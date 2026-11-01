extends PanelContainer
## Settings window: the UI toggle for passthrough mode (IR/RGB/Black) the
## user asked for, plus flight-input backend and ATAK bridge target. A
## fourth window reusing the exact same wrapper pattern as the other
## three -- proof that adding a new window is just "add a scene", per the
## plan's modularity goal.
##
## No Save button: every control commits to Settings and calls
## save_settings() the moment it changes, instead of batching changes
## behind a separate confirmation click -- a dedicated Save button is one
## more thing that can get missed (especially before pointer-click was
## reliable at all), and there's no reason a local settings file needs
## one.
##
## Passthrough, the "Steam Frame Controllers" input choice, and the FPV
## view size only make sense on the VR shell (a phone/PC has no
## passthrough camera, no motion controllers, and no FPV overlay) -- each
## shell that instances this scene sets show_passthrough/
## show_input_backend/show_fpv_view accordingly. show_ai_detection mirrors
## show_fpv_view (detection only makes sense where there's an FPV view to
## run it on) rather than being its own independent flag.
##
## Settings moved from a single scrolling list to a TabContainer
## ("General" + "AI Detection") specifically to give the AI detection
## controls their own tab per the plan, rather than growing the one list
## further -- see /home/itsrebasetime/.claude/plans/i-want-to-add-transient-lemur.md
## section G.

@export var show_passthrough := true
@export var show_input_backend := true
@export var show_fpv_view := true
@export var show_ai_detection := true

@onready var _tabs: TabContainer = $Margin/OuterVBox/Tabs

@onready var _passthrough_row: HBoxContainer = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/PassthroughRow
@onready var _input_row: HBoxContainer = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/InputRow
@onready var _fpv_width_row: HBoxContainer = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/FpvWidthRow
@onready var _fpv_height_row: HBoxContainer = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/FpvHeightRow
@onready var _passthrough_option: OptionButton = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/PassthroughRow/OptionButton
@onready var _input_option: OptionButton = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/InputRow/OptionButton
@onready var _atak_address: LineEdit = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/AtakAddressRow/LineEdit
@onready var _atak_port: SpinBox = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/AtakPortRow/SpinBox
@onready var _self_callsign: LineEdit = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/SelfCallsignRow/LineEdit
@onready var _uav_callsign: LineEdit = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/UavCallsignRow/LineEdit
@onready var _fpv_width: HSlider = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/FpvWidthRow/HSlider
@onready var _fpv_width_value_label: Label = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/FpvWidthRow/ValueLabel
@onready var _fpv_height: HSlider = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/FpvHeightRow/HSlider
@onready var _fpv_height_value_label: Label = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/FpvHeightRow/ValueLabel
@onready var _keyboard: PanelContainer = $Margin/OuterVBox/Tabs/General/CenterRegion/ScrollContainer/VBox/KeyboardOverlay

@onready var _detection_enabled: CheckButton = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/EnabledRow/CheckButton
@onready var _detection_include_vehicles: CheckButton = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/IncludeVehiclesRow/CheckButton
@onready var _detection_rate: HSlider = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/RateRow/HSlider
@onready var _detection_rate_value_label: Label = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/RateRow/ValueLabel
@onready var _detection_confidence: HSlider = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/ConfidenceRow/HSlider
@onready var _detection_confidence_value_label: Label = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/ConfidenceRow/ValueLabel
@onready var _detection_backend_option: OptionButton = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/BackendRow/OptionButton
@onready var _detection_backend_status_label: Label = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/BackendStatusRow/StatusLabel
@onready var _detection_show_overlay: CheckButton = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/ShowOverlayRow/CheckButton
@onready var _detection_show_debug_info: CheckButton = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/ShowDebugInfoRow/CheckButton
@onready var _detection_referee_exclusion: CheckButton = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/RefereeExclusionRow/CheckButton
@onready var _vest_color: ColorPickerButton = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/VestColorRow/ColorPickerButton
@onready var _vest_tolerance: HSlider = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/VestToleranceRow/HSlider
@onready var _vest_tolerance_value_label: Label = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/VestToleranceRow/ValueLabel
@onready var _detection_send_to_atak: CheckButton = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/SendAtakRow/CheckButton
@onready var _camera_tilt: HSlider = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/CameraTiltRow/HSlider
@onready var _camera_tilt_value_label: Label = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/CameraTiltRow/ValueLabel
@onready var _camera_hfov: HSlider = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/CameraHFovRow/HSlider
@onready var _camera_hfov_value_label: Label = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/CameraHFovRow/ValueLabel
@onready var _camera_vfov: HSlider = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/CameraVFovRow/HSlider
@onready var _camera_vfov_value_label: Label = $Margin/OuterVBox/Tabs/AIDetection/CenterRegion/ScrollContainer/VBox/CameraVFovRow/ValueLabel

