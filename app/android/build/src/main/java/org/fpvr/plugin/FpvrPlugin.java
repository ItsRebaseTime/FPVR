package org.fpvr.plugin;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.core.content.ContextCompat;
import androidx.core.app.ActivityCompat;

import org.godotengine.godot.Dictionary;
import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Android-platform hardware access that stock /dev scanning cannot reach:
 * USB serial devices (GPS/ELRS over CDC-ACM) via UsbManager, and the
 * phone's own built-in GNSS via LocationManager. Exposed to GDScript as
 * the "FpvrPlugin" singleton; HardwareHub (GDScript) is the only caller
 * and treats this as just another data source, same shape as the Linux
 * SerialPort/GpsDriver path.
 *
 * Scope note: only standard USB CDC-ACM serial is implemented for the
 * GPS/ELRS path (covers most ELRS USB adapters and u-blox/other GPS
 * modules). Vendor-specific serial chips (CP210x, FTDI, CH340 without a
 * CDC-ACM descriptor) are not implemented.
 *
 * UVC video capture: Android has no built-in UVC/webcam support, so this
 * plugin only hands a raw usbfs file descriptor + raw USB descriptor
 * bytes up to GDScript (openUsbRawConnection/getUsbRawFd/
 * getUsbRawDescriptors) -- the actual isochronous transfer protocol,
 * UVC descriptor parsing, and Probe/Commit negotiation live in
 * core/src/hw/uvc_usbfs_driver.cpp (C++), which issues the same
 * USBDEVFS_* ioctls directly on that fd that a native Linux UVC driver
 * would. This keeps the one genuinely hard, iterative-to-debug piece of
 * logic in C++ next to the existing V4L2 UvcDriver it mirrors, rather
 * than duplicating it in Java.
 */
public class FpvrPlugin extends GodotPlugin {

	private static final String TAG = "FpvrPlugin";
	private static final String ACTION_USB_PERMISSION = "org.fpvr.plugin.USB_PERMISSION";
	private static final int LOCATION_PERMISSION_REQUEST_CODE = 42111;
	private static final int CAMERA_PERMISSION_REQUEST_CODE = 42112;

	private UsbManager usbManager;
	private LocationManager locationManager;

	private final ConcurrentHashMap<Integer, OpenSerialDevice> openDevices = new ConcurrentHashMap<>();
	private final ConcurrentHashMap<Integer, UsbDeviceConnection> rawConnections = new ConcurrentHashMap<>();
	private volatile Location lastLocation = null;

	// Android shows at most one runtime-permission dialog per Activity at a
	// time; a requestPermissions() call made while another is still pending
	// is silently dropped (confirmed: the camera-permission request never
	// surfaced because it landed while the location-permission dialog this
	// app also requests at startup was still on screen). Serialize instead
	// of relying on callers not to overlap.
	private boolean permissionRequestInFlight = false;
	private final ArrayDeque<Runnable> queuedPermissionRequests = new ArrayDeque<>();

	public FpvrPlugin(Godot godot) {
		super(godot);
	}

	@NonNull
	@Override
	public String getPluginName() {
		return "FpvrPlugin";
	}

	@NonNull
	@Override
	public Set<SignalInfo> getPluginSignals() {
		Set<SignalInfo> signals = new HashSet<>();
		signals.add(new SignalInfo("usb_permission_result", Integer.class, Boolean.class));
		signals.add(new SignalInfo("location_permission_result", Boolean.class));
		signals.add(new SignalInfo("camera_permission_result", Boolean.class));
		return signals;
	}

	@Override
	public android.view.View onMainCreate(android.app.Activity activity) {
		usbManager = (UsbManager) activity.getSystemService(Context.USB_SERVICE);
		locationManager = (LocationManager) activity.getSystemService(Context.LOCATION_SERVICE);

		IntentFilter filter = new IntentFilter(ACTION_USB_PERMISSION);
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
			activity.registerReceiver(usbPermissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
		} else {
			activity.registerReceiver(usbPermissionReceiver, filter);
		}
		return super.onMainCreate(activity);
	}

	@Override
	public void onMainDestroy() {
		for (OpenSerialDevice d : openDevices.values()) {
			d.close();
		}
		openDevices.clear();
		for (UsbDeviceConnection c : rawConnections.values()) {
			c.close();
		}
		rawConnections.clear();
		stopLocationUpdates();
	}

