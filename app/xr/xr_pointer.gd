extends Node
## Laser-pointer-and-click interaction for the window content Controls
## (Settings' OptionButtons/LineEdits/SpinBox/Button, mainly) -- the only
## way to interact *inside* a window now that the whole arc is
## permanently head-locked (see head_locked_window.gd) instead of being
## grabbable.
##
## Casts a ray from each controller's forward direction (-Z), intersects
## it against every registered window's quad plane in that window's own
## local space (pure math, no physics bodies needed since quad_size/
## viewport_size are already known), and forwards the hit as a synthetic
## mouse motion/click straight into that window's SubViewport via
## push_input() -- the standard way to drive a SubViewport-on-a-quad GUI
## from VR, since a SubViewport never reads the Input singleton on its
## own.
##
## Click button: confirmed on real hardware that only a full, hard
## trigger pull ("trigger_click") registers at all -- shoulder_click,
## primary_click (thumbstick), and select_button (System) never fire,
## despite all having real bindings under the Frame profile in
## openxr_action_map.tres exactly like the buttons that do work (A/B/X/Y,
## View). Requiring a full pull isn't comfortable for repeated UI
## clicking, so this also reads the trigger's plain analog value
## ("trigger", a float action, bound to /input/trigger/value under the
## Frame profile) against a much lower threshold -- a light partial
## squeeze now registers as a click, the hard detent is just one way to
## exceed that threshold. CLICK_ACTION_CANDIDATES (the boolean actions)
## stay in the mix and still get logged on every edge in case a future
## runtime update makes one of the currently-dead ones start working.
const CLICK_ACTION_CANDIDATES := ["shoulder_click", "trigger_click", "primary_click", "select_button"]
const TRIGGER_VALUE_ACTION := "trigger"
const TRIGGER_VALUE_THRESHOLD := 0.3
const MAX_RAY_LENGTH := 5.0
const LASER_RADIUS := 0.0015
const LASER_COLOR := Color(0.3, 0.9, 1.0)

@export var left_controller: XRController3D
@export var right_controller: XRController3D

## Suspended while the FPV overlay is active (see main.gd) -- the lasers
## have nothing to point at once the windows are hidden.
var enabled := true

var windows: Array[Node3D] = []

var _lasers: Dictionary = {} # XRController3D -> MeshInstance3D
var _hovered: Dictionary = {} # XRController3D -> Node3D (window) or null
var _hover_pixel: Dictionary = {} # XRController3D -> Vector2
var _click_target: Dictionary = {} # XRController3D -> Node3D (window)
var _prev_click: Dictionary = {} # XRController3D -> bool
var _debug_prev_fired: Dictionary = {} # "<hand>:<action>" -> bool

func register_window(window: Node3D) -> void:
	windows.append(window)

func _make_laser() -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = LASER_RADIUS
	mesh.bottom_radius = LASER_RADIUS
	mesh.height = 1.0
	mesh.radial_segments = 8

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = LASER_COLOR
	mat.emission_enabled = true
	mat.emission = LASER_COLOR

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	# CylinderMesh height runs along local +/-Y; rotating -90 deg about X
	# maps that to local -Z, i.e. the controller's forward direction.
	mi.rotation_degrees = Vector3(-90, 0, 0)
	return mi

func _process(_delta: float) -> void:
	if not enabled:
		for laser in _lasers.values():
			laser.visible = false
		return
	for controller in [left_controller, right_controller]:
		if controller != null:
			_update_controller(controller)

