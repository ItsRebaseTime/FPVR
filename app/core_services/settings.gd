extends Node
## Autoload singleton holding persisted user settings. Any shell or window
## can read/write these and react to settings_changed; nothing here is
## shell-specific, so a new setting added for one shell is automatically
## available to the others.

const SAVE_PATH := "user://settings.cfg"

## Must match the HSlider min/max in settings_window.tscn (FpvWidthRow/
## FpvHeightRow) -- load_settings() clamps to these so a value saved
## under an older/looser or just different range (sliders' bounds have
## already moved more than once) doesn't silently persist out of bounds
## of what the UI currently allows.
const FPV_PERCENT_MIN := 30.0
const FPV_WIDTH_PERCENT_MAX := 70.0
const FPV_HEIGHT_PERCENT_MAX := 50.0

## AI detection tunables -- see the plan at
## /home/itsrebasetime/.claude/plans/i-want-to-add-transient-lemur.md
## section G/H. Rate/confidence ranges are provisional (Phase 1's bench
## numbers on real Steam Frame hardware came in 5-7x faster than hedged,
## so there's comfortable headroom above the slider max below) -- revisit
## once a real detector model's throughput is known.
const DETECTION_RATE_HZ_MIN := 0.5
const DETECTION_RATE_HZ_MAX := 10.0
const DETECTION_CONFIDENCE_MIN := 0.0
const DETECTION_CONFIDENCE_MAX := 1.0
const VEST_COLOR_TOLERANCE_MIN := 0.0
const VEST_COLOR_TOLERANCE_MAX := 1.0
const CAMERA_TILT_MIN := -90.0
const CAMERA_TILT_MAX := 90.0
const CAMERA_FOV_MIN := 10.0
const CAMERA_FOV_MAX := 220.0

signal settings_changed

var passthrough_mode: int = 0 # PassthroughController.Mode.IR
var input_backend: String = "steamframe" # "steamframe" | "gamepad"
var atak_target_address: String = "239.2.3.1"
var atak_target_port: int = 6969
var self_callsign: String = "FPVR"
var uav_callsign: String = "UAV"
var fpv_width_percent: float = 70.0 # percent of the headset's FOV the FPV view's width covers
var fpv_height_percent: float = 50.0 # percent of the headset's FOV the FPV view's height covers

var detection_enabled: bool = true
var detection_include_vehicles: bool = false # also detect car/truck/bus (COCO classes 2/7/5), not just person
var detection_rate_hz: float = 1.0
var detection_confidence_threshold: float = 0.5
var detection_backend: String = "auto" # "auto" | "npu" | "gpu" -- no "cpu", see InferenceEngine's doc comment
var detection_show_overlay: bool = true
var detection_referee_exclusion_enabled: bool = true
## Pick-a-color-and-a-tolerance replaces 6 raw HSV min/max fields with
## something a color wheel can actually drive -- see
## settings_window.gd's ColorPickerButton wiring and
## detection_service.gd's _apply_referee_exclusion(), which derives the
## hue/sat/val ranges InferenceEngine.check_vest_color() wants from
## these two values. Default is a hi-vis orange.
var detection_vest_color: Color = Color(1.0, 0.55, 0.0)
var detection_vest_color_tolerance: float = 0.3 # 0..1, how wide a net the color match casts
var detection_send_to_atak: bool = true
var camera_tilt_deg: float = 0.0 # down-tilt from horizontal; physical FPV camera mount constant
var camera_hfov_deg: float = 150.0 # physical FPV camera's own FOV -- distinct from fpv_overlay.gd's REFERENCE_FOV_DEG (the headset display's FOV)
var camera_vfov_deg: float = 110.0

