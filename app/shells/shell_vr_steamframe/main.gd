extends Node3D
## Steam Frame VR shell: assembles the XR rig, flight-control mapping,
## passthrough toggling, and the ATAK bridge.
## /core and /app/windows are untouched here -- this shell is purely wiring.
##
## Only two things ever occupy the main view: the FPV overlay (video feed
## + ELRS HUD, see fpv_overlay.tscn/fpv_overlay.gd's ElrsOverlay child) and
## the Settings window, both head-locked under the camera at the same
## spot. Exactly two independent toggles decide what's visible:
##   - View button -> fpv_view_toggle_requested -> flips _fpv_active
##     (FPV feed vs. plain passthrough, nothing shown).
##   - Menu button -> menu_toggle_requested -> flips _settings_visible
##     (Settings replaces whatever was showing; hiding it reveals
##     whatever _fpv_active says should be there).
## _update_window_visibility() is the one place that combines them --
## simple enough that "Menu shows Settings over either FPV or
## passthrough, and un-showing it returns to whichever was active" falls
## straight out of ANDing the two flags, no separate state machine needed.
##
## Not yet run on real Steam Frame hardware (none available during
## development); xr_rig.gd falls back to flat rendering without an OpenXR
## runtime so the rest of this scene can still be exercised on a desktop.

@onready var xr_rig = $XRRig
@onready var xr_pointer: Node = $XRPointer
@onready var settings_window = $SettingsWindow
@onready var control_mapper: Node = $ControlMapper
@onready var passthrough_controller: Node = $PassthroughController
@onready var fpv_overlay: Node3D = $FPVOverlay

var _atak_bridge: Node
var _fpv_active := false
var _settings_visible := false

func _ready() -> void:
	var left: XRController3D = xr_rig.get_node("LeftController")
	var right: XRController3D = xr_rig.get_node("RightController")
	var camera: XRCamera3D = xr_rig.get_node("Camera")

	# Reparent both under the camera so they track head movement for
	# free -- each one's local position/size is set in its own _ready(),
	# which already ran before this (children ready before their
	# parent), so a plain reparent here is all that's needed.
	for window in [settings_window, fpv_overlay]:
		remove_child(window)
		camera.add_child(window)

	xr_pointer.left_controller = left
	xr_pointer.right_controller = right
	xr_pointer.register_window(settings_window)

	_apply_input_backend(left, right)
	Settings.settings_changed.connect(func(): _apply_input_backend(left, right))
	# fpv_overlay's own settings_changed listener (connected in its _ready(),
	# which already ran before this one) recomputes its size first, so
	# reading it back here always gets the up-to-date value.
	Settings.settings_changed.connect(_sync_settings_size)
	control_mapper.passthrough_cycle_requested.connect(passthrough_controller.cycle)
	control_mapper.fpv_view_toggle_requested.connect(_on_fpv_view_toggle_requested)
	control_mapper.menu_toggle_requested.connect(_on_menu_toggle_requested)

	_sync_settings_size()
	_update_window_visibility()

	_atak_bridge = load("res://bridge/atak_bridge.gd").new()
	add_child(_atak_bridge)

func _process(_delta: float) -> void:
	_atak_bridge.update_self_fix(HardwareHub.get_self_gps_fix())
	_atak_bridge.update_uav_fix(HardwareHub.get_uav_fix())

## "View" button: flips between the FPV feed and plain passthrough.
func _on_fpv_view_toggle_requested() -> void:
	_fpv_active = not _fpv_active
	_update_window_visibility()

## "Menu" button: shows/hides Settings, replacing whatever was showing
## underneath (FPV or passthrough) and restoring it when hidden again.
func _on_menu_toggle_requested() -> void:
	_settings_visible = not _settings_visible
	_update_window_visibility()

## Settings has no size of its own now -- it should always exactly match
## whatever size the FPV overlay currently is, per the user's request.
func _sync_settings_size() -> void:
	settings_window.set_quad_size(fpv_overlay.get_current_size())

func _update_window_visibility() -> void:
	fpv_overlay.visible = _fpv_active and not _settings_visible
	settings_window.visible = _settings_visible
	# The laser pointer has nothing to click on FPV/passthrough -- only
	# Settings has interactive Controls -- so it's disabled the rest of
	# the time, both to avoid wasted per-frame raycasting and because
	# there's no laser to distract from the video feed.
	xr_pointer.enabled = _settings_visible

func _apply_input_backend(left: XRController3D, right: XRController3D) -> void:
	if Settings.input_backend == "gamepad":
		control_mapper.set_backend(load("res://input/generic_gamepad_input.gd").new())
	else:
		control_mapper.set_backend(load("res://input/steamframe_controller_input.gd").new(left, right))
