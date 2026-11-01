extends RefCounted
## Flight-control input backend reading Steam Frame motion controllers via
## the real Valve Steam Frame controller OpenXR interaction profile
## ("/interaction_profiles/valve/frame_controller_valve", added to
## res://openxr_action_map.tres alongside the Touch-emulation profile Godot
## generates by default) rather than the generic Oculus Touch emulation
## Steam Frame controllers otherwise present as. Confirmed from Godot's own
## engine source (modules/openxr/extensions/openxr_valve_controller_extension.cpp):
## the right controller has A/B/X/Y face buttons and Menu, the left has a
## dedicated View button and a physical D-pad (separate from the
## thumbstick), and both have Trigger/Squeeze/Thumbstick/System/Shoulder.
## Still worth confirming the exact physical button each action name maps
## to on real hardware, since this hasn't been tested against an actual
## Steam Frame unit yet -- but these are the real, correct OpenXR action
## paths for this controller, not a guess at which generic/Touch action
## happens to fire.
##
## Deliberately mirrors GenericGamepadInput's A/B/X/Y -> arm/mode/
## passthrough/RTH assignment, since both backends drive the same physical
## layout family (face buttons on the right, thumbsticks on both) -- the
## whole point of using the real Frame profile instead of staying on
## Touch emulation is that a user switching between the Frame controllers
## and a generic BT/USB gamepad sees a consistent, already-familiar button
## layout rather than two unrelated ones.
##
## Implements the same poll() -> Dictionary contract as
## GenericGamepadInput, so ControlMapper doesn't care which is active.

var left: XRController3D
var right: XRController3D

func _init(left_controller: XRController3D, right_controller: XRController3D) -> void:
	left = left_controller
	right = right_controller

func poll() -> Dictionary:
	var left_stick := left.get_vector2("primary") if left.get_is_active() else Vector2.ZERO
	var right_stick := right.get_vector2("primary") if right.get_is_active() else Vector2.ZERO

	return {
		"throttle": clampf((left_stick.y + 1.0) / 2.0, 0.0, 1.0),
		"yaw": left_stick.x,
		"pitch": right_stick.y,
		"roll": right_stick.x,
		"arm_pressed": right.is_button_pressed("a_button") if right.get_is_active() else false,
		"mode_cycle_pressed": right.is_button_pressed("b_button") if right.get_is_active() else false,
		"rth_pressed": right.is_button_pressed("y_button") if right.get_is_active() else false,
		"passthrough_cycle_pressed": right.is_button_pressed("x_button") if right.get_is_active() else false,
		# The real, dedicated View button -- only the left controller has
		# one; it doesn't exist on the Touch-emulation layer this project
		# relied on before, which is why this never fired no matter which
		# Touch action name it was mapped to.
		"fpv_view_toggle_pressed": left.is_button_pressed("view_button") if left.get_is_active() else false,
		# Right controller's real Menu button -- toggles the Settings window.
		"menu_toggle_pressed": right.is_button_pressed("menu_button") if right.get_is_active() else false,
	}