var _focused_text_field: LineEdit = null

func _ready() -> void:
	_passthrough_row.visible = show_passthrough
	_input_row.visible = show_input_backend
	_fpv_width_row.visible = show_fpv_view
	_fpv_height_row.visible = show_fpv_view
	_tabs.set_tab_title(1, "AI Detection")
	if not show_ai_detection:
		_tabs.set_tab_hidden(1, true)

	_keyboard.visible = false
	_keyboard.key_pressed.connect(_on_keyboard_key)
	get_viewport().gui_focus_changed.connect(_on_focus_changed)

	_passthrough_option.clear()
	_passthrough_option.add_item("IR (default)", 0)
	_passthrough_option.add_item("RGB (Arcturus)", 1)
	_passthrough_option.add_item("Black", 2)
	_passthrough_option.select(Settings.passthrough_mode)
	_passthrough_option.item_selected.connect(_on_passthrough_selected)

	_input_option.clear()
	if show_input_backend:
		_input_option.add_item("Steam Frame Controllers", 0)
	_input_option.add_item("Generic Gamepad (BT/USB)", 1)
	_input_option.select(0 if Settings.input_backend == "steamframe" and show_input_backend else (_input_option.get_item_count() - 1))
	_input_option.item_selected.connect(_on_input_backend_selected)

	_atak_address.text = Settings.atak_target_address
	_atak_address.text_changed.connect(_on_atak_address_changed)
	_atak_port.value = Settings.atak_target_port
	_atak_port.value_changed.connect(_on_atak_port_changed)
	_self_callsign.text = Settings.self_callsign
	_self_callsign.text_changed.connect(_on_self_callsign_changed)
	_uav_callsign.text = Settings.uav_callsign
	_uav_callsign.text_changed.connect(_on_uav_callsign_changed)
	_fpv_width.value = Settings.fpv_width_percent
	_fpv_width_value_label.text = "%d%%" % Settings.fpv_width_percent
	_fpv_width.value_changed.connect(_on_fpv_width_changed)
	_fpv_height.value = Settings.fpv_height_percent
	_fpv_height_value_label.text = "%d%%" % Settings.fpv_height_percent
	_fpv_height.value_changed.connect(_on_fpv_height_changed)

	_setup_ai_tab()

