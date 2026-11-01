extends Node
## Autoload singleton: owns USB device discovery/classification and the
## live GPS/ELRS/UVC drivers. Every window scene and every shell reads
## hardware state from here instead of re-scanning devices itself -- this
## is the one place that logic lives, so adding a new window type or a new
## shell never means re-implementing device discovery.
##
## Two discovery backends, picked automatically at _ready():
## - Linux (incl. the Steam Frame, which runs a Linux-based OS): raw /dev
##   scanning via UsbDeviceRegistry/SerialPort, as before.
## - Android: stock Android blocks that raw /dev access, so this goes
##   through the FpvrPlugin Android plugin (UsbManager device list +
##   permission flow + CDC-ACM bulk transfers) instead. Serial port
##   entries from either backend are stored the same way and driven by
##   the same _process loop -- SerialPort and AndroidUsbSource both expose
##   is_open()/read_available()/write_bytes()/close_port().
##
## Android also has its own built-in GNSS (no USB device needed). When
## both that and a USB-connected external GPS are present, get_self_gps_fix()
## returns whichever currently reports the better accuracy_m.
##
## UVC video capture on Android goes through UvcUsbfsDriver (core), which
## issues USBDEVFS_* ioctls directly on the raw usbfs fd FpvrPlugin hands
## up -- see that class's doc comment. _uvc/_uvc_path are shared by both
## platforms' code paths (never both active in the same running instance,
## since _rescan() always takes exactly one branch), holding either a
## UvcDriver (Linux/V4L2) or a UvcUsbfsDriver (Android) interchangeably --
## both expose the same is_open()/read_frame()/get_format()/get_width()/
## get_height()/close_device() shape, so the _process() video block below
## doesn't need to know which platform it's running on.

const PROBE_BAUD := 115200
const RESCAN_INTERVAL := 3.0
const VIDEO_WIDTH := 1280
const VIDEO_HEIGHT := 720

signal devices_changed
signal video_frame_ready(bytes: PackedByteArray, format: String, width: int, height: int)

var _is_android := false
var _android_plugin = null

var _registry := UsbDeviceRegistry.new()
var _serial_ports: Dictionary = {} # key -> { port, kind, gps, elrs }
var _uvc_path: String = ""
var _uvc = null # UvcDriver (Linux) or UvcUsbfsDriver (Android) -- duck-typed, see class doc comment
var _rescan_timer := 0.0

var _android_location_fix: Dictionary = { "has_fix": false }
var _android_permission_requested: Dictionary = {} # device_id -> true, so we ask at most once per device
var _android_camera_permission_requested := false

var _uvc_backend: String = "" # "v4l2" | "usbfs_fallback" | ""
var _uvc_warning: String = ""
var _last_uvc_scan_summary := ""

func _ready() -> void:
	_is_android = OS.get_name() == "Android"
	if _is_android and Engine.has_singleton("FpvrPlugin"):
		_android_plugin = Engine.get_singleton("FpvrPlugin")
		_android_plugin.usb_permission_result.connect(_on_android_usb_permission_result)
		_android_plugin.location_permission_result.connect(_on_android_location_permission_result)
		_android_plugin.camera_permission_result.connect(_on_android_camera_permission_result)
		_start_android_location()
	_rescan()

func _process(delta: float) -> void:
	_rescan_timer += delta
	if _rescan_timer >= RESCAN_INTERVAL:
		_rescan_timer = 0.0
		_rescan()

	for key in _serial_ports.keys():
		var entry: Dictionary = _serial_ports[key]
		var port = entry["port"]
		if not port.is_open():
			continue
		var data: PackedByteArray = port.read_available()
		if data.size() == 0:
			continue
		if entry["kind"] == "unknown":
			_classify(entry, data)
		if entry["kind"] == "gps":
			entry["gps"].feed(data)
		elif entry["kind"] == "elrs":
			entry["elrs"].feed(data)

	if _uvc != null and _uvc.is_open():
		var frame: PackedByteArray = _uvc.read_frame()
		if frame.size() > 0:
			video_frame_ready.emit(frame, _uvc.get_format(), _uvc.get_width(), _uvc.get_height())

	if _android_plugin != null:
		_android_location_fix = _android_plugin.getLastLocationFix()