	// ---------------------------------------------------------------
	// Raw USB connection (UVC video) -- see the class doc comment for why
	// the actual isochronous transfer logic lives in C++, not here. This
	// just hands over what only Java/UsbManager can provide: a permitted,
	// open connection's file descriptor and raw descriptor bytes.
	// ---------------------------------------------------------------

	@UsedByGodot
	public boolean openUsbRawConnection(int deviceId) {
		UsbDevice device = findDeviceById(deviceId);
		if (device == null || !usbManager.hasPermission(device)) {
			Log.d(TAG, "openUsbRawConnection(" + deviceId + "): device=" + device + " hasPermission=" +
					(device != null && usbManager.hasPermission(device)));
			return false;
		}
		UsbDeviceConnection existing = rawConnections.remove(deviceId);
		if (existing != null) {
			existing.close();
		}
		UsbDeviceConnection connection = usbManager.openDevice(device);
		Log.d(TAG, "openUsbRawConnection(" + deviceId + "): openDevice -> " + connection);
		if (connection == null) {
			return false;
		}
		rawConnections.put(deviceId, connection);
		return true;
	}

	@UsedByGodot
	public void closeUsbRawConnection(int deviceId) {
		UsbDeviceConnection c = rawConnections.remove(deviceId);
		if (c != null) {
			c.close();
		}
	}

	/** -1 if not open. Valid only until closeUsbRawConnection() is called. */
	@UsedByGodot
	public int getUsbRawFd(int deviceId) {
		UsbDeviceConnection c = rawConnections.get(deviceId);
		int fd = c != null ? c.getFileDescriptor() : -1;
		Log.d(TAG, "getUsbRawFd(" + deviceId + ") -> " + fd);
		return fd;
	}

	/** Raw USB descriptor bytes (device + all config/interface/endpoint/
	 * class-specific descriptors concatenated), the same blob libusb-style
	 * tooling parses on desktop Linux. Empty if not open. */
	@UsedByGodot
	public byte[] getUsbRawDescriptors(int deviceId) {
		UsbDeviceConnection c = rawConnections.get(deviceId);
		byte[] out = c != null ? c.getRawDescriptors() : new byte[0];
		Log.d(TAG, "getUsbRawDescriptors(" + deviceId + ") -> " + out.length + " bytes");
		return out;
	}

	/** Claims the VideoStreaming interface (altsetting 0) via Android's own
	 * UsbDeviceConnection API rather than a raw USBDEVFS_CLAIMINTERFACE
	 * ioctl from native code -- the latter was observed failing with EBUSY
	 * on a real device even on the very first attempt, before this app had
	 * made any other claim, which going through the framework's own
	 * sanctioned claim path avoids. Must be called before the native driver
	 * touches the fd; the claim is then already in effect when it does. */
	@UsedByGodot
	public boolean claimVideoStreamingInterface(int deviceId) {
		UsbDevice device = findDeviceById(deviceId);
		UsbDeviceConnection c = rawConnections.get(deviceId);
		if (device == null || c == null) {
			return false;
		}
		for (int i = 0; i < device.getInterfaceCount(); i++) {
			UsbInterface intf = device.getInterface(i);
			if (intf.getInterfaceClass() == UsbConstants.USB_CLASS_VIDEO
					&& intf.getInterfaceSubclass() == 2 /* SC_VIDEOSTREAMING */
					&& intf.getAlternateSetting() == 0) {
				boolean claimed = c.claimInterface(intf, true);
				Log.d(TAG, "claimVideoStreamingInterface(" + deviceId + "): interface id=" + intf.getId() + " claimed=" + claimed);
				return claimed;
			}
		}
		Log.d(TAG, "claimVideoStreamingInterface(" + deviceId + "): no VideoStreaming altsetting-0 interface found");
		return false;
	}

	// ---------------------------------------------------------------
	// USB device discovery + permission
	// ---------------------------------------------------------------

	/** Returns an Array of Dictionaries describing every attached USB device. */
	@UsedByGodot
	public Object[] listUsbDevices() {
		HashMap<String, UsbDevice> devices = usbManager.getDeviceList();
		Object[] out = new Object[devices.size()];
		int i = 0;
		for (UsbDevice device : devices.values()) {
			out[i++] = describeDevice(device);
		}
		return out;
	}

