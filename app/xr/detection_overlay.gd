extends MeshInstance3D
## Transparent HUD quad showing AI detection bounding boxes directly on top
## of the FPV video feed -- same role and the exact same trick as
## elrs_hud_overlay.gd (a child of fpv_overlay.gd so it always tracks that
## quad's size via sync_size(), nudged a hair closer to the camera so it
## draws in front without z-fighting), just with a different content scene.
##
## Gated by Settings.detection_show_overlay (toggled in Settings' "AI
## Detection" tab).

const VIEWPORT_SIZE := Vector2i(800, 600)

@onready var _viewport: SubViewport = $SubViewport

func _ready() -> void:
	visible = Settings.detection_show_overlay
	position = Vector3(0, 0, 0.011) # a hair closer than ElrsOverlay's 0.01 so neither z-fights the other
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true

	var content: Control = load("res://xr/detection_overlay_content.tscn").instantiate()
	content.size = Vector2(VIEWPORT_SIZE)
	_viewport.add_child(content)

	var material := StandardMaterial3D.new()
	material.albedo_texture = _viewport.get_texture()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = material

	Settings.settings_changed.connect(_on_settings_changed)

func _on_settings_changed() -> void:
	visible = Settings.detection_show_overlay

func sync_size(meters: Vector2) -> void:
	(mesh as QuadMesh).size = meters