func _rescan() -> void:
	if _android_plugin != null:
		_rescan_android()
	else:
		_rescan_linux()
	devices_changed.emit()

func _rescan_linux() -> void:
	var devices: Array = _registry.scan()
	var seen := {}
	var v4l2_paths: Array = []
	var fallback_devices: Array = [] # "uvc_no_kernel_driver" dicts

	for d in devices:
		var path: String = d["path"]
		if d["kind"] == "serial":
			seen[path] = true
			if not _serial_ports.has(path):
				var port = SerialPort.new()
				if port.open_port(path, PROBE_BAUD):
					_serial_ports[path] = {
						"port": port,
						"kind": "unknown",
						"gps": GpsDriver.new(),
						"elrs": ElrsDriver.new(),
						"name": d.get("name", path),
					}
		elif d["kind"] == "uvc":
			v4l2_paths.append(path)
		elif d["kind"] == "uvc_no_kernel_driver":
			fallback_devices.append(d)

	_drop_stale_ports(seen)
	_log_uvc_scan_once(devices, v4l2_paths, fallback_devices)

	# If what's currently open is still a valid candidate, leave it alone.
	if _uvc != null and _uvc.is_open():
		if _uvc_backend == "v4l2" and v4l2_paths.has(_uvc_path):
			return
		if _uvc_backend == "usbfs_fallback":
			for d in fallback_devices:
				if d["path"] == _uvc_path:
					return

	if _uvc != null:
		_uvc.close_device()
		_uvc = null
	_uvc_path = ""
	_uvc_backend = ""
	_uvc_warning = ""

	# V4L2 is always preferred when a /dev/videoX node exists: kernel-driven,
	# interrupt-completion, mmap'd zero-copy buffers, and far more hardened
	# against device quirks than our own userspace driver. Only fall back to
	# the in-app usbfs driver when no kernel driver claimed the device at
	# all (e.g. Steam Frame's current OS, which doesn't ship uvcvideo).
	#
	# Try every V4L2 candidate, not just the first: some UVC devices expose
	# a metadata-only /dev/videoX node alongside the real capture node,
	# which reports V4L2_CAP_VIDEO_CAPTURE but fails to actually open for
	# capture.
	for path in v4l2_paths:
		var driver := UvcDriver.new()
		if driver.open_device(path, VIDEO_WIDTH, VIDEO_HEIGHT):
			_uvc = driver
			_uvc_path = path
			_uvc_backend = "v4l2"
			return

	for d in fallback_devices:
		var driver := UvcUsbfsDriver.new()
		if driver.open_from_path(d["path"], d["descriptors_path"], VIDEO_WIDTH, VIDEO_HEIGHT):
			_uvc = driver
			_uvc_path = d["path"]
			_uvc_backend = "usbfs_fallback"
			_uvc_warning = "No uvcvideo kernel driver found for \"%s\" -- using the built-in fallback video driver instead. For better latency and stability, install/enable the uvcvideo kernel module." % d["name"]
			return
		else:
			print("HardwareHub: UvcUsbfsDriver.open_from_path FAILED for \"%s\" (path=%s, descriptors=%s) -- likely a permission error opening the raw device node or sysfs descriptors file; check with `ls -la %s` and `ls -la %s`." % [d["name"], d["path"], d["descriptors_path"], d["path"], d["descriptors_path"]])

func _log_uvc_scan_once(devices: Array, v4l2_paths: Array, fallback_devices: Array) -> void:
	var summary := "HardwareHub scan: %d device(s) total, %d serial, %d v4l2 uvc, %d uvc-no-kernel-driver" % [
		devices.size(),
		devices.filter(func(d): return d["kind"] == "serial").size(),
		v4l2_paths.size(),
		fallback_devices.size(),
	]
	if v4l2_paths.is_empty() and fallback_devices.is_empty():
		summary += " -- no UVC-class USB device detected at all. Check `lsusb` and `ls /sys/bus/usb/devices/*/` for a bInterfaceClass of 0e on the attached device."
	if summary != _last_uvc_scan_summary:
		_last_uvc_scan_summary = summary
		print(summary)

