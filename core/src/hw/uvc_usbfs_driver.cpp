#include "uvc_usbfs_driver.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <linux/usbdevice_fs.h>
#include <sys/ioctl.h>
#include <unistd.h>

using namespace godot;
using namespace fpvr;

namespace {
constexpr uint8_t USB_DT_INTERFACE = 0x04;
constexpr uint8_t USB_DT_ENDPOINT = 0x05;
constexpr uint8_t USB_DT_CS_INTERFACE = 0x24;
constexpr uint8_t USB_CLASS_VIDEO = 0x0E;
constexpr uint8_t UVC_SC_VIDEOSTREAMING = 0x02;
constexpr uint8_t UVC_VS_FORMAT_MJPEG = 0x06;
constexpr uint8_t UVC_VS_FRAME_MJPEG = 0x07;
constexpr uint8_t USB_ENDPOINT_XFER_ISOC = 0x01;

constexpr uint8_t UVC_VS_PROBE_CONTROL = 0x01;
constexpr uint8_t UVC_VS_COMMIT_CONTROL = 0x02;
constexpr uint8_t UVC_SET_CUR = 0x01;
constexpr uint8_t UVC_GET_CUR = 0x81;

constexpr int PROBE_COMMIT_LEN = 26;

uint16_t read_u16_le(const uint8_t *p) {
	return static_cast<uint16_t>(p[0] | (p[1] << 8));
}
uint32_t read_u32_le(const uint8_t *p) {
	return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
			(static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
void write_u16_le(uint8_t *p, uint16_t v) {
	p[0] = v & 0xFF;
	p[1] = (v >> 8) & 0xFF;
}
void write_u32_le(uint8_t *p, uint32_t v) {
	p[0] = v & 0xFF;
	p[1] = (v >> 8) & 0xFF;
	p[2] = (v >> 16) & 0xFF;
	p[3] = (v >> 24) & 0xFF;
}
} // namespace

void UvcUsbfsDriver::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open_from_fd", "fd", "raw_descriptors", "want_width", "want_height"), &UvcUsbfsDriver::open_from_fd);
	ClassDB::bind_method(D_METHOD("open_from_path", "dev_node_path", "descriptors_sysfs_path", "want_width", "want_height"), &UvcUsbfsDriver::open_from_path);
	ClassDB::bind_method(D_METHOD("close_device"), &UvcUsbfsDriver::close_device);
	ClassDB::bind_method(D_METHOD("is_open"), &UvcUsbfsDriver::is_open);
	ClassDB::bind_method(D_METHOD("get_width"), &UvcUsbfsDriver::get_width);
	ClassDB::bind_method(D_METHOD("get_height"), &UvcUsbfsDriver::get_height);
	ClassDB::bind_method(D_METHOD("get_format"), &UvcUsbfsDriver::get_format);
	ClassDB::bind_method(D_METHOD("read_frame"), &UvcUsbfsDriver::read_frame);
}

UvcUsbfsDriver::~UvcUsbfsDriver() {
	close_device();
}

bool UvcUsbfsDriver::is_open() const {
	return fd >= 0 && !urbs.empty();
}

int UvcUsbfsDriver::get_width() const {
	return width;
}

int UvcUsbfsDriver::get_height() const {
	return height;
}

String UvcUsbfsDriver::get_format() const {
	return String("mjpeg");
}

// Generic TLV walk of the raw USB descriptor set (device + all config/
// interface/endpoint/class-specific descriptors concatenated, exactly what
// UsbDeviceConnection.getRawDescriptors() returns on Android, or what
// reading a usbfs device node returns on desktop Linux). We only read
// fixed-offset fields within each descriptor and always advance by its own
// bLength, so the variable-length trailing frame-interval list on
// VS_FRAME_MJPEG descriptors never needs to be parsed.
bool UvcUsbfsDriver::parse_descriptors(const uint8_t *desc, int len, int want_width, int want_height,
		FrameCandidate &out_frame, std::vector<AltCandidate> &out_alts) {
	int pos = 0;
	int current_interface_number = -1;
	int current_alt_setting = -1;
	uint8_t current_class = 0;
	uint8_t current_subclass = 0;
	int found_vs_interface = -1;

	std::vector<FrameCandidate> frames;
	uint8_t last_mjpeg_format_index = 0;
	bool have_format = false;

	while (pos + 2 <= len) {
		uint8_t dlen = desc[pos];
		uint8_t dtype = desc[pos + 1];
		if (dlen < 2 || pos + dlen > len) {
			break;
		}

		if (dtype == USB_DT_INTERFACE && dlen >= 9) {
			current_interface_number = desc[pos + 2];
			current_alt_setting = desc[pos + 3];
			current_class = desc[pos + 5];
			current_subclass = desc[pos + 6];
			if (current_class == USB_CLASS_VIDEO && current_subclass == UVC_SC_VIDEOSTREAMING) {
				if (found_vs_interface == -1) {
					found_vs_interface = current_interface_number;
				}
			}
		} else if (dtype == USB_DT_CS_INTERFACE && current_class == USB_CLASS_VIDEO &&
				current_subclass == UVC_SC_VIDEOSTREAMING) {
			uint8_t subtype = desc[pos + 2];
			if (subtype == UVC_VS_FORMAT_MJPEG && dlen >= 5) {
				last_mjpeg_format_index = desc[pos + 3];
				have_format = true;
			} else if (subtype == UVC_VS_FRAME_MJPEG && dlen >= 25 && have_format) {
				FrameCandidate fc;
				fc.format_index = last_mjpeg_format_index;
				fc.frame_index = desc[pos + 3];
				fc.width = read_u16_le(desc + pos + 5);
				fc.height = read_u16_le(desc + pos + 7);
				fc.default_interval = read_u32_le(desc + pos + 21);
				frames.push_back(fc);
			}
		} else if (dtype == USB_DT_ENDPOINT && dlen >= 7 && current_interface_number == found_vs_interface) {
			uint8_t ep_addr = desc[pos + 2];
			uint8_t attrs = desc[pos + 3];
			if ((attrs & 0x03) == USB_ENDPOINT_XFER_ISOC) {
				uint16_t wmax_raw = read_u16_le(desc + pos + 4);
				int base = wmax_raw & 0x7FF;
				int mult = 1 + ((wmax_raw >> 11) & 0x3);
				AltCandidate ac;
				ac.alt_setting = current_alt_setting;
				ac.endpoint_address = ep_addr;
				ac.max_packet_size = base * mult;
				out_alts.push_back(ac);
			}
		}

		pos += dlen;
	}

	vs_interface_number = found_vs_interface;
	UtilityFunctions::print("UvcUsbfsDriver: parsed descriptors len=", len, " vs_iface=", vs_interface_number,
			" frames=", static_cast<int>(frames.size()), " isoc_alts=", static_cast<int>(out_alts.size()));
	if (vs_interface_number == -1 || frames.empty() || out_alts.empty()) {
		return false;
	}

	// Prefer an exact resolution match; otherwise take the first (device-default) frame.
	out_frame = frames[0];
	for (const FrameCandidate &fc : frames) {
		if (fc.width == want_width && fc.height == want_height) {
			out_frame = fc;
			break;
		}
	}
	return true;
}


bool UvcUsbfsDriver::negotiate_and_start(const FrameCandidate &frame, const std::vector<AltCandidate> &alts) {
	// On Android, interface claiming already happened on the Java side
	// (FpvrPlugin.claimVideoStreamingInterface(), via
	// UsbDeviceConnection.claimInterface()) before this fd ever reached us --
	// a raw USBDEVFS_CLAIMINTERFACE ioctl from here was observed failing
	// with EBUSY on real hardware even as the very first attempt. There's
	// no Java-side equivalent on Linux (owns_fd == true, opened via
	// open_from_path), so we claim it here instead; DISCONNECT_CLAIM
	// force-detaches a kernel driver if one is bound (e.g. uvcvideo
	// manually loaded but this exact device not otherwise in use).
	if (owns_fd) {
		unsigned int iface = static_cast<unsigned int>(vs_interface_number);
		if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &iface) != 0) {
			struct usbdevfs_disconnect_claim dc;
			memset(&dc, 0, sizeof(dc));
			dc.interface = iface;
			dc.flags = USBDEVFS_DISCONNECT_CLAIM_IF_DRIVER;
			if (ioctl(fd, USBDEVFS_DISCONNECT_CLAIM, &dc) != 0) {
				UtilityFunctions::print("UvcUsbfsDriver: CLAIMINTERFACE/DISCONNECT_CLAIM both failed errno=", errno, " (", strerror(errno), ")");
				return false;
			}
		}
	}

	uint8_t probe[PROBE_COMMIT_LEN];
	memset(probe, 0, sizeof(probe));
	write_u16_le(probe + 0, 0x0001); // bmHint: dwFrameInterval fixed
	probe[2] = frame.format_index;
	probe[3] = frame.frame_index;
	write_u32_le(probe + 4, frame.default_interval);

	struct usbdevfs_ctrltransfer ctrl;
	memset(&ctrl, 0, sizeof(ctrl));
	ctrl.bRequestType = 0x21; // host->device, class, interface
	ctrl.bRequest = UVC_SET_CUR;
	ctrl.wValue = static_cast<uint16_t>(UVC_VS_PROBE_CONTROL) << 8;
	ctrl.wIndex = static_cast<uint16_t>(vs_interface_number);
	ctrl.wLength = PROBE_COMMIT_LEN;
	ctrl.timeout = 1000;
	ctrl.data = probe;
	if (ioctl(fd, USBDEVFS_CONTROL, &ctrl) < 0) {
		UtilityFunctions::print("UvcUsbfsDriver: Probe SET_CUR failed errno=", errno, " (", strerror(errno), ")");
		return false;
	}

	uint8_t negotiated[PROBE_COMMIT_LEN];
	memset(negotiated, 0, sizeof(negotiated));
	ctrl.bRequestType = 0xA1; // device->host, class, interface
	ctrl.bRequest = UVC_GET_CUR;
	ctrl.data = negotiated;
	if (ioctl(fd, USBDEVFS_CONTROL, &ctrl) < 0) {
		// Some devices don't support GET_CUR readback cleanly; fall back to
		// what we asked for and hope the device honors it on Commit.
		memcpy(negotiated, probe, PROBE_COMMIT_LEN);
	}

	ctrl.bRequestType = 0x21;
	ctrl.bRequest = UVC_SET_CUR;
	ctrl.wValue = static_cast<uint16_t>(UVC_VS_COMMIT_CONTROL) << 8;
	ctrl.data = negotiated;
	if (ioctl(fd, USBDEVFS_CONTROL, &ctrl) < 0) {
		UtilityFunctions::print("UvcUsbfsDriver: Commit SET_CUR failed errno=", errno, " (", strerror(errno), ")");
		return false;
	}

	uint32_t max_payload = read_u32_le(negotiated + 22);
	UtilityFunctions::print("UvcUsbfsDriver: negotiated max_payload=", static_cast<int>(max_payload));

	// Pick the highest-bandwidth isochronous altsetting available. Simpler
	// and more reliably sufficient than hunting for the smallest altsetting
	// that still satisfies max_payload, at the cost of being a bit greedier
	// with USB bus bandwidth than strictly necessary -- fine for the single-
	// camera case this is built for.
	const AltCandidate *best = nullptr;
	for (const AltCandidate &ac : alts) {
		if (best == nullptr || ac.max_packet_size > best->max_packet_size) {
			best = &ac;
		}
	}
	if (best == nullptr || best->max_packet_size == 0) {
		return false;
	}
	if (max_payload > 0 && static_cast<uint32_t>(best->max_packet_size) < max_payload) {
		// Device wants more per-transfer bandwidth than any altsetting offers
		// per packet; still proceed (payload simply spans more packets/URBs),
		// since dwMaxPayloadTransferSize is advisory for packet sizing, not
		// a hard requirement enforced by every device.
	}

	chosen_alt_setting = best->alt_setting;
	endpoint_address = best->endpoint_address;
	max_packet_size = best->max_packet_size;
	width = frame.width;
	height = frame.height;

	UtilityFunctions::print("UvcUsbfsDriver: chosen alt=", chosen_alt_setting, " ep=", endpoint_address,
			" max_packet_size=", max_packet_size, " frame=", width, "x", height);

	struct usbdevfs_setinterface si;
	si.interface = static_cast<unsigned int>(vs_interface_number);
	si.altsetting = static_cast<unsigned int>(chosen_alt_setting);
	if (ioctl(fd, USBDEVFS_SETINTERFACE, &si) < 0) {
		UtilityFunctions::print("UvcUsbfsDriver: SETINTERFACE failed errno=", errno, " (", strerror(errno), ")");
		return false;
	}

	submit_all_urbs();
	UtilityFunctions::print("UvcUsbfsDriver: streaming started, ", static_cast<int>(urbs.size()), " URBs submitted");
	return true;
}

