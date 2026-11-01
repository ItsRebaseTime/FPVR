extends Node3D
## A window rendered to a SubViewport and displayed on a quad that's
## head-locked -- reparented under the XRCamera3D by main.gd (same
## technique as fpv_overlay.gd) at a fixed yaw/pitch/distance, so it
## always stays in the same spot in the player's field of view rather
## than a fixed point in world space. Replaced the previous
## grip-grab-to-move design: with every window permanently arranged in a
## non-overlapping arc around the player, there's nothing left to grab
## or place -- see xr_pointer.gd for the laser-pointer click interaction
## these windows still support.
##
## content_scene is any of the /windows/*.tscn Controls; this wrapper has
## no idea what's inside, which is what lets the same wrapper host the
## video, map, telemetry, or settings window interchangeably.

@export var content_scene: PackedScene
@export var quad_size := Vector2(0.4, 0.3)
@export var viewport_size := Vector2i(800, 600)

## Pixels per meter, matching the ratio every other window in this
## project was already authored with (800x600 for a 0.4x0.3 quad, etc.) --
## set_quad_size() uses this to keep the SubViewport's resolution in the
## same fixed proportion to the quad's physical size always. Without
## this, changing quad_size while leaving viewport_size fixed changes the
## quad's aspect ratio relative to its own rendered texture's aspect
## ratio, stretching/squashing everything non-uniformly -- including
## text, which should always render at the font's own designed
## proportions, never distorted.
const PIXELS_PER_METER := 2000.0

## Fixed placement relative to the camera -- yaw/pitch in degrees off
## dead-ahead (positive yaw = right, positive pitch = up), distance in
## meters. Applied once in _ready(); surviving an external reparent is
## fine since position/rotation are plain local-space values, same as
## fpv_overlay.gd's DISTANCE_M.
@export var arc_yaw_deg := 0.0
@export var arc_pitch_deg := 0.0
@export var arc_distance_m := 1.0

@onready var viewport: SubViewport = $SubViewport
@onready var quad: MeshInstance3D = $Quad

func _ready() -> void:
	viewport.size = viewport_size
	if content_scene != null:
		var content := content_scene.instantiate()
		if content is Control:
			content.size = Vector2(viewport_size)
		viewport.add_child(content)

	var mesh := quad.mesh as QuadMesh
	mesh.size = quad_size

	var material := StandardMaterial3D.new()
	material.albedo_texture = viewport.get_texture()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	quad.material_override = material

	_apply_arc_placement()

## Resizes the quad in place -- used by main.gd to keep the Settings
## window's size matched to the FPV overlay's own current size (which
## changes live as Settings.fpv_width_percent/fpv_height_percent are
## dragged), rather than carrying its own independent fixed quad_size.
## Also rescales the SubViewport (and its Control content) to match, at
## the same fixed PIXELS_PER_METER density the quad started with, so the
## UI -- text included -- keeps its real-world designed proportions
## instead of stretching to fill a now-differently-shaped quad.
func set_quad_size(size: Vector2) -> void:
	quad_size = size
	(quad.mesh as QuadMesh).size = size

	viewport_size = Vector2i(roundi(size.x * PIXELS_PER_METER), roundi(size.y * PIXELS_PER_METER))
	viewport.size = viewport_size
	for child in viewport.get_children():
		if child is Control:
			child.size = Vector2(viewport_size)

## Spherical placement around the camera (which sits at this node's local
## origin once reparented): position is the standard yaw/pitch-from-
## straight-ahead spherical conversion, and rotation is the closed-form
## solution for "make the quad's default +Z-facing normal point back at
## the origin" -- rotation_degrees = (pitch, -yaw, 0) is what falls out of
## composing a Y-yaw and X-pitch rotation and solving for where +Z ends
## up; it is NOT just "rotation mirrors position", those differ by sign.
func _apply_arc_placement() -> void:
	var yaw := deg_to_rad(arc_yaw_deg)
	var pitch := deg_to_rad(arc_pitch_deg)
	position = arc_distance_m * Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		-cos(yaw) * cos(pitch),
	)
	rotation_degrees = Vector3(arc_pitch_deg, -arc_yaw_deg, 0)