	private Dictionary describeDevice(UsbDevice device) {
		Dictionary d = new Dictionary();
		d.put("device_id", device.getDeviceId());
		d.put("vendor_id", device.getVendorId());
		d.put("product_id", device.getProductId());
		d.put("device_name", device.getDeviceName());
		d.put("product_name", device.getProductName() != null ? device.getProductName() : "");
		d.put("has_permission", usbManager.hasPermission(device));
		d.put("kind", classifyDevice(device));
		return d;
	}

	/** "serial" if a CDC-ACM data interface is present, "uvc" if a video
	 * class interface is present (discovery only -- not yet capturable),
	 * else "unknown". */
	private String classifyDevice(UsbDevice device) {
		boolean hasCdcData = false;
		boolean hasVideo = false;
		for (int i = 0; i < device.getInterfaceCount(); i++) {
			int cls = device.getInterface(i).getInterfaceClass();
			if (cls == UsbConstants.USB_CLASS_CDC_DATA) {
				hasCdcData = true;
			} else if (cls == UsbConstants.USB_CLASS_VIDEO) {
				hasVideo = true;
			}
		}
		if (hasCdcData) return "serial";
		if (hasVideo) return "uvc";
		return "unknown";
	}

	@UsedByGodot
	public void requestUsbPermission(int deviceId) {
		try {
			UsbDevice device = findDeviceById(deviceId);
			if (device == null) {
				emitSignal("usb_permission_result", deviceId, false);
				return;
			}
			if (usbManager.hasPermission(device)) {
				emitSignal("usb_permission_result", deviceId, true);
				return;
			}
			int flags = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? PendingIntent.FLAG_MUTABLE : 0;
			// Android 14+ (API 34) refuses to create a FLAG_MUTABLE PendingIntent
			// for an implicit intent (no explicit component/package) -- throws
			// IllegalArgumentException. setPackage() makes this an explicit,
			// same-app-only intent, which is exempt from that restriction.
			Intent intent = new Intent(ACTION_USB_PERMISSION).setPackage(getActivity().getPackageName());
			PendingIntent pi = PendingIntent.getBroadcast(getActivity(), 0, intent, flags);
			usbManager.requestPermission(device, pi);
		} catch (Throwable t) {
			Log.e(TAG, "requestUsbPermission(" + deviceId + "): EXCEPTION", t);
		}
	}