void UvcUsbfsDriver::submit_all_urbs() {
	urbs.clear();
	urbs.reserve(NUM_URBS);
	for (int i = 0; i < NUM_URBS; i++) {
		size_t urb_size = sizeof(usbdevfs_urb) + static_cast<size_t>(PACKETS_PER_URB) * sizeof(usbdevfs_iso_packet_desc);
		auto *urb = static_cast<usbdevfs_urb *>(malloc(urb_size));
		memset(urb, 0, urb_size);
		urb->type = USBDEVFS_URB_TYPE_ISO;
		urb->endpoint = static_cast<unsigned char>(endpoint_address);
		urb->flags = USBDEVFS_URB_ISO_ASAP;
		urb->buffer = malloc(static_cast<size_t>(PACKETS_PER_URB) * max_packet_size);
		urb->buffer_length = PACKETS_PER_URB * max_packet_size;
		urb->number_of_packets = PACKETS_PER_URB;
		for (int p = 0; p < PACKETS_PER_URB; p++) {
			urb->iso_frame_desc[p].length = static_cast<unsigned int>(max_packet_size);
		}
		urbs.push_back(urb);
		ioctl(fd, USBDEVFS_SUBMITURB, urb);
	}

	running.store(true);
	reader_thread = std::thread(&UvcUsbfsDriver::reader_thread_main, this);
}

