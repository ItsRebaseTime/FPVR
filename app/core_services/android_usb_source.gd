extends RefCounted
## Wraps one USB CDC-ACM serial device opened through the FpvrPlugin Android
## plugin (UsbManager-based, since stock Android blocks the raw /dev access
## SerialPort uses on Linux). Implements the same is_open/read_available/
## write_bytes/close shape as SerialPort so HardwareHub's main loop and
## classification logic don't need to know which platform opened the port.

var _plugin
var device_id: int
var _open := false

func _init(plugin, p_device_id: int) -> void:
	_plugin = plugin
	device_id = p_device_id

func mark_opened() -> void:
	_open = true

func is_open() -> bool:
	return _open

func read_available() -> PackedByteArray:
	if not _open:
		return PackedByteArray()
	return _plugin.readUsbSerialBytes(device_id)

func write_bytes(bytes: PackedByteArray) -> int:
	if not _open:
		return 0
	return _plugin.writeUsbSerialBytes(device_id, bytes)

func close_port() -> void:
	if _open:
		_plugin.closeUsbSerialDevice(device_id)
	_open = false
