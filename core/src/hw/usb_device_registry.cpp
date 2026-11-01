#include "usb_device_registry.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <set>
#include <string>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

using namespace godot;
using namespace fpvr;

void UsbDeviceRegistry::_bind_methods() {
	ClassDB::bind_method(D_METHOD("scan"), &UsbDeviceRegistry::scan);
}

namespace {

// Resolves the symlink at /sys/class/<class>/<name>/device and checks that
// the real path passes through a "usb" bus directory, which is how we tell
// USB-attached hardware apart from anything built into the host.
bool is_usb_backed(const std::string &sysfs_class, const std::string &name) {
	std::string link_path = "/sys/class/" + sysfs_class + "/" + name + "/device";
	char resolved[PATH_MAX];
	if (realpath(link_path.c_str(), resolved) == nullptr) {
		return false;
	}
	std::string real(resolved);
	return real.find("/usb") != std::string::npos;
}

// Plain POSIX read rather than std::ifstream: iostreams pull in the C++
// locale machinery, which is fragile across this GDExtension's dlopen
// boundary -- confirmed via gdb backtrace crashing inside
// std::locale::_Impl::~_Impl() with heap corruption on the second
// ifstream used in a run. Every other file in this codebase already
// avoids iostreams for exactly this kind of reason; this was the one
// place that didn't.
std::string read_sysfs_trimmed(const std::string &path) {
	int fd = open(path.c_str(), O_RDONLY);
	if (fd < 0) {
		return "";
	}
	char buf[256];
	ssize_t n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) {
		return "";
	}
	buf[n] = '\0';
	std::string line(buf);
	size_t newline = line.find('\n');
	if (newline != std::string::npos) {
		line.resize(newline);
	}
	while (!line.empty() && line.back() == ' ') {
		line.pop_back();
	}
	return line;
}

bool device_has_video4linux_child(const std::string &device_dir) {
	DIR *dir = opendir(device_dir.c_str());
	if (dir == nullptr) {
		return false;
	}
	bool found = false;
	struct dirent *entry;
	while ((entry = readdir(dir)) != nullptr) {
		std::string name(entry->d_name);
		// Direct video4linux child (device itself is the video interface)
		// or a video4linux dir nested under one of this device's own
		// interface subdirectories (name starts with the device dir's own
		// basename followed by ':').
		std::string sub = device_dir + "/" + name + "/video4linux";
		struct stat st;
		if (stat(sub.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
			found = true;
			break;
		}
	}
	closedir(dir);
	return found;
}

} // namespace