void UvcUsbfsDriver::process_packet(const uint8_t *data, int len) {
	if (len < 2) {
		return;
	}
	uint8_t header_len = data[0];
	if (header_len < 2 || header_len > len) {
		return;
	}
	uint8_t header_info = data[1];
	int fid = header_info & 0x01;
	bool eof = (header_info & 0x02) != 0;

	if (current_fid == -1) {
		current_fid = fid;
		frame_buffer.clear();
	} else if (fid != current_fid) {
		// A new frame started without an explicit EOF on the previous one;
		// hand over whatever was collected so far rather than drop it.
		if (!frame_buffer.empty()) {
			pending_frame = frame_buffer;
		}
		frame_buffer.clear();
		current_fid = fid;
	}

	int payload_len = len - header_len;
	if (payload_len > 0) {
		frame_buffer.insert(frame_buffer.end(), data + header_len, data + header_len + payload_len);
	}

	if (eof) {
		if (!frame_buffer.empty()) {
			pending_frame = frame_buffer;
		}
		frame_buffer.clear();
		current_fid = -1;
	}
}

// Background thread: blocks on USBDEVFS_REAPURB (not a polling NDELAY loop)
// so it sleeps until the kernel actually has a completed isochronous URB,
// rather than burning render-thread time or CPU. Runs until close_device()
// flips `running` false and discards every outstanding URB, which wakes
// this thread's current blocking reap for each one.
void UvcUsbfsDriver::reader_thread_main() {
	while (running.load()) {
		void *completed = nullptr;
		if (ioctl(fd, USBDEVFS_REAPURB, &completed) != 0 || completed == nullptr) {
			if (errno == EINTR) {
				continue;
			}
			break; // fd closed/device gone
		}
		auto *urb = static_cast<usbdevfs_urb *>(completed);
		auto *buf = static_cast<uint8_t *>(urb->buffer);
		{
			std::lock_guard<std::mutex> lock(frame_mutex);
			for (int p = 0; p < urb->number_of_packets; p++) {
				unsigned int actual = urb->iso_frame_desc[p].actual_length;
				if (actual > 0) {
					process_packet(buf + p * max_packet_size, static_cast<int>(actual));
				}
			}
		}
		if (running.load()) {
			ioctl(fd, USBDEVFS_SUBMITURB, urb); // resubmit immediately for continuous capture
		}
	}
}

