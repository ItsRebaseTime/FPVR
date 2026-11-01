#ifndef FPVR_UVC_DRIVER_H
#define FPVR_UVC_DRIVER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <vector>

namespace fpvr {

// V4L2 mmap-streaming capture from a UVC webcam. Prefers MJPEG (decoded on
// the Godot side with Image.load_jpg_from_buffer -- cheap and avoids
// shipping a JPEG decoder here); falls back to YUYV, which this class
// converts to RGB8 itself since Godot has no built-in YUYV loader.
class UvcDriver : public godot::RefCounted {
	GDCLASS(UvcDriver, godot::RefCounted)

protected:
	static void _bind_methods();

private:
	struct MappedBuffer {
		void *start = nullptr;
		size_t length = 0;
	};

	int fd = -1;
	int width = 0;
	int height = 0;
	uint32_t pixel_format = 0; // V4L2_PIX_FMT_MJPEG or V4L2_PIX_FMT_YUYV
	std::vector<MappedBuffer> buffers;

	void unmap_all();

public:
	~UvcDriver();

	// Tries MJPEG first at the requested size, then YUYV, then whatever the
	// driver defaults to. Returns false if the device can't be opened/streamed.
	bool open_device(const godot::String &path, int want_width, int want_height);
	void close_device();
	bool is_open() const;

	int get_width() const;
	int get_height() const;
	// "mjpeg" or "rgb8" -- rgb8 is already-converted YUYV->RGB, width*height*3 bytes.
	godot::String get_format() const;

	// Non-blocking; returns an empty array if no frame is ready yet.
	godot::PackedByteArray read_frame();
};

} // namespace fpvr

#endif // FPVR_UVC_DRIVER_H
