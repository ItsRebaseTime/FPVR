extends MeshInstance3D
## Full-field-of-view, head-locked first-person UVC video view, toggled by
## the "View" button (see steamframe_controller_input.gd/
## generic_gamepad_input.gd's fpv_view_toggle_pressed, routed through
## ControlMapper's fpv_view_toggle_requested signal, handled in
## shell_vr_steamframe/main.gd). A flat, monoscopic feed shown identically
## to both eyes -- the same way real analog FPV goggles work -- with no 3D
## environment or windows involved, per the user's request.
##
## A plain textured 3D quad, reparented under the XRCamera3D by main.gd at
## startup so it tracks head movement for free. Deliberately NOT a 2D
## CanvasLayer overlay: Godot's own XR docs note that plain 2D content
## doesn't reliably composite into the OpenXR stereo view the way a
## normal 3D-rendered object does, whereas a textured quad is exactly the
## same technique already proven working for the other windows (just
## without their SubViewport, since this only ever shows a flat decoded
## image, never interactive Controls).
##
## Purely a consumer of HardwareHub's video stream; knows nothing about
## USB/V4L2/UVC. Visibility is owned entirely by main.gd (ANDing the View
## and Menu toggles) -- this node just reads its own `visible` (plain
## Node3D property, no separate "active" flag needed) to decide whether
## to bother decoding incoming frames at all.
##
## Width/height are user-tunable (Settings.fpv_width_percent/
## fpv_height_percent, from the Settings window) as a percentage of the
## headset's field of view, not a fixed size -- the initial fixed size
## filled (and exceeded) the whole FOV with no way to see the sides.
## REFERENCE_FOV_DEG is Valve's own published spec (110 deg horizontal x
## 110 deg vertical, "quoted conservatively"); real-world reviews measure
## closer to ~103 deg. It only needs to be a reasonable reference for
## "100%" -- the percent control exists specifically so this doesn't need
## to be exact, and distance/FOV/size are all handled here so main.gd only
## ever needs to reparent this under the camera.
##
## ElrsOverlay (child node, see elrs_hud_overlay.gd) is a second,
## transparent quad showing ELRS link/battery/flight-mode data on top of
## the video -- parented here specifically so it always exactly tracks
## this quad's own size/position without duplicating the percent-to-
## meters math above; see sync_size() below.

const DISTANCE_M := 0.6
const REFERENCE_FOV_DEG := Vector2(110.0, 110.0)

@onready var _elrs_overlay: Node3D = $ElrsOverlay
@onready var _detection_overlay: Node3D = $DetectionOverlay

var _material: StandardMaterial3D

func _ready() -> void:
	visible = false
	position = Vector3(0, 0, -DISTANCE_M)
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material_override = _material
	HardwareHub.video_frame_ready.connect(_on_frame)
	apply_size_percent(Settings.fpv_width_percent, Settings.fpv_height_percent)
	Settings.settings_changed.connect(_on_settings_changed)

func _on_settings_changed() -> void:
	apply_size_percent(Settings.fpv_width_percent, Settings.fpv_height_percent)

## width_percent/height_percent (0..100, typically) are the fraction of
## REFERENCE_FOV_DEG this quad should subtend at DISTANCE_M -- e.g. 50%
## width means the quad's horizontal edges sit at +/-25 deg off dead
## ahead, not that the quad is literally half as wide in meters.
func apply_size_percent(width_percent: float, height_percent: float) -> void:
	var fov_rad := Vector2(
		deg_to_rad(REFERENCE_FOV_DEG.x * width_percent / 100.0),
		deg_to_rad(REFERENCE_FOV_DEG.y * height_percent / 100.0),
	)
	var size := Vector2(
		2.0 * DISTANCE_M * tan(fov_rad.x * 0.5),
		2.0 * DISTANCE_M * tan(fov_rad.y * 0.5),
	)
	(mesh as QuadMesh).size = size
	_elrs_overlay.sync_size(size)
	_detection_overlay.sync_size(size)

## Lets main.gd keep the Settings window's size matched to this one --
## see head_locked_window.gd's set_quad_size().
func get_current_size() -> Vector2:
	return (mesh as QuadMesh).size

func _on_frame(bytes: PackedByteArray, format: String, width: int, height: int) -> void:
	if not visible:
		return
	var image := Image.new()
	if format == "mjpeg":
		if image.load_jpg_from_buffer(bytes) != OK:
			return
	else:
		image.set_data(width, height, false, Image.FORMAT_RGB8, bytes)
	_material.albedo_texture = ImageTexture.create_from_image(image)