bool UvcUsbfsDriver::open_common(const PackedByteArray &raw_descriptors, int want_width, int want_height) {
	if (raw_descriptors.size() == 0) {
		return false;
	}
	FrameCandidate frame;
	std::vector<AltCandidate> alts;
	if (!parse_descriptors(raw_descriptors.ptr(), raw_descriptors.size(), want_width, want_height, frame, alts)) {
		return false;
	}
	return negotiate_and_start(frame, alts);
}

bool UvcUsbfsDriver::open_from_fd(int p_fd, const PackedByteArray &raw_descriptors, int want_width, int want_height) {
	close_device();
	if (p_fd < 0) {
		return false;
	}
	fd = p_fd;
	owns_fd = false; // Android/Java owns the fd lifetime
	if (!open_common(raw_descriptors, want_width, want_height)) {
		fd = -1;
		return false;
	}
	return true;
}

bool UvcUsbfsDriver::open_from_path(const String &dev_node_path, const String &descriptors_sysfs_path, int want_width, int want_height) {
	close_device();

	int desc_fd = open(descriptors_sysfs_path.utf8().get_data(), O_RDONLY);
	if (desc_fd < 0) {
		UtilityFunctions::print("UvcUsbfsDriver: open() of descriptors sysfs file failed for ", descriptors_sysfs_path, " errno=", errno, " (", strerror(errno), ")");
		return false;
	}
	PackedByteArray raw_descriptors;
	uint8_t buf[4096];
	ssize_t n;
	while ((n = read(desc_fd, buf, sizeof(buf))) > 0) {
		int64_t old_size = raw_descriptors.size();
		raw_descriptors.resize(old_size + n);
		memcpy(raw_descriptors.ptrw() + old_size, buf, n);
	}
	close(desc_fd);

	int dev_fd = open(dev_node_path.utf8().get_data(), O_RDWR);
	if (dev_fd < 0) {
		UtilityFunctions::print("UvcUsbfsDriver: open() of raw usbfs device node failed for ", dev_node_path, " errno=", errno, " (", strerror(errno), ") -- likely a permission problem; the node is usually root:root 0664 unless a udev rule grants access.");
		return false;
	}
	fd = dev_fd;
	owns_fd = true;
	if (!open_common(raw_descriptors, want_width, want_height)) {
		close(dev_fd);
		fd = -1;
		return false;
	}
	return true;
}

