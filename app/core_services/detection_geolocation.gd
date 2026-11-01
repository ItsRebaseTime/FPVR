class_name DetectionGeolocation
## Ground-plane-intersection range/bearing estimate for a detection's
## position, from the UAV's own GPS fix and a few physical-camera
## constants (Settings.camera_tilt_deg/camera_hfov_deg/camera_vfov_deg --
## distinct from fpv_overlay.gd's REFERENCE_FOV_DEG, which is the
## headset's own display FOV, not the FPV camera's). A pure stateless
## helper (no autoload needed) -- call estimate_ground_position() directly.
##
## See the plan at
## /home/itsrebasetime/.claude/plans/i-want-to-add-transient-lemur.md
## section E for the full reasoning. Short version: this assumes flat
## ground below the UAV and a single geometric ray from camera tilt +
## the detection's position in frame -- there is no stereo/depth
## involved. Accuracy is good while the UAV is well above the ground and
## the detection sits well below the horizon in frame; it degrades
## sharply as the ray's depression angle approaches zero (near-horizon
## detections, or low-altitude flight), where a small tilt/altitude
## error swings the estimated range by a large amount. Only meaningful
## while uav_fix.has_fix is true and altitude_m is a real, positive,
## airborne value.
##
## The final lat/lon step is the inverse of gps_uav_window.gd's own
## _local_offset_m() (same equirectangular approximation, same
## EARTH_RADIUS_M), just solved the other direction (local meters ->
## lat/lon instead of lat/lon -> local meters) and anchored at the UAV's
## position rather than the headset's, since the ray originates at the
## UAV's camera.

const EARTH_RADIUS_M := 6371000.0

## detection_center_frac: 0..1 within the FPV frame (x right, y down) --
## e.g. a detection Dictionary's x+w/2, y+h/2 (see
## core/src/ai/inference_engine.h's detect() doc comment for that
## contract). Returns {"has_estimate": false} when there's no usable UAV
## fix/altitude or the computed ray doesn't hit the ground in front of
## the camera; otherwise {"has_estimate": true, "latitude", "longitude",
## "range_m", "bearing_deg"}.
static func estimate_ground_position(
		uav_fix: Dictionary,
		detection_center_frac: Vector2,
		camera_tilt_deg: float,
		camera_hfov_deg: float,
		camera_vfov_deg: float) -> Dictionary:
	if not uav_fix.get("has_fix", false):
		return { "has_estimate": false }
	var altitude_m: float = uav_fix.get("altitude_m", 0.0)
	if altitude_m <= 0.0:
		return { "has_estimate": false }

	# -0.5..0.5, so 0 means "dead center" (boresight) on each axis.
	var x_offset_frac := detection_center_frac.x - 0.5
	var y_offset_frac := detection_center_frac.y - 0.5

	var horizontal_angle_deg := x_offset_frac * camera_hfov_deg
	# y grows downward in frame space, and a detection below center means
	# a steeper look-down angle than the camera's own tilt -- hence +=,
	# not -=, below.
	var vertical_angle_deg := y_offset_frac * camera_vfov_deg
	var depression_deg := camera_tilt_deg + vertical_angle_deg

	# At or above the horizon: tan() blows up or goes negative, and the
	# flat-ground assumption stops meaning anything anyway.
	if depression_deg <= 0.1:
		return { "has_estimate": false }

	var range_m := altitude_m / tan(deg_to_rad(depression_deg))
	var bearing_deg := fmod(uav_fix.get("heading_deg", 0.0) + horizontal_angle_deg + 360.0, 360.0)
	var bearing_rad := deg_to_rad(bearing_deg)

	# x = east, y = north -- inverse of gps_uav_window.gd's
	# _local_offset_m(), which returns (east, -north) because screen Y
	# grows downward there; no such flip needed here since this isn't
	# screen space.
	var east_m := range_m * sin(bearing_rad)
	var north_m := range_m * cos(bearing_rad)

	var lat0: float = uav_fix["latitude"]
	var lon0: float = uav_fix["longitude"]
	var dlat_deg := rad_to_deg(north_m / EARTH_RADIUS_M)
	var dlon_deg := rad_to_deg(east_m / (EARTH_RADIUS_M * cos(deg_to_rad(lat0))))

	return {
		"has_estimate": true,
		"latitude": lat0 + dlat_deg,
		"longitude": lon0 + dlon_deg,
		"range_m": range_m,
		"bearing_deg": bearing_deg,
	}