func _ready() -> void:
	load_settings()

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	passthrough_mode = cfg.get_value("display", "passthrough_mode", passthrough_mode)
	input_backend = cfg.get_value("input", "backend", input_backend)
	atak_target_address = cfg.get_value("atak", "target_address", atak_target_address)
	atak_target_port = cfg.get_value("atak", "target_port", atak_target_port)
	self_callsign = cfg.get_value("atak", "self_callsign", self_callsign)
	uav_callsign = cfg.get_value("atak", "uav_callsign", uav_callsign)
	fpv_width_percent = clampf(cfg.get_value("display", "fpv_width_percent", fpv_width_percent), FPV_PERCENT_MIN, FPV_WIDTH_PERCENT_MAX)
	fpv_height_percent = clampf(cfg.get_value("display", "fpv_height_percent", fpv_height_percent), FPV_PERCENT_MIN, FPV_HEIGHT_PERCENT_MAX)

	detection_enabled = cfg.get_value("detection", "enabled", detection_enabled)
	detection_include_vehicles = cfg.get_value("detection", "include_vehicles", detection_include_vehicles)
	detection_rate_hz = clampf(cfg.get_value("detection", "rate_hz", detection_rate_hz), DETECTION_RATE_HZ_MIN, DETECTION_RATE_HZ_MAX)
	detection_confidence_threshold = clampf(cfg.get_value("detection", "confidence_threshold", detection_confidence_threshold), DETECTION_CONFIDENCE_MIN, DETECTION_CONFIDENCE_MAX)
	detection_backend = cfg.get_value("detection", "backend", detection_backend)
	detection_show_overlay = cfg.get_value("detection", "show_overlay", detection_show_overlay)
	detection_referee_exclusion_enabled = cfg.get_value("detection", "referee_exclusion_enabled", detection_referee_exclusion_enabled)
	detection_vest_color = cfg.get_value("detection", "vest_color", detection_vest_color)
	detection_vest_color_tolerance = clampf(cfg.get_value("detection", "vest_color_tolerance", detection_vest_color_tolerance), VEST_COLOR_TOLERANCE_MIN, VEST_COLOR_TOLERANCE_MAX)
	detection_send_to_atak = cfg.get_value("detection", "send_to_atak", detection_send_to_atak)
	camera_tilt_deg = clampf(cfg.get_value("detection", "camera_tilt_deg", camera_tilt_deg), CAMERA_TILT_MIN, CAMERA_TILT_MAX)
	camera_hfov_deg = clampf(cfg.get_value("detection", "camera_hfov_deg", camera_hfov_deg), CAMERA_FOV_MIN, CAMERA_FOV_MAX)
	camera_vfov_deg = clampf(cfg.get_value("detection", "camera_vfov_deg", camera_vfov_deg), CAMERA_FOV_MIN, CAMERA_FOV_MAX)

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("display", "passthrough_mode", passthrough_mode)
	cfg.set_value("input", "backend", input_backend)
	cfg.set_value("atak", "target_address", atak_target_address)
	cfg.set_value("atak", "target_port", atak_target_port)
	cfg.set_value("atak", "self_callsign", self_callsign)
	cfg.set_value("atak", "uav_callsign", uav_callsign)
	cfg.set_value("display", "fpv_width_percent", fpv_width_percent)
	cfg.set_value("display", "fpv_height_percent", fpv_height_percent)
	cfg.set_value("detection", "enabled", detection_enabled)
	cfg.set_value("detection", "include_vehicles", detection_include_vehicles)
	cfg.set_value("detection", "rate_hz", detection_rate_hz)
	cfg.set_value("detection", "confidence_threshold", detection_confidence_threshold)
	cfg.set_value("detection", "backend", detection_backend)
	cfg.set_value("detection", "show_overlay", detection_show_overlay)
	cfg.set_value("detection", "referee_exclusion_enabled", detection_referee_exclusion_enabled)
	cfg.set_value("detection", "vest_color", detection_vest_color)
	cfg.set_value("detection", "vest_color_tolerance", detection_vest_color_tolerance)
	cfg.set_value("detection", "send_to_atak", detection_send_to_atak)
	cfg.set_value("detection", "camera_tilt_deg", camera_tilt_deg)
	cfg.set_value("detection", "camera_hfov_deg", camera_hfov_deg)
	cfg.set_value("detection", "camera_vfov_deg", camera_vfov_deg)
	cfg.save(SAVE_PATH)
	settings_changed.emit()
