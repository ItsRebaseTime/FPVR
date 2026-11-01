#include "serial_port.h"

#include <godot_cpp/core/class_db.hpp>

#include <cerrno>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

using namespace godot;
using namespace fpvr;

void SerialPort::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open_port", "path", "baud"), &SerialPort::open_port);
	ClassDB::bind_method(D_METHOD("close_port"), &SerialPort::close_port);
	ClassDB::bind_method(D_METHOD("is_open"), &SerialPort::is_open);
	ClassDB::bind_method(D_METHOD("read_available", "max_bytes"), &SerialPort::read_available, DEFVAL(4096));
	ClassDB::bind_method(D_METHOD("write_bytes", "bytes"), &SerialPort::write_bytes);
}

SerialPort::~SerialPort() {
	close_port();
}

namespace {
speed_t baud_to_speed(int baud) {
	switch (baud) {
		case 9600: return B9600;
		case 19200: return B19200;
		case 38400: return B38400;
		case 57600: return B57600;
		case 115200: return B115200;
		case 230400: return B230400;
		case 420000: return B460800; // closest standard rate; ELRS backpack often uses 420k/400k over USB-CDC which ignores real baud anyway
		case 460800: return B460800;
		case 921600: return B921600;
		default: return B115200;
	}
}
} // namespace

bool SerialPort::open_port(const String &path, int baud) {
	close_port();

	fd = open(path.utf8().get_data(), O_RDWR | O_NOCTTY | O_NONBLOCK);
	if (fd < 0) {
		return false;
	}

	struct termios tty;
	if (tcgetattr(fd, &tty) != 0) {
		close(fd);
		fd = -1;
		return false;
	}

	speed_t speed = baud_to_speed(baud);
	cfsetispeed(&tty, speed);
	cfsetospeed(&tty, speed);

	tty.c_cflag &= ~PARENB;
	tty.c_cflag &= ~CSTOPB;
	tty.c_cflag &= ~CSIZE;
	tty.c_cflag |= CS8;
	tty.c_cflag &= ~CRTSCTS;
	tty.c_cflag |= CREAD | CLOCAL;

	cfmakeraw(&tty);

	tty.c_cc[VMIN] = 0;
	tty.c_cc[VTIME] = 0;

	if (tcsetattr(fd, TCSANOW, &tty) != 0) {
		close(fd);
		fd = -1;
		return false;
	}

	return true;
}

void SerialPort::close_port() {
	if (fd >= 0) {
		close(fd);
		fd = -1;
	}
}

bool SerialPort::is_open() const {
	return fd >= 0;
}

PackedByteArray SerialPort::read_available(int max_bytes) {
	PackedByteArray out;
	if (fd < 0 || max_bytes <= 0) {
		return out;
	}

	out.resize(max_bytes);
	ssize_t n = read(fd, out.ptrw(), max_bytes);
	if (n <= 0) {
		out.resize(0);
		return out;
	}
	out.resize(n);
	return out;
}

int SerialPort::write_bytes(const PackedByteArray &bytes) {
	if (fd < 0 || bytes.size() == 0) {
		return 0;
	}
	ssize_t n = write(fd, bytes.ptr(), bytes.size());
	return n < 0 ? 0 : static_cast<int>(n);
}