	private final BroadcastReceiver usbPermissionReceiver = new BroadcastReceiver() {
		@Override
		public void onReceive(Context context, Intent intent) {
			if (!ACTION_USB_PERMISSION.equals(intent.getAction())) {
				return;
			}
			UsbDevice device = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE);
			boolean granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false);
			Log.d(TAG, "usb_permission_result device=" + device + " granted=" + granted);
			if (device != null) {
				emitSignal("usb_permission_result", device.getDeviceId(), granted);
			}
		}
	};

	private UsbDevice findDeviceById(int deviceId) {
		for (UsbDevice device : usbManager.getDeviceList().values()) {
			if (device.getDeviceId() == deviceId) {
				return device;
			}
		}
		return null;
	}

	// ---------------------------------------------------------------
	// USB CDC-ACM serial I/O
	// ---------------------------------------------------------------

	@UsedByGodot
	public boolean openUsbSerialDevice(int deviceId, int baudRate) {
		UsbDevice device = findDeviceById(deviceId);
		if (device == null || !usbManager.hasPermission(device)) {
			return false;
		}
		OpenSerialDevice existing = openDevices.remove(deviceId);
		if (existing != null) {
			existing.close();
		}
		OpenSerialDevice opened = OpenSerialDevice.open(usbManager, device, baudRate);
		if (opened == null) {
			return false;
		}
		openDevices.put(deviceId, opened);
		return true;
	}

	@UsedByGodot
	public void closeUsbSerialDevice(int deviceId) {
		OpenSerialDevice d = openDevices.remove(deviceId);
		if (d != null) {
			d.close();
		}
	}

	/** Drains whatever bytes the background reader thread has queued since the last call. */
	@UsedByGodot
	public byte[] readUsbSerialBytes(int deviceId) {
		OpenSerialDevice d = openDevices.get(deviceId);
		return d != null ? d.drainRead() : new byte[0];
	}

	@UsedByGodot
	public int writeUsbSerialBytes(int deviceId, byte[] data) {
		OpenSerialDevice d = openDevices.get(deviceId);
		return d != null ? d.write(data) : 0;
	}

	// ---------------------------------------------------------------
	// Built-in GNSS (phone's own location)
	// ---------------------------------------------------------------

	@UsedByGodot
	public boolean hasLocationPermission() {
		return ContextCompat.checkSelfPermission(getActivity(), android.Manifest.permission.ACCESS_FINE_LOCATION)
				== PackageManager.PERMISSION_GRANTED;
	}

	@UsedByGodot
	public void requestLocationPermission() {
		requestPermissionSerialized(android.Manifest.permission.ACCESS_FINE_LOCATION, LOCATION_PERMISSION_REQUEST_CODE);
	}

	/** Queues the request if another permission dialog is already showing,
	 * instead of firing requestPermissions() concurrently (which Android
	 * silently drops) -- see the queuedPermissionRequests field comment. */
	private void requestPermissionSerialized(String permission, int requestCode) {
		Runnable fire = () -> ActivityCompat.requestPermissions(getActivity(), new String[] { permission }, requestCode);
		if (permissionRequestInFlight) {
			queuedPermissionRequests.add(fire);
		} else {
			permissionRequestInFlight = true;
			fire.run();
		}
	}

	private void onPermissionRequestResolved() {
		Runnable next = queuedPermissionRequests.poll();
		if (next != null) {
			next.run(); // permissionRequestInFlight stays true
		} else {
			permissionRequestInFlight = false;
		}
	}

	@UsedByGodot
	public boolean hasCameraPermission() {
		return ContextCompat.checkSelfPermission(getActivity(), android.Manifest.permission.CAMERA)
				== PackageManager.PERMISSION_GRANTED;
	}

	/** Android silently refuses to show the USB permission dialog for a
	 * video-class (UVC) device unless this is granted first -- confirmed
	 * via UsbUserPermissionManager logging "Camera permission required for
	 * USB video class devices" when it's missing. Call this (and wait for
	 * camera_permission_result) before requestUsbPermission() on a "uvc"
	 * kind device. */
	@UsedByGodot
	public void requestCameraPermission() {
		requestPermissionSerialized(android.Manifest.permission.CAMERA, CAMERA_PERMISSION_REQUEST_CODE);
	}

	@Override
	public void onMainRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
		boolean granted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
		if (requestCode == LOCATION_PERMISSION_REQUEST_CODE) {
			emitSignal("location_permission_result", granted);
		} else if (requestCode == CAMERA_PERMISSION_REQUEST_CODE) {
			emitSignal("camera_permission_result", granted);
		}
		onPermissionRequestResolved();
	}

	private final LocationListener locationListener = new LocationListener() {
		@Override
		public void onLocationChanged(@NonNull Location location) {
			lastLocation = location;
		}
	};

	@UsedByGodot
	public boolean startLocationUpdates() {
		if (!hasLocationPermission()) {
			return false;
		}
		try {
			locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, locationListener);
			return true;
		} catch (SecurityException | IllegalArgumentException e) {
			return false;
		}
	}

	@UsedByGodot
	public void stopLocationUpdates() {
		try {
			locationManager.removeUpdates(locationListener);
		} catch (SecurityException ignored) {
		}
	}

	@UsedByGodot
	public Dictionary getLastLocationFix() {
		Dictionary d = new Dictionary();
		Location loc = lastLocation;
		boolean hasFix = loc != null;
		d.put("has_fix", hasFix);
		d.put("latitude", hasFix ? loc.getLatitude() : 0.0);
		d.put("longitude", hasFix ? loc.getLongitude() : 0.0);
		d.put("altitude_m", hasFix ? loc.getAltitude() : 0.0);
		// Android's reported accuracy is already a 1-sigma horizontal radius in
		// meters, so it's directly comparable to the HDOP*UERE estimate GpsDriver
		// computes for an external NMEA receiver -- see HardwareHub's merge logic.
		d.put("accuracy_m", hasFix && loc.hasAccuracy() ? loc.getAccuracy() : 9999.0);
		d.put("ground_speed_mps", hasFix && loc.hasSpeed() ? loc.getSpeed() : 0.0);
		d.put("course_deg", hasFix && loc.hasBearing() ? loc.getBearing() : 0.0);
		return d;
	}

	/** Holds one open CDC-ACM serial device: the claimed data interface, its
	 * bulk endpoints, and a background thread continuously draining the
	 * bulk-IN endpoint into a byte queue so reads from GDScript never block. */
	private static class OpenSerialDevice {
		final UsbDeviceConnection connection;
		final UsbInterface dataInterface;
		final UsbEndpoint endpointIn;
		final UsbEndpoint endpointOut;
		final ArrayDeque<byte[]> readQueue = new ArrayDeque<>();
		volatile boolean running = true;
		Thread readerThread;

		OpenSerialDevice(UsbDeviceConnection connection, UsbInterface dataInterface, UsbEndpoint in, UsbEndpoint out) {
			this.connection = connection;
			this.dataInterface = dataInterface;
			this.endpointIn = in;
			this.endpointOut = out;
		}

		static OpenSerialDevice open(UsbManager manager, UsbDevice device, int baudRate) {
			UsbInterface dataIntf = null;
			UsbInterface commIntf = null;
			for (int i = 0; i < device.getInterfaceCount(); i++) {
				UsbInterface intf = device.getInterface(i);
				if (intf.getInterfaceClass() == UsbConstants.USB_CLASS_CDC_DATA) {
					dataIntf = intf;
				} else if (intf.getInterfaceClass() == UsbConstants.USB_CLASS_COMM) {
					commIntf = intf;
				}
			}
			if (dataIntf == null) {
				return null;
			}

			UsbDeviceConnection connection = manager.openDevice(device);
			if (connection == null) {
				return null;
			}

			if (!connection.claimInterface(dataIntf, true)) {
				connection.close();
				return null;
			}

			UsbEndpoint in = null, out = null;
			for (int i = 0; i < dataIntf.getEndpointCount(); i++) {
				UsbEndpoint ep = dataIntf.getEndpoint(i);
				if (ep.getType() != UsbConstants.USB_ENDPOINT_XFER_BULK) {
					continue;
				}
				if (ep.getDirection() == UsbConstants.USB_DIR_IN) {
					in = ep;
				} else {
					out = ep;
				}
			}
			if (in == null || out == null) {
				connection.releaseInterface(dataIntf);
				connection.close();
				return null;
			}

			// Best-effort CDC control setup: assert DTR/RTS and set line coding.
			// Some devices only start streaming data once DTR is asserted.
			if (commIntf != null) {
				connection.claimInterface(commIntf, true);
				int ifaceNum = commIntf.getId();
				connection.controlTransfer(0x21, 0x22, 0x0003, ifaceNum, null, 0, 200); // SET_CONTROL_LINE_STATE: DTR+RTS
				byte[] lineCoding = new byte[] {
						(byte) (baudRate & 0xFF), (byte) ((baudRate >> 8) & 0xFF),
						(byte) ((baudRate >> 16) & 0xFF), (byte) ((baudRate >> 24) & 0xFF),
						0, // 1 stop bit
						0, // no parity
						8, // 8 data bits
				};
				connection.controlTransfer(0x21, 0x20, 0, ifaceNum, lineCoding, lineCoding.length, 200); // SET_LINE_CODING
			}

			OpenSerialDevice opened = new OpenSerialDevice(connection, dataIntf, in, out);
			opened.startReaderThread();
			return opened;
		}

		void startReaderThread() {
			readerThread = new Thread(() -> {
				byte[] buf = new byte[512];
				while (running) {
					int n = connection.bulkTransfer(endpointIn, buf, buf.length, 250);
					if (n > 0) {
						byte[] chunk = new byte[n];
						System.arraycopy(buf, 0, chunk, 0, n);
						synchronized (readQueue) {
							readQueue.addLast(chunk);
							// Bound memory if GDScript stops draining (e.g. device misclassified).
							while (readQueue.size() > 256) {
								readQueue.removeFirst();
							}
						}
					}
				}
			}, "FpvrUsbSerialReader");
			readerThread.setDaemon(true);
			readerThread.start();
		}

		byte[] drainRead() {
			synchronized (readQueue) {
				if (readQueue.isEmpty()) {
					return new byte[0];
				}
				int total = 0;
				for (byte[] chunk : readQueue) {
					total += chunk.length;
				}
				byte[] out = new byte[total];
				int offset = 0;
				for (byte[] chunk : readQueue) {
					System.arraycopy(chunk, 0, out, offset, chunk.length);
					offset += chunk.length;
				}
				readQueue.clear();
				return out;
			}
		}

		int write(byte[] data) {
			if (data == null || data.length == 0) {
				return 0;
			}
			int n = connection.bulkTransfer(endpointOut, data, data.length, 500);
			return Math.max(n, 0);
		}

		void close() {
			running = false;
			if (readerThread != null) {
				try {
					readerThread.join(500);
				} catch (InterruptedException ignored) {
				}
			}
			connection.releaseInterface(dataInterface);
			connection.close();
		}
	}
}
