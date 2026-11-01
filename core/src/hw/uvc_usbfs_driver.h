#ifndef FPVR_UVC_USBFS_DRIVER_H
#define FPVR_UVC_USBFS_DRIVER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

// Forward-declared to avoid pulling <linux/usbdevice_fs.h> into the header;
// only the .cpp needs the real kernel struct layout.
struct usbdevfs_urb;

namespace fpvr {

// Userspace UVC capture via direct USBDEVFS_* ioctls on a raw usbfs file
// descriptor -- the same mechanism libusb/libuvc use on desktop Linux.
// Used in two situations, both opened differently but sharing the same
// protocol/streaming implementation:
//   - Android: no built-in UVC/webcam support at all, so this is the only
//     way to get video. The fd comes from UsbManager (open_from_fd()),
//     already permission-granted and owned by the Java side.
//   - Linux (incl. Steam Frame): fallback for when a UVC device is on the
//     bus but no uvcvideo kernel module is bound to it (confirmed via
//     UsbDeviceRegistry's sysfs walk) -- here this driver opens the raw
//     /dev/bus/usb/BBB/DDD node itself (open_from_path()). UvcDriver (V4L2)
//     is always preferred when a /dev/videoX node exists: it's kernel-
//     driven (interrupt-completion, mmap'd zero-copy buffers) rather than
//     polling off this driver's own background thread, and far more
//     hardened against device quirks.
//
// Both entry points mirror UvcDriver's is_open()/read_frame()/get_format()/
// get_width()/get_height()/close_device() shape, so HardwareHub's video-poll
// loop doesn't need to know or care which driver is behind it.
//
// Isochronous URB submission/reaping runs on a dedicated background thread
// (blocking USBDEVFS_REAPURB, not a polling loop) so read_frame() is cheap
// and this never competes with the render thread for frame-time budget --
// important since, as a fallback for the V4L2 path, this may end up
// carrying the Video window's entire frame rate.
//
// Scope: MJPEG only (parses VS_FORMAT_MJPEG/VS_FRAME_MJPEG descriptors).
// Uncompressed (YUY2 etc.) UVC formats are not parsed; a camera that only
// offers uncompressed streaming will fail to open here, same as it would
// be skipped on Linux if MJPEG weren't available (see UvcDriver).
class UvcUsbfsDriver : public godot::RefCounted {
	GDCLASS(UvcUsbfsDriver, godot::RefCounted)

protected:
	static void _bind_methods();

private:
	int fd = -1;
	bool owns_fd = false; // true if we opened the node ourselves (open_from_path) and must close() it
	int vs_interface_number = -1;
	int chosen_alt_setting = -1;
	int endpoint_address = -1;
	int max_packet_size = 0;
	int width = 0;
	int height = 0;

	static constexpr int NUM_URBS = 8;
	static constexpr int PACKETS_PER_URB = 32;
	std::vector<usbdevfs_urb *> urbs;

	std::thread reader_thread;
	std::atomic<bool> running{ false };
	std::mutex frame_mutex;

	// Incremental frame assembly state, touched only from the reader thread
	// except for pending_frame, which read_frame() also consumes -- guarded
	// by frame_mutex.
	std::vector<uint8_t> frame_buffer;
	int current_fid = -1;
	std::vector<uint8_t> pending_frame;

	struct FrameCandidate {
		uint8_t format_index;
		uint8_t frame_index;
		int width;
		int height;
		uint32_t default_interval;
	};
	struct AltCandidate {
		int alt_setting;
		int endpoint_address;
		int max_packet_size;
	};

	bool parse_descriptors(const uint8_t *desc, int len, int want_width, int want_height,
			FrameCandidate &out_frame, std::vector<AltCandidate> &out_alts);
	bool open_common(const godot::PackedByteArray &raw_descriptors, int want_width, int want_height);
	bool negotiate_and_start(const FrameCandidate &frame, const std::vector<AltCandidate> &alts);
	void submit_all_urbs();
	void process_packet(const uint8_t *data, int len);
	void reader_thread_main();

public:
	~UvcUsbfsDriver();

	// fd is owned by the caller (e.g. Android's UsbDeviceConnection); never closed here.
	bool open_from_fd(int p_fd, const godot::PackedByteArray &raw_descriptors, int want_width, int want_height);
	// Opens dev_node_path itself (e.g. "/dev/bus/usb/001/005") and reads
	// descriptors_sysfs_path (e.g. the sysfs "descriptors" file) for the
	// raw descriptor blob -- the Linux-native fallback path, no Android
	// plumbing involved. Owns and closes the fd itself.
	bool open_from_path(const godot::String &dev_node_path, const godot::String &descriptors_sysfs_path, int want_width, int want_height);
	void close_device();
	bool is_open() const;

	int get_width() const;
	int get_height() const;
	godot::String get_format() const; // always "mjpeg" once open

	// Returns the most recently completed JPEG frame, or an empty array if
	// none is ready yet. Cheap: just drains a mutex-protected slot the
	// background reader thread fills.
	godot::PackedByteArray read_frame();
};

} // namespace fpvr

#endif // FPVR_UVC_USBFS_DRIVER_H