func _rescan_android() -> void:
	var devices: Array = _android_plugin.listUsbDevices()
	var seen := {}
	var uvc_still_present := false

	for d in devices:
		var device_id: int = d["device_id"]
		var key := "android:%d" % device_id

		if d["kind"] == "serial":
			seen[key] = true
			if _serial_ports.has(key):
				continue
			if not d["has_permission"]:
				_request_android_permission_once(device_id)
				continue
			var source = load("res://core_services/android_usb_source.gd").new(_android_plugin, device_id)
			if _android_plugin.openUsbSerialDevice(device_id, PROBE_BAUD):
				source.mark_opened()
				_serial_ports[key] = {
					"port": source,
					"kind": "unknown",
					"gps": GpsDriver.new(),
					"elrs": ElrsDriver.new(),
					"name": d.get("product_name", key),
				}
		elif d["kind"] == "uvc":
			if _uvc_path == key:
				uvc_still_present = true
			elif _uvc_path == "": # first-found wins, same as the Linux path
				if not d["has_permission"]:
					# Android won't even show the USB permission dialog for a
					# video-class device until CAMERA is granted -- see
					# FpvrPlugin.requestCameraPermission()'s doc comment.
					if _android_plugin.hasCameraPermission():
						_request_android_permission_once(device_id)
					elif not _android_camera_permission_requested:
						_android_camera_permission_requested = true
						_android_plugin.requestCameraPermission()
				else:
					_try_open_android_uvc(device_id, key)
					uvc_still_present = _uvc_path == key

	_drop_stale_ports(seen)

	if _uvc_path.begins_with("android:") and not uvc_still_present:
		_close_android_uvc()

func _try_open_android_uvc(device_id: int, key: String) -> void:
	print("HardwareHub: trying to open Android UVC device ", device_id)
	if not _android_plugin.openUsbRawConnection(device_id):
		print("HardwareHub: openUsbRawConnection failed for ", device_id)
		return
	if not _android_plugin.claimVideoStreamingInterface(device_id):
		print("HardwareHub: claimVideoStreamingInterface failed for ", device_id)
		_android_plugin.closeUsbRawConnection(device_id)
		return
	var raw_descriptors: PackedByteArray = _android_plugin.getUsbRawDescriptors(device_id)
	var fd: int = _android_plugin.getUsbRawFd(device_id)
	var driver := UvcUsbfsDriver.new()
	var ok := driver.open_from_fd(fd, raw_descriptors, VIDEO_WIDTH, VIDEO_HEIGHT)
	print("HardwareHub: UvcUsbfsDriver.open_from_fd(", fd, ", ", raw_descriptors.size(), " bytes) -> ", ok)
	if ok:
		_uvc = driver
		_uvc_path = key
		_uvc_backend = "usbfs_android" # expected/by-design here, not a missing-driver situation -- no warning
	else:
		_android_plugin.closeUsbRawConnection(device_id)

func _close_android_uvc() -> void:
	if _uvc != null:
		_uvc.close_device()
		_uvc = null
	var device_id := int(_uvc_path.trim_prefix("android:"))
	_android_plugin.closeUsbRawConnection(device_id)
	_uvc_path = ""
	_uvc_backend = ""

func _drop_stale_ports(seen: Dictionary) -> void:
	for key in _serial_ports.keys():
		if not seen.has(key):
			_serial_ports[key]["port"].close_port()
			_serial_ports.erase(key)

func _request_android_permission_once(device_id: int) -> void:
	if _android_permission_requested.has(device_id):
		return
	_android_permission_requested[device_id] = true
	_android_plugin.requestUsbPermission(device_id)