void UvcUsbfsDriver::close_device() {
	if (fd >= 0 && !urbs.empty()) {
		running.store(false);
		for (usbdevfs_urb *urb : urbs) {
			ioctl(fd, USBDEVFS_DISCARDURB, urb); // wakes the reader thread's blocking reap for each
		}
		if (reader_thread.joinable()) {
			reader_thread.join();
		}
		for (usbdevfs_urb *urb : urbs) {
			::free(urb->buffer);
			::free(urb);
		}
		urbs.clear();
	}
	if (owns_fd && fd >= 0) {
		close(fd);
	}
	fd = -1;
	owns_fd = false;
	vs_interface_number = -1;
	chosen_alt_setting = -1;
	endpoint_address = -1;
	max_packet_size = 0;
	width = 0;
	height = 0;
	frame_buffer.clear();
	pending_frame.clear();
	current_fid = -1;
}

PackedByteArray UvcUsbfsDriver::read_frame() {
	PackedByteArray out;
	if (fd < 0) {
		return out;
	}
	std::lock_guard<std::mutex> lock(frame_mutex);
	if (!pending_frame.empty()) {
		out.resize(static_cast<int64_t>(pending_frame.size()));
		memcpy(out.ptrw(), pending_frame.data(), pending_frame.size());
		pending_frame.clear();
	}
	return out;
}
