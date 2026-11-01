extends PanelContainer
## Plots the headset's own GPS fix (center) and the UAV's position from ELRS
## telemetry (if present) on a simple local-tangent-plane map. Reads only
## from HardwareHub -- no device/protocol knowledge here.

const MIN_RADIUS_M := 50.0
const EARTH_RADIUS_M := 6371000.0

@onready var _plot: Control = $Margin/VBox/Plot
@onready var _info_label: Label = $Margin/VBox/Info

var _self_fix: Dictionary = { "has_fix": false }
var _uav_fix: Dictionary = { "has_fix": false }

func _ready() -> void:
	_plot.draw.connect(_on_plot_draw)

func _process(_delta: float) -> void:
	_self_fix = HardwareHub.get_self_gps_fix()
	_uav_fix = HardwareHub.get_uav_fix()
	_plot.queue_redraw()
	_update_info()

func _update_info() -> void:
	var lines: PackedStringArray = []
	if _self_fix.get("has_fix", false):
		lines.append("Self:  %.6f, %.6f  alt %.0fm  hdop %.1f  sats %d" % [
			_self_fix["latitude"], _self_fix["longitude"], _self_fix.get("altitude_m", 0.0),
			_self_fix.get("hdop", 99.0), _self_fix.get("satellites", 0)
		])
	else:
		lines.append("Self:  no GPS fix")

	if _uav_fix.get("has_fix", false):
		lines.append("UAV:   %.6f, %.6f  alt %.0fm  hdg %.0f  spd %.1f m/s" % [
			_uav_fix["latitude"], _uav_fix["longitude"], _uav_fix.get("altitude_m", 0.0),
			_uav_fix.get("heading_deg", 0.0), _uav_fix.get("ground_speed_mps", 0.0)
		])
	else:
		lines.append("UAV:   no telemetry GPS")

	_info_label.text = "\n".join(lines)

# Equirectangular local-tangent-plane approximation -- plenty accurate at
# the few-kilometer range this map is meant for.
func _local_offset_m(lat0: float, lon0: float, lat: float, lon: float) -> Vector2:
	var dlat_m := deg_to_rad(lat - lat0) * EARTH_RADIUS_M
	var dlon_m := deg_to_rad(lon - lon0) * EARTH_RADIUS_M * cos(deg_to_rad(lat0))
	return Vector2(dlon_m, -dlat_m) # screen Y grows downward, north is up

func _on_plot_draw() -> void:
	var size := _plot.size
	var center := size / 2.0

	_plot.draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.09, 0.08), true)

	if not _self_fix.get("has_fix", false):
		_plot.draw_string(ThemeDB.fallback_font, Vector2(8, size.y / 2), "Waiting for self GPS fix...", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
		return

	var uav_offset := Vector2.ZERO
	var have_uav: bool = _uav_fix.get("has_fix", false)
	if have_uav:
		uav_offset = _local_offset_m(_self_fix["latitude"], _self_fix["longitude"], _uav_fix["latitude"], _uav_fix["longitude"])

	var radius_m: float = max(MIN_RADIUS_M, max(abs(uav_offset.x), abs(uav_offset.y)) * 1.3)
	var px_per_m: float = (min(size.x, size.y) / 2.0 - 16.0) / radius_m

	# Range rings every quarter of the current radius.
	for ring in range(1, 4):
		var r := radius_m * ring / 4.0 * px_per_m
		_plot.draw_arc(center, r, 0, TAU, 48, Color(0.3, 0.4, 0.35, 0.5), 1.0)

	# Self marker.
	_plot.draw_circle(center, 6.0, Color(0.3, 0.8, 1.0))

	if have_uav:
		var uav_pos := center + uav_offset * px_per_m
		_plot.draw_line(center, uav_pos, Color(1.0, 0.7, 0.2, 0.6), 2.0)
		_plot.draw_circle(uav_pos, 6.0, Color(1.0, 0.6, 0.1))
		var heading_rad := deg_to_rad(_uav_fix.get("heading_deg", 0.0))
		var heading_tip := uav_pos + Vector2(sin(heading_rad), -cos(heading_rad)) * 14.0
		_plot.draw_line(uav_pos, heading_tip, Color(1.0, 0.9, 0.3), 2.0)