Array UsbDeviceRegistry::scan() {
	Array results;

	// Serial candidates: CDC-ACM (ttyACM*) and USB-serial chips (ttyUSB*).
	// Any of these could be the GPS receiver or the ELRS TX/RX; the actual
	// protocol is identified later by GpsDriver/ElrsDriver sniffing the
	// byte stream, not here.
	{
		DIR *dir = opendir("/dev");
		if (dir != nullptr) {
			struct dirent *entry;
			while ((entry = readdir(dir)) != nullptr) {
				std::string name(entry->d_name);
				bool is_serial_candidate = name.rfind("ttyACM", 0) == 0 || name.rfind("ttyUSB", 0) == 0;
				if (!is_serial_candidate) {
					continue;
				}
				if (!is_usb_backed("tty", name)) {
					continue;
				}
				Dictionary d;
				d["path"] = String("/dev/") + String(name.c_str());
				d["kind"] = String("serial");
				d["name"] = String(name.c_str());
				results.append(d);
			}
			closedir(dir);
		}
	}

	// UVC video candidates: /dev/video* nodes that both support video
	// capture and report a "usb:" bus_info string via VIDIOC_QUERYCAP.
	{
		DIR *dir = opendir("/dev");
		if (dir != nullptr) {
			int total_video_nodes = 0;
			int usb_backed_nodes = 0;
			struct dirent *entry;
			while ((entry = readdir(dir)) != nullptr) {
				std::string name(entry->d_name);
				if (name.rfind("video", 0) != 0) {
					continue;
				}
				total_video_nodes++;
				if (!is_usb_backed("video4linux", name)) {
					continue;
				}
				usb_backed_nodes++;
				std::string path = "/dev/" + name;
				int fd = open(path.c_str(), O_RDWR | O_NONBLOCK);
				if (fd < 0) {
					UtilityFunctions::print("UsbDeviceRegistry: open() of ", String(path.c_str()), " failed errno=", errno, " (", strerror(errno), ") -- likely a permission problem; the node is usually root:video 0660, so the user running this app needs to be in the \"video\" group.");
					continue;
				}
				struct v4l2_capability cap;
				memset(&cap, 0, sizeof(cap));
				bool ok = ioctl(fd, VIDIOC_QUERYCAP, &cap) == 0 &&
						(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE) &&
						strstr(reinterpret_cast<const char *>(cap.bus_info), "usb") != nullptr;
				close(fd);
				if (!ok) {
					UtilityFunctions::print("UsbDeviceRegistry: ", String(path.c_str()), " opened but VIDIOC_QUERYCAP rejected it (no V4L2_CAP_VIDEO_CAPTURE and/or bus_info isn't \"usb...\") -- likely a metadata-only node alongside the real capture node.");
					continue;
				}
				Dictionary d;
				d["path"] = String(path.c_str());
				d["kind"] = String("uvc");
				d["name"] = String(reinterpret_cast<const char *>(cap.card));
				results.append(d);
			}
			closedir(dir);
			if (total_video_nodes != last_logged_total_video_nodes || usb_backed_nodes != last_logged_usb_backed_nodes) {
				last_logged_total_video_nodes = total_video_nodes;
				last_logged_usb_backed_nodes = usb_backed_nodes;
				UtilityFunctions::print("UsbDeviceRegistry: /dev scan saw ", total_video_nodes, " video* node(s), ", usb_backed_nodes, " resolved to a USB bus via sysfs.");
			}
		}
	}

	// UVC devices with no kernel driver bound: walk sysfs for USB
	// interfaces claiming class 0x0e (video) whose parent device has no
	// video4linux child anywhere -- e.g. Steam Frame's current OS, which
	// doesn't ship the uvcvideo kernel module. UvcUsbfsDriver can still
	// talk to these directly; this is purely discovery, done without ever
	// opening the device node (sysfs attribute files are plain text reads).
	{
		const std::string base = "/sys/bus/usb/devices";
		DIR *dir = opendir(base.c_str());
		if (dir != nullptr) {
			std::set<std::string> seen_devices;
			struct dirent *entry;
			while ((entry = readdir(dir)) != nullptr) {
				std::string name(entry->d_name);
				size_t colon = name.find(':');
				if (colon == std::string::npos) {
					continue; // not an interface entry (e.g. "1-2", not "1-2:1.0")
				}
				std::string iface_path = base + "/" + name;
				std::string class_str = read_sysfs_trimmed(iface_path + "/bInterfaceClass");
				if (class_str != "0e" && class_str != "0x0e") {
					continue;
				}
				std::string device_name = name.substr(0, colon);
				if (seen_devices.count(device_name) > 0) {
					continue;
				}
				seen_devices.insert(device_name);

				std::string device_dir = base + "/" + device_name;
				if (device_has_video4linux_child(device_dir)) {
					continue; // already surfaced via the /dev/video* scan above
				}

				std::string busnum = read_sysfs_trimmed(device_dir + "/busnum");
				std::string devnum = read_sysfs_trimmed(device_dir + "/devnum");
				if (busnum.empty() || devnum.empty()) {
					continue;
				}
				char dev_path[64];
				snprintf(dev_path, sizeof(dev_path), "/dev/bus/usb/%03d/%03d", atoi(busnum.c_str()), atoi(devnum.c_str()));

				std::string product = read_sysfs_trimmed(device_dir + "/product");
				if (product.empty()) {
					product = "USB video device (no kernel driver)";
				}

				Dictionary d;
				d["path"] = String(dev_path);
				d["kind"] = String("uvc_no_kernel_driver");
				d["name"] = String(product.c_str());
				d["descriptors_path"] = String((device_dir + "/descriptors").c_str());
				results.append(d);
			}
			closedir(dir);
		}
	}

	return results;
}
