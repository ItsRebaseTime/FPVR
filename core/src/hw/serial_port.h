#ifndef FPVR_SERIAL_PORT_H
#define FPVR_SERIAL_PORT_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace fpvr {

// Minimal POSIX termios serial backend. One instance owns one tty fd.
class SerialPort : public godot::RefCounted {
	GDCLASS(SerialPort, godot::RefCounted)

protected:
	static void _bind_methods();

private:
	int fd = -1;

public:
	~SerialPort();

	bool open_port(const godot::String &path, int baud);
	void close_port();
	bool is_open() const;

	// Non-blocking: returns whatever bytes are currently available, or an
	// empty array if none/closed.
	godot::PackedByteArray read_available(int max_bytes = 4096);
	int write_bytes(const godot::PackedByteArray &bytes);
};

} // namespace fpvr

#endif // FPVR_SERIAL_PORT_H
