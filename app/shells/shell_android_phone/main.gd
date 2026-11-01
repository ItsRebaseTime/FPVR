extends Control
## Android phone flat shell: same three windows as every other shell, laid
## out as tabs (a phone screen is too narrow for the VR shell's side-by-side
## layout) and switched by touch instead of grabbed. Flight control uses a
## generic BT/USB gamepad, since a phone has no motion controllers.
##
## NOTE on current limitations (not yet solved, flagged honestly rather
## than silently assumed away): stock Android does not let an app open
## /dev/ttyACM*/dev/video* directly the way UsbDeviceRegistry does on
## Linux -- that needs a UsbManager/USB-serial JNI bridge requesting
## per-device permission from the user, which core_services/hardware_hub.gd
## does not implement yet. This shell is wired correctly and will work once
## that Android-specific discovery backend is added behind the same
## HardwareHub interface.

const BASE_EDGE_MARGIN := 24 # comfortable minimum even with no notch/rounded corner
const TOUCH_FONT_SIZE := 22
const TAB_TOUCH_PADDING := Vector2(24, 18) # horizontal, vertical content margin inside each tab

@onready var _safe_area: MarginContainer = $SafeArea
@onready var _tabs: TabContainer = $SafeArea/Tabs

func _ready() -> void:
	var bridge = load("res://bridge/atak_bridge.gd").new()
	add_child(bridge)

	var control_mapper = load("res://core_services/control_mapper.gd").new()
	add_child(control_mapper)
	control_mapper.set_backend(load("res://input/generic_gamepad_input.gd").new())

	set_process(true)
	set_meta("bridge", bridge)

	_apply_touch_friendly_theme()
	_apply_safe_area_margins()
	get_tree().root.size_changed.connect(_apply_safe_area_margins)

func _process(_delta: float) -> void:
	var bridge: Node = get_meta("bridge")
	bridge.update_self_fix(HardwareHub.get_self_gps_fix())
	bridge.update_uav_fix(HardwareHub.get_uav_fix())

## Bigger default font (and therefore bigger buttons/fields, which size to
## their text) across every window this shell hosts, so controls are easy
## to hit with a finger instead of being sized for mouse/VR-quad use.
func _apply_touch_friendly_theme() -> void:
	var touch_theme := Theme.new()
	touch_theme.set_default_font_size(TOUCH_FONT_SIZE)
	theme = touch_theme

	var tab_bar := _tabs.get_tab_bar()
	tab_bar.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)

	for stylebox_name in ["tab_selected", "tab_unselected", "tab_hovered"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.3, 0.3, 0.3) if stylebox_name == "tab_selected" else Color(0.18, 0.18, 0.18)
		style.content_margin_left = TAB_TOUCH_PADDING.x
		style.content_margin_right = TAB_TOUCH_PADDING.x
		style.content_margin_top = TAB_TOUCH_PADDING.y
		style.content_margin_bottom = TAB_TOUCH_PADDING.y
		tab_bar.add_theme_stylebox_override(stylebox_name, style)

## Insets the whole UI by the device's actual unobscured safe area (status
## bar, rounded corners, camera cutouts) on top of a comfortable minimum
## margin, so nothing -- including the first tab -- ever lands under a
## corner or cutout. Re-applied on rotation/resize.
func _apply_safe_area_margins() -> void:
	var window_size: Vector2i = DisplayServer.window_get_size()
	var safe_area: Rect2i = DisplayServer.get_display_safe_area()

	if window_size.x <= 0 or window_size.y <= 0:
		return

	var left := safe_area.position.x + BASE_EDGE_MARGIN
	var top := safe_area.position.y + BASE_EDGE_MARGIN
	var right := (window_size.x - (safe_area.position.x + safe_area.size.x)) + BASE_EDGE_MARGIN
	var bottom := (window_size.y - (safe_area.position.y + safe_area.size.y)) + BASE_EDGE_MARGIN

	_safe_area.add_theme_constant_override("margin_left", left)
	_safe_area.add_theme_constant_override("margin_top", top)
	_safe_area.add_theme_constant_override("margin_right", right)
	_safe_area.add_theme_constant_override("margin_bottom", bottom)
