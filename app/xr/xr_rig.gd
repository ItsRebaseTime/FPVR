extends XROrigin3D
## Initializes OpenXR if a runtime is present and enables XR rendering on
## the viewport. Falls back to flat rendering (just logs a warning) when no
## runtime is available, which is the normal case on a desktop dev machine
## with no headset attached -- lets every other system (hub, windows,
## bridge) keep working for iteration without needing hardware.

var xr_active := false

func _ready() -> void:
	var interface := XRServer.find_interface("OpenXR")
	if interface != null and interface.is_initialized():
		_activate_xr()
	elif interface != null and interface.initialize():
		_activate_xr()
	else:
		push_warning("FPVR: no OpenXR runtime found, running in flat fallback mode")

func _activate_xr() -> void:
	get_viewport().use_xr = true
	xr_active = true
	# ALPHA_BLEND passthrough (see passthrough_controller.gd) only actually
	# shows the real-world camera feed if our own rendered output has
	# alpha=0 wherever nothing opaque is drawn -- without this, Godot's
	# default opaque clear color paints over the whole view regardless of
	# which OpenXR blend mode is requested, which is why IR/RGB/Black all
	# looked identically gray before this. The WorldEnvironment sibling
	# node (background_mode=BG_COLOR, alpha=0) supplies the other half.
	get_viewport().transparent_bg = true