func _update_controller(controller: XRController3D) -> void:
	# Lazily created here rather than in _ready(): left_controller/
	# right_controller are assigned by the shell's main.gd _ready(), which
	# (as the parent) runs *after* this node's own _ready() -- creating
	# the laser there would always find both still null.
	var laser: MeshInstance3D = _lasers.get(controller)
	if laser == null:
		laser = _make_laser()
		controller.add_child(laser)
		_lasers[controller] = laser

	if not controller.get_is_active():
		if laser != null:
			laser.visible = false
		return

	var origin := controller.global_position
	var dir := -controller.global_transform.basis.z.normalized()

	var hit_window: Node3D = null
	var hit_dist := MAX_RAY_LENGTH
	var hit_pixel := Vector2.ZERO

	for w in windows:
		if not w.visible:
			continue
		var hit: Variant = _raycast_window(w, origin, dir)
		if hit != null and hit["dist"] < hit_dist:
			hit_dist = hit["dist"]
			hit_window = w
			hit_pixel = hit["pixel"]

	if laser != null:
		laser.visible = true
		laser.scale = Vector3(1, hit_dist, 1)
		laser.position = Vector3(0, 0, -hit_dist * 0.5)

	var prev_hover: Node3D = _hovered.get(controller)
	if hit_window != prev_hover:
		if prev_hover != null:
			_send_mouse_motion(prev_hover.viewport, Vector2(-1, -1), _is_clicking(controller))
		_hovered[controller] = hit_window
	if hit_window != null:
		_hover_pixel[controller] = hit_pixel
		_send_mouse_motion(hit_window.viewport, hit_pixel, _is_clicking(controller))

	var pressed: bool = _is_click_pressed(controller)
	var was_pressed: bool = _prev_click.get(controller, false)
	if pressed and not was_pressed and hit_window != null:
		_click_target[controller] = hit_window
		_send_mouse_button(hit_window.viewport, hit_pixel, true)
	elif not pressed and was_pressed:
		var target: Node3D = _click_target.get(controller)
		if target != null:
			var release_pixel: Vector2 = hit_pixel if hit_window == target else _hover_pixel.get(controller, hit_pixel)
			_send_mouse_button(target.viewport, release_pixel, false)
			_click_target[controller] = null
	_prev_click[controller] = pressed

func _is_clicking(controller: XRController3D) -> bool:
	return _click_target.get(controller) != null

## True if any of CLICK_ACTION_CANDIDATES is pressed, or the trigger's
## analog value clears TRIGGER_VALUE_THRESHOLD, on this controller. Logs
## (once per press edge) exactly which signal fired, so a still-dead
## boolean candidate can be confirmed and dropped later.
func _is_click_pressed(controller: XRController3D) -> bool:
	var hand := "left" if controller == left_controller else "right"
	var any_pressed := false
	for action in CLICK_ACTION_CANDIDATES:
		var key := "%s:%s" % [hand, action]
		var fired: bool = controller.is_button_pressed(action)
		if fired:
			any_pressed = true
		if fired and not _debug_prev_fired.get(key, false):
			print("XRPointer: click candidate \"", action, "\" fired on ", hand, " controller")
		_debug_prev_fired[key] = fired

	var trigger_key := "%s:%s" % [hand, TRIGGER_VALUE_ACTION]
	var trigger_fired: bool = controller.get_float(TRIGGER_VALUE_ACTION) > TRIGGER_VALUE_THRESHOLD
	if trigger_fired:
		any_pressed = true
	if trigger_fired and not _debug_prev_fired.get(trigger_key, false):
		print("XRPointer: trigger value cleared threshold on ", hand, " controller")
	_debug_prev_fired[trigger_key] = trigger_fired

	return any_pressed

func _raycast_window(window: Node3D, origin: Vector3, dir: Vector3):
	var inv := window.global_transform.affine_inverse()
	var local_origin: Vector3 = inv * origin
	var local_dir: Vector3 = (inv.basis * dir).normalized()
	if absf(local_dir.z) < 0.0001:
		return null
	var t := -local_origin.z / local_dir.z
	if t <= 0.0 or t > MAX_RAY_LENGTH:
		return null
	var hit_local: Vector3 = local_origin + local_dir * t
	var half: Vector2 = window.quad_size * 0.5
	if absf(hit_local.x) > half.x or absf(hit_local.y) > half.y:
		return null
	var quad_size: Vector2 = window.quad_size
	var viewport_size: Vector2i = window.viewport_size
	var u: float = (hit_local.x + half.x) / quad_size.x
	var v: float = (half.y - hit_local.y) / quad_size.y
	return {
		"dist": t,
		"pixel": Vector2(u * viewport_size.x, v * viewport_size.y),
	}

func _send_mouse_motion(viewport: SubViewport, pixel_pos: Vector2, button_held: bool) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pixel_pos
	ev.global_position = pixel_pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if button_held else 0
	viewport.push_input(ev)

func _send_mouse_button(viewport: SubViewport, pixel_pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pixel_pos
	ev.global_position = pixel_pos
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(ev)
