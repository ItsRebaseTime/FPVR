extends Node
## Converts a normalized flight-input dictionary (from whichever input
## backend is active -- Steam Frame controllers or a generic gamepad) into
## CRSF channel values and writes them through HardwareHub. The backend is
## injected via set_backend(), so swapping input hardware never touches
## this class.
##
## Mode-2-style mapping, matching the architecture plan:
##   ch0 roll, ch1 pitch, ch2 throttle, ch3 yaw, ch4 arm, ch5 flight mode, ch6 RTH

const CH_MIN := 172
const CH_MID := 992
const CH_MAX := 1811
const MODE_COUNT := 3

signal passthrough_cycle_requested
signal fpv_view_toggle_requested
signal menu_toggle_requested

var backend = null

var _armed := false
var _mode_index := 0
var _prev_arm_pressed := false
var _prev_mode_pressed := false
var _prev_passthrough_pressed := false
var _prev_fpv_view_toggle_pressed := false
var _prev_menu_toggle_pressed := false

func set_backend(new_backend) -> void:
	backend = new_backend

func _process(_delta: float) -> void:
	if backend == null:
		return
	var inp: Dictionary = backend.poll()

	var channels: Array = []
	channels.resize(16)
	channels.fill(CH_MID)

	channels[0] = _axis_to_channel(inp.get("roll", 0.0))
	channels[1] = _axis_to_channel(inp.get("pitch", 0.0))
	channels[2] = roundi(lerp(float(CH_MIN), float(CH_MAX), inp.get("throttle", 0.0)))
	channels[3] = _axis_to_channel(inp.get("yaw", 0.0))

	var arm_pressed: bool = inp.get("arm_pressed", false)
	if arm_pressed and not _prev_arm_pressed:
		_armed = not _armed
	_prev_arm_pressed = arm_pressed
	channels[4] = CH_MAX if _armed else CH_MIN

	var mode_pressed: bool = inp.get("mode_cycle_pressed", false)
	if mode_pressed and not _prev_mode_pressed:
		_mode_index = (_mode_index + 1) % MODE_COUNT
	_prev_mode_pressed = mode_pressed
	channels[5] = roundi(lerp(float(CH_MIN), float(CH_MAX), float(_mode_index) / float(MODE_COUNT - 1)))

	channels[6] = CH_MAX if inp.get("rth_pressed", false) else CH_MIN

	var passthrough_pressed: bool = inp.get("passthrough_cycle_pressed", false)
	if passthrough_pressed and not _prev_passthrough_pressed:
		passthrough_cycle_requested.emit()
	_prev_passthrough_pressed = passthrough_pressed

	var fpv_view_toggle_pressed: bool = inp.get("fpv_view_toggle_pressed", false)
	if fpv_view_toggle_pressed and not _prev_fpv_view_toggle_pressed:
		fpv_view_toggle_requested.emit()
	_prev_fpv_view_toggle_pressed = fpv_view_toggle_pressed

	var menu_toggle_pressed: bool = inp.get("menu_toggle_pressed", false)
	if menu_toggle_pressed and not _prev_menu_toggle_pressed:
		menu_toggle_requested.emit()
	_prev_menu_toggle_pressed = menu_toggle_pressed

	HardwareHub.send_uav_channels(channels)

func is_armed() -> bool:
	return _armed

func _axis_to_channel(v: float) -> int:
	return roundi(lerp(float(CH_MIN), float(CH_MAX), (clampf(v, -1.0, 1.0) + 1.0) / 2.0))