func _on_android_usb_permission_result(device_id: int, granted: bool) -> void:
	if not granted:
		_android_permission_requested.erase(device_id) # denied -> allow asking again on a later rescan
	_rescan_android() # granted -> opens it now instead of waiting for the next timer tick

func _start_android_location() -> void:
	if _android_plugin.hasLocationPermission():
		_android_plugin.startLocationUpdates()
	else:
		_android_plugin.requestLocationPermission()

func _on_android_location_permission_result(granted: bool) -> void:
	if granted:
		_android_plugin.startLocationUpdates()

func _on_android_camera_permission_result(_granted: bool) -> void:
	_rescan_android() # granted -> the uvc branch above can now request USB permission

func _classify(entry: Dictionary, sample: PackedByteArray) -> void:
	if ElrsDriver.looks_like_crsf(sample):
		entry["kind"] = "elrs"
	elif GpsDriver.looks_like_nmea(sample):
		entry["kind"] = "gps"
	elif GpsDriver.looks_like_ubx(sample):
		entry["kind"] = "gps"

## Picks whichever GPS source currently has the better (smaller) accuracy_m:
## the phone's own built-in GNSS vs. a USB-connected external receiver.
## On non-Android platforms there's no internal fix, so this always
## resolves to the external one (or no fix), same as before.
func get_self_gps_fix() -> Dictionary:
	var external := { "has_fix": false }
	for entry in _serial_ports.values():
		if entry["kind"] == "gps":
			external = entry["gps"].get_fix()
			break

	var internal: Dictionary = _android_location_fix

	var ext_ok: bool = external.get("has_fix", false)
	var int_ok: bool = internal.get("has_fix", false)
	if ext_ok and int_ok:
		var ext_acc: float = external.get("accuracy_m", 9999.0)
		var int_acc: float = internal.get("accuracy_m", 9999.0)
		return external if ext_acc <= int_acc else internal
	elif ext_ok:
		return external
	elif int_ok:
		return internal
	return { "has_fix": false }

func get_uav_fix() -> Dictionary:
	for entry in _serial_ports.values():
		if entry["kind"] == "elrs":
			return entry["elrs"].get_gps()
	return { "has_fix": false }

func get_uav_battery() -> Dictionary:
	for entry in _serial_ports.values():
		if entry["kind"] == "elrs":
			return entry["elrs"].get_battery()
	return { "has_data": false }

func get_uav_link_stats() -> Dictionary:
	for entry in _serial_ports.values():
		if entry["kind"] == "elrs":
			return entry["elrs"].get_link_stats()
	return { "has_data": false }

func get_uav_flight_mode() -> String:
	for entry in _serial_ports.values():
		if entry["kind"] == "elrs":
			return entry["elrs"].get_flight_mode()
	return ""

func get_elrs_port_for_control():
	for entry in _serial_ports.values():
		if entry["kind"] == "elrs":
			return entry["port"]
	return null

## Packs 16 CRSF channel values (0..1984, center ~992) and writes them to
## the ELRS TX/RX serial link, if one is connected. No-op otherwise, so
## callers (control_mapper) never need to check for hardware themselves.
func send_uav_channels(channels: Array) -> void:
	var port = get_elrs_port_for_control()
	if port == null:
		return
	port.write_bytes(ElrsDriver.pack_channels_frame(channels))

func has_video() -> bool:
	return _uvc != null and _uvc.is_open()

## "backend" is "v4l2" | "usbfs_android" | "usbfs_fallback" | "" (no video).
## "warning" is non-empty only for usbfs_fallback (no kernel UVC driver
## found on Linux) -- windows/settings UIs can surface it to the user.
func get_video_driver_info() -> Dictionary:
	return { "backend": _uvc_backend, "warning": _uvc_warning }

func get_connected_devices_summary() -> Array:
	var out: Array = []
	for key in _serial_ports.keys():
		out.append({ "path": key, "kind": _serial_ports[key]["kind"] })
	if has_video():
		out.append({ "path": _uvc_path, "kind": "uvc" })
	return out
