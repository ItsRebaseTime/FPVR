#include "uvc_driver.h"

#include <godot_cpp/core/class_db.hpp>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

using namespace godot;
using namespace fpvr;

void UvcDriver::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open_device", "path", "want_width", "want_height"), &UvcDriver::open_device);
	ClassDB::bind_method(D_METHOD("close_device"), &UvcDriver::close_device);
	ClassDB::bind_method(D_METHOD("is_open"), &UvcDriver::is_open);
	ClassDB::bind_method(D_METHOD("get_width"), &UvcDriver::get_width);
	ClassDB::bind_method(D_METHOD("get_height"), &UvcDriver::get_height);
	ClassDB::bind_method(D_METHOD("get_format"), &UvcDriver::get_format);
	ClassDB::bind_method(D_METHOD("read_frame"), &UvcDriver::read_frame);
}

UvcDriver::~UvcDriver() {
	close_device();
}

namespace {
int xioctl(int fd, unsigned long request, void *arg) {
	int r;
	do {
		r = ioctl(fd, request, arg);
	} while (r == -1 && errno == EINTR);
	return r;
}

uint8_t clip_u8(int v) {
	return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
}
} // namespace

bool UvcDriver::open_device(const String &path, int want_width, int want_height) {
	close_device();

	fd = open(path.utf8().get_data(), O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		return false;
	}

	struct v4l2_capability cap;
	memset(&cap, 0, sizeof(cap));
	if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0 || !(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE) || !(cap.capabilities & V4L2_CAP_STREAMING)) {
		close_device();
		return false;
	}

	// YUYV first: it costs one cheap per-pixel YUV->RGB pass right here
	// (below), entirely avoiding a full software JPEG decode
	// (Image::load_jpg_from_buffer, libjpeg-turbo on the CPU) every
	// single frame -- real, continuous CPU work MJPEG requires that
	// YUYV simply doesn't. Both paths already ride the same kernel-
	// driven, interrupt-completion, mmap'd zero-copy V4L2 buffers, so
	// this is purely about skipping decode work, not USB/driver
	// overhead. Falls back to MJPEG only if the device doesn't offer
	// YUYV at the requested resolution (some USB2.0 analog FPV
	// receivers only have the USB bandwidth for MJPEG at useful
	// resolutions/framerates).
	uint32_t try_formats[] = { V4L2_PIX_FMT_YUYV, V4L2_PIX_FMT_MJPEG };
	bool format_set = false;
	for (uint32_t fmt : try_formats) {
		struct v4l2_format format;
		memset(&format, 0, sizeof(format));
		format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		format.fmt.pix.width = want_width;
		format.fmt.pix.height = want_height;
		format.fmt.pix.pixelformat = fmt;
		format.fmt.pix.field = V4L2_FIELD_ANY;
		if (xioctl(fd, VIDIOC_S_FMT, &format) == 0 && format.fmt.pix.pixelformat == fmt) {
			width = format.fmt.pix.width;
			height = format.fmt.pix.height;
			pixel_format = fmt;
			format_set = true;
			break;
		}
	}
	if (!format_set) {
		close_device();
		return false;
	}

	struct v4l2_requestbuffers req;
	memset(&req, 0, sizeof(req));
	req.count = 4;
	req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 1) {
		close_device();
		return false;
	}

	buffers.resize(req.count);
	for (uint32_t i = 0; i < req.count; i++) {
		struct v4l2_buffer buf;
		memset(&buf, 0, sizeof(buf));
		buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		buf.memory = V4L2_MEMORY_MMAP;
		buf.index = i;
		if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
			close_device();
			return false;
		}
		buffers[i].length = buf.length;
		buffers[i].start = mmap(nullptr, buf.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, buf.m.offset);
		if (buffers[i].start == MAP_FAILED) {
			buffers[i].start = nullptr;
			close_device();
			return false;
		}
		if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
			close_device();
			return false;
		}
	}

	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
		close_device();
		return false;
	}

	return true;
}

void UvcDriver::unmap_all() {
	for (auto &b : buffers) {
		if (b.start != nullptr) {
			munmap(b.start, b.length);
			b.start = nullptr;
		}
	}
	buffers.clear();
}

void UvcDriver::close_device() {
	if (fd >= 0) {
		int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		xioctl(fd, VIDIOC_STREAMOFF, &type);
	}
	unmap_all();
	if (fd >= 0) {
		close(fd);
		fd = -1;
	}
	width = 0;
	height = 0;
	pixel_format = 0;
}

bool UvcDriver::is_open() const {
	return fd >= 0;
}

int UvcDriver::get_width() const {
	return width;
}

int UvcDriver::get_height() const {
	return height;
}

String UvcDriver::get_format() const {
	return pixel_format == V4L2_PIX_FMT_MJPEG ? String("mjpeg") : String("rgb8");
}

PackedByteArray UvcDriver::read_frame() {
	PackedByteArray out;
	if (fd < 0) {
		return out;
	}

	struct v4l2_buffer buf;
	memset(&buf, 0, sizeof(buf));
	buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	buf.memory = V4L2_MEMORY_MMAP;
	if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
		return out; // EAGAIN (no frame yet) or a transient error; caller retries next tick
	}

	const uint8_t *src = static_cast<const uint8_t *>(buffers[buf.index].start);

	if (pixel_format == V4L2_PIX_FMT_MJPEG) {
		out.resize(buf.bytesused);
		memcpy(out.ptrw(), src, buf.bytesused);
	} else { // YUYV -> RGB8
		out.resize(static_cast<int64_t>(width) * height * 3);
		uint8_t *dst = out.ptrw();
		int pixel_count = width * height;
		for (int i = 0; i < pixel_count; i += 2) {
			int o = i * 2; // 4 bytes (Y0 U Y1 V) per 2 pixels
			int y0 = src[o + 0];
			int u = src[o + 1];
			int y1 = src[o + 2];
			int v = src[o + 3];
			int c0 = y0 - 16;
			int c1 = y1 - 16;
			int d = u - 128;
			int e = v - 128;

			int di = i * 3;
			dst[di + 0] = clip_u8((298 * c0 + 409 * e + 128) >> 8);
			dst[di + 1] = clip_u8((298 * c0 - 100 * d - 208 * e + 128) >> 8);
			dst[di + 2] = clip_u8((298 * c0 + 516 * d + 128) >> 8);

			dst[di + 3] = clip_u8((298 * c1 + 409 * e + 128) >> 8);
			dst[di + 4] = clip_u8((298 * c1 - 100 * d - 208 * e + 128) >> 8);
			dst[di + 5] = clip_u8((298 * c1 + 516 * d + 128) >> 8);
		}
	}

	xioctl(fd, VIDIOC_QBUF, &buf);
	return out;
}
