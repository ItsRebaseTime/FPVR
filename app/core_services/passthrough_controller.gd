extends Node
## Cycles the headset's passthrough mode between IR (default monochrome),
## RGB (requires the third-party Arcturus Vision Camera), and fully opaque
## Black.
##
## IMPORTANT caveat: Valve has not published an API to query or select
## which camera module is active (stock monochrome vs. Arcturus color) --
## see the architecture plan. Both IR and RGB therefore issue the exact
## same OpenXR call (alpha-blend passthrough); which physical sensor feeds
## that passthrough is decided by the OS/hardware, not this app. This class
## exists so that distinction can be slotted in later behind one call site
## (_apply_mode) the moment Valve documents a real switch, without any
## caller needing to change.

enum Mode { IR, RGB, BLACK }

signal mode_changed(mode: Mode)

var current_mode: Mode = Mode.IR

func _ready() -> void:
	current_mode = Settings.passthrough_mode as Mode
	_apply_mode(current_mode)
	# The Settings window's passthrough dropdown writes Settings.passthrough_mode
	# directly and only calls save_settings() on its own "Save" button -- it has
	# no reference to this controller, so this is the only way that change
	# actually reaches the OpenXR call below. Guarded by the current_mode check
	# so set_mode()'s own save_settings() call below doesn't re-apply itself.
	Settings.settings_changed.connect(_on_settings_changed)

func _on_settings_changed() -> void:
	var mode: Mode = Settings.passthrough_mode as Mode
	if mode != current_mode:
		current_mode = mode
		_apply_mode(mode)
		mode_changed.emit(mode)

func cycle() -> void:
	set_mode((current_mode + 1) % 3 as Mode)

func set_mode(mode: Mode) -> void:
	current_mode = mode
	_apply_mode(mode)
	Settings.passthrough_mode = mode
	Settings.save_settings()
	mode_changed.emit(mode)

func _apply_mode(mode: Mode) -> void:
	var interface := XRServer.find_interface("OpenXR")
	if interface == null:
		return # no XR runtime active (e.g. running the flat dev shell)
	match mode:
		Mode.BLACK:
			interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		Mode.IR, Mode.RGB:
			interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
