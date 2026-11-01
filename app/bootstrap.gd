extends Node
## Entry point for every build target. Picks the right shell at runtime
## instead of baking a platform choice into the export preset -- the same
## APK installed on a Steam Frame and on a regular Android phone (like a
## Pixel with no OpenXR runtime) needs to boot into different shells, and
## "xr_mode=OpenXR" at export time was forcing the activity to wait on an
## XR session that a plain phone can never provide, which is what produced
## the black screen.
##
## The OpenXR probe itself is platform-agnostic -- Steam Frame runs Linux,
## not Android, so it must not be gated behind OS.get_name() == "Android"
## (that gate previously meant the VR shell could never be reached at all
## on Steam Frame, even with xr/openxr/enabled=true in project settings).

func _ready() -> void:
	var target_scene := "res://shells/shell_linux_pc/main.tscn"

	var interface := XRServer.find_interface("OpenXR")
	# initialize() is the actual availability probe -- a plain phone with no
	# OpenXR runtime (e.g. a Pixel) returns an interface object but
	# initialize() fails; a real headset succeeds. Either way, this is the
	# one initialize() call for the whole app: xr_rig.gd checks
	# is_initialized() first and will not call it again.
	if interface != null and interface.initialize():
		target_scene = "res://shells/shell_vr_steamframe/main.tscn"
	elif OS.get_name() == "Android":
		target_scene = "res://shells/shell_android_phone/main.tscn"

	# Deferred: the tree is still mid-setup during this node's own _ready().
	get_tree().call_deferred("change_scene_to_file", target_scene)
