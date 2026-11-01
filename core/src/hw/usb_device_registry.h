#ifndef FPVR_USB_DEVICE_REGISTRY_H
#define FPVR_USB_DEVICE_REGISTRY_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace fpvr {

// Enumerates USB-attached hardware only (serial GPS/ELRS candidates and UVC
// video devices). Internal/non-USB hardware is deliberately excluded by
// checking that each device's sysfs path resolves under a USB bus.
class UsbDeviceRegistry : public godot::RefCounted {
	GDCLASS(UsbDeviceRegistry, godot::RefCounted)

protected:
	static void _bind_methods();

public:
	// Returns an Array of Dictionaries, one per detected USB device:
	// { "path": String, "kind": "serial"|"uvc"|"uvc_no_kernel_driver", "name": String }
	//
	// "uvc" means a /dev/videoX node exists (the uvcvideo kernel module
	// handled it) -- UvcDriver (V4L2) should be used. "uvc_no_kernel_driver"
	// means a USB video-class interface was found on the bus via sysfs but
	// no video4linux device materialized for it (e.g. Steam Frame's current
	// OS doesn't ship uvcvideo) -- also carries "descriptors_path" (a sysfs
	// file with the raw USB descriptor blob) so UvcUsbfsDriver can open it
	// directly, the same fallback path Android always uses.
	godot::Array scan();

private:
	// Dedup for the diagnostic print in scan()'s V4L2 branch -- without
	// this it printed unconditionally every ~3s (HardwareHub's rescan
	// timer), which was fine for the one-off "is the camera even found"
	// question it was added for, but drowns out everything else in a log
	// covering more than a few seconds of runtime.
	int last_logged_total_video_nodes = -1;
	int last_logged_usb_backed_nodes = -1;
};

} // namespace fpvr

#endif // FPVR_USB_DEVICE_REGISTRY_H
