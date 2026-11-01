extends MeshInstance3D
## Transparent HUD quad showing ELRS link/battery/flight-mode data
## directly on top of the FPV video feed -- a child of fpv_overlay.gd, not
## a sibling, specifically so it always sits exactly at the same
## position/size as the video quad without duplicating fpv_overlay's
## percent-of-FOV-to-meters math: the parent just calls sync_size() with
## its own current size whenever that changes (Settings.fpv_width_percent/
## fpv_height_percent), and nudges this a hair closer to the camera
## (local +Z, see position below) so it draws in front without z-fighting.
##
## The SubViewport behind this quad renders with a transparent background
## (transparent_bg = true) and the quad's own material allows alpha, so
## only the actual label text occludes the video -- everywhere else shows
## the feed underneath unchanged. render_target_update_mode is left at
## Godot's default (UPDATE_WHEN_VISIBLE) rather than forced to ALWAYS like
## the old grabbable windows needed: this is only ever visible together
## with the FPV feed, so there's nothing to keep warm while hidden -- one
## less thing rendering when passthrough or Settings is what's showing.

const VIEWPORT_SIZE := Vector2i(800, 600)

@onready var _viewport: SubViewport = $SubViewport

func _ready() -> void:
	position = Vector3(0, 0, 0.01)
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true

	var content: Control = load("res://xr/elrs_hud_overlay_content.tscn").instantiate()
	content.size = Vector2(VIEWPORT_SIZE)
	_viewport.add_child(content)

	var material := StandardMaterial3D.new()
	material.albedo_texture = _viewport.get_texture()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = material

func sync_size(meters: Vector2) -> void:
	(mesh as QuadMesh).size = meters
