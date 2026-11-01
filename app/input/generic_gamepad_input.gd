extends RefCounted
## Flight-control input backend for a generic Bluetooth/USB HID gamepad
## (Xbox/PlayStation-style layout), used as the alternative to Steam Frame
## motion controllers. Same poll() -> Dictionary contract as
## SteamframeControllerInput so ControlMapper is agnostic to which is active.
##
## No spatial tracking, so this backend only ever drives flight control --
## the window arc, laser-pointer clicking, and the View/Menu toggles stay
## tied to the motion controllers' own tracking regardless of which
## backend is selected for flight.

const DEVICE_ID := 0

func poll() -> Dictionary:
	var left_x := Input.get_joy_axis(DEVICE_ID, JOY_AXIS_LEFT_X)
	var left_y := Input.get_joy_axis(DEVICE_ID, JOY_AXIS_LEFT_Y)
	var right_x := Input.get_joy_axis(DEVICE_ID, JOY_AXIS_RIGHT_X)
	var right_y := Input.get_joy_axis(DEVICE_ID, JOY_AXIS_RIGHT_Y)

	return {
		"throttle": clampf((-left_y + 1.0) / 2.0, 0.0, 1.0), # stick forward = more throttle
		"yaw": left_x,
		"pitch": -right_y,
		"roll": right_x,
		"arm_pressed": Input.is_joy_button_pressed(DEVICE_ID, JOY_BUTTON_A),
		"mode_cycle_pressed": Input.is_joy_button_pressed(DEVICE_ID, JOY_BUTTON_B),
		"rth_pressed": Input.is_joy_button_pressed(DEVICE_ID, JOY_BUTTON_Y),
		"passthrough_cycle_pressed": Input.is_joy_button_pressed(DEVICE_ID, JOY_BUTTON_X),
		"fpv_view_toggle_pressed": Input.is_joy_button_pressed(DEVICE_ID, JOY_BUTTON_BACK),
		"menu_toggle_pressed": Input.is_joy_button_pressed(DEVICE_ID, JOY_BUTTON_START),
	}