func _setup_ai_tab() -> void:
	_detection_enabled.button_pressed = Settings.detection_enabled
	_detection_enabled.toggled.connect(_on_detection_enabled_toggled)

	_detection_include_vehicles.button_pressed = Settings.detection_include_vehicles
	_detection_include_vehicles.toggled.connect(_on_detection_include_vehicles_toggled)

	_detection_rate.value = Settings.detection_rate_hz
	_detection_rate_value_label.text = "%.1f Hz" % Settings.detection_rate_hz
	_detection_rate.value_changed.connect(_on_detection_rate_changed)

	_detection_confidence.value = Settings.detection_confidence_threshold
	_detection_confidence_value_label.text = "%d%%" % int(Settings.detection_confidence_threshold * 100.0)
	_detection_confidence.value_changed.connect(_on_detection_confidence_changed)

	_detection_backend_option.clear()
	_detection_backend_option.add_item("Auto", 0)
	_detection_backend_option.add_item("GPU (Vulkan)", 1)
	_detection_backend_option.add_item("NPU (Hexagon, if available)", 2)
	var backend_index: int = {"auto": 0, "gpu": 1, "npu": 2}.get(Settings.detection_backend, 0)
	_detection_backend_option.select(backend_index)
	_detection_backend_option.item_selected.connect(_on_detection_backend_selected)
	_refresh_backend_status()

	_detection_show_overlay.button_pressed = Settings.detection_show_overlay
	_detection_show_overlay.toggled.connect(_on_detection_show_overlay_toggled)

	_detection_show_debug_info.button_pressed = Settings.detection_show_debug_info
	_detection_show_debug_info.toggled.connect(_on_detection_show_debug_info_toggled)

	_detection_referee_exclusion.button_pressed = Settings.detection_referee_exclusion_enabled
	_detection_referee_exclusion.toggled.connect(_on_detection_referee_exclusion_toggled)

	_vest_color.color = Settings.detection_vest_color
	_vest_color.color_changed.connect(_on_vest_color_changed)
	_vest_color.get_picker().picker_shape = ColorPicker.SHAPE_HSV_WHEEL
	_vest_tolerance.value = Settings.detection_vest_color_tolerance
	_vest_tolerance_value_label.text = "%d%%" % int(Settings.detection_vest_color_tolerance * 100.0)
	_vest_tolerance.value_changed.connect(_on_vest_tolerance_changed)

	_detection_send_to_atak.button_pressed = Settings.detection_send_to_atak
	_detection_send_to_atak.toggled.connect(_on_detection_send_to_atak_toggled)

	_camera_tilt.value = Settings.camera_tilt_deg
	_camera_tilt_value_label.text = "%d deg" % int(Settings.camera_tilt_deg)
	_camera_tilt.value_changed.connect(_on_camera_tilt_changed)
	_camera_hfov.value = Settings.camera_hfov_deg
	_camera_hfov_value_label.text = "%d deg" % int(Settings.camera_hfov_deg)
	_camera_hfov.value_changed.connect(_on_camera_hfov_changed)
	_camera_vfov.value = Settings.camera_vfov_deg
	_camera_vfov_value_label.text = "%d deg" % int(Settings.camera_vfov_deg)
	_camera_vfov.value_changed.connect(_on_camera_vfov_changed)

## DetectionService only sets its backend once, at startup (see
## detection_service.gd's _try_load_temp_model()) -- this just reflects
## whatever it landed on, refreshed whenever the tab becomes visible,
## since there's no settings_changed-style signal for "backend changed"
## and polling on every frame would be wasteful for a value that only
## ever changes once per app run.
func _refresh_backend_status() -> void:
	_detection_backend_status_label.text = DetectionService.get_active_backend()

func _on_passthrough_selected(_index: int) -> void:
	Settings.passthrough_mode = _passthrough_option.get_selected_id()
	Settings.save_settings()

func _on_input_backend_selected(_index: int) -> void:
	Settings.input_backend = "steamframe" if _input_option.get_selected_id() == 0 else "gamepad"
	Settings.save_settings()

func _on_atak_address_changed(new_text: String) -> void:
	Settings.atak_target_address = new_text
	Settings.save_settings()

func _on_atak_port_changed(value: float) -> void:
	Settings.atak_target_port = int(value)
	Settings.save_settings()

func _on_self_callsign_changed(new_text: String) -> void:
	Settings.self_callsign = new_text
	Settings.save_settings()

func _on_uav_callsign_changed(new_text: String) -> void:
	Settings.uav_callsign = new_text
	Settings.save_settings()

func _on_fpv_width_changed(value: float) -> void:
	Settings.fpv_width_percent = value
	_fpv_width_value_label.text = "%d%%" % value
	Settings.save_settings()

func _on_fpv_height_changed(value: float) -> void:
	Settings.fpv_height_percent = value
	_fpv_height_value_label.text = "%d%%" % value
	Settings.save_settings()

func _on_detection_enabled_toggled(pressed: bool) -> void:
	Settings.detection_enabled = pressed
	Settings.save_settings()

func _on_detection_include_vehicles_toggled(pressed: bool) -> void:
	Settings.detection_include_vehicles = pressed
	Settings.save_settings()

func _on_detection_rate_changed(value: float) -> void:
	Settings.detection_rate_hz = value
	_detection_rate_value_label.text = "%.1f Hz" % value
	Settings.save_settings()

func _on_detection_confidence_changed(value: float) -> void:
	Settings.detection_confidence_threshold = value
	_detection_confidence_value_label.text = "%d%%" % int(value * 100.0)
	Settings.save_settings()

## Takes effect on the next app start -- DetectionService only selects a
## backend once, in _try_load_temp_model() at startup (see that file's doc
## comment on why: NCNN's Vulkan device/network state isn't something to
## tear down and rebuild live from a Settings toggle).
func _on_detection_backend_selected(index: int) -> void:
	Settings.detection_backend = ["auto", "gpu", "npu"][index]
	Settings.save_settings()

func _on_detection_show_overlay_toggled(pressed: bool) -> void:
	Settings.detection_show_overlay = pressed
	Settings.save_settings()

func _on_detection_show_debug_info_toggled(pressed: bool) -> void:
	Settings.detection_show_debug_info = pressed
	Settings.save_settings()

func _on_detection_referee_exclusion_toggled(pressed: bool) -> void:
	Settings.detection_referee_exclusion_enabled = pressed
	Settings.save_settings()

func _on_vest_color_changed(color: Color) -> void:
	Settings.detection_vest_color = color
	Settings.save_settings()

func _on_vest_tolerance_changed(value: float) -> void:
	Settings.detection_vest_color_tolerance = value
	_vest_tolerance_value_label.text = "%d%%" % int(value * 100.0)
	Settings.save_settings()

func _on_detection_send_to_atak_toggled(pressed: bool) -> void:
	Settings.detection_send_to_atak = pressed
	Settings.save_settings()

func _on_camera_tilt_changed(value: float) -> void:
	Settings.camera_tilt_deg = value
	_camera_tilt_value_label.text = "%d deg" % int(value)
	Settings.save_settings()

func _on_camera_hfov_changed(value: float) -> void:
	Settings.camera_hfov_deg = value
	_camera_hfov_value_label.text = "%d deg" % int(value)
	Settings.save_settings()

func _on_camera_vfov_changed(value: float) -> void:
	Settings.camera_vfov_deg = value
	_camera_vfov_value_label.text = "%d deg" % int(value)
	Settings.save_settings()

## There is no physical keyboard in VR and desktop Linux's DisplayServer
## has no automatic on-screen keyboard (that's Android/iOS-only), so this
## window shows/hides its own based on which Control currently has focus
## -- gui_focus_changed fires whenever focus moves to a new Control within
## this window's own SubViewport.
func _on_focus_changed(control: Control) -> void:
	if control is LineEdit:
		_focused_text_field = control
		_keyboard.visible = true
	else:
		_focused_text_field = null
		_keyboard.visible = false

func _on_keyboard_key(key: String) -> void:
	if _focused_text_field == null:
		return
	match key:
		"DONE":
			_focused_text_field.release_focus()
			_focused_text_field = null
			_keyboard.visible = false
		"BACKSPACE":
			var col: int = _focused_text_field.caret_column
			if col > 0:
				_focused_text_field.text = _focused_text_field.text.substr(0, col - 1) + _focused_text_field.text.substr(col)
				_focused_text_field.caret_column = col - 1
				_focused_text_field.text_changed.emit(_focused_text_field.text)
		_:
			var col: int = _focused_text_field.caret_column
			_focused_text_field.text = _focused_text_field.text.substr(0, col) + key + _focused_text_field.text.substr(col)
			_focused_text_field.caret_column = col + key.length()
			_focused_text_field.text_changed.emit(_focused_text_field.text)
