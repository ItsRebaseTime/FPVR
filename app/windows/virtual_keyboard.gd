extends PanelContainer
## A simple on-screen keyboard for text entry inside a SubViewport-rendered
## window. Desktop Linux's DisplayServer (what Steam Frame runs) has no
## built-in virtual keyboard the way Android/iOS do -- that only shows up
## automatically on platforms whose DisplayServer reports
## FEATURE_VIRTUAL_KEYBOARD -- and there's no physical keyboard in VR
## either, so this fills that gap. Caller (e.g. settings_window.gd) shows/
## hides it based on focus and wires key_pressed to whatever LineEdit is
## currently focused; this scene has no idea which field is active.

signal key_pressed(key: String)

const ROWS := [
	["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
	["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
	["a", "s", "d", "f", "g", "h", "j", "k", "l", "."],
	["z", "x", "c", "v", "b", "n", "m", ":", "/", "-"],
]
const KEY_SIZE := Vector2(44, 44)

@onready var _vbox: VBoxContainer = $VBox

func _ready() -> void:
	for row in ROWS:
		var hbox := HBoxContainer.new()
		hbox.alignment = BoxContainer.ALIGNMENT_CENTER
		for ch in row:
			hbox.add_child(_make_key(ch, ch, KEY_SIZE))
		_vbox.add_child(hbox)

	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_child(_make_key("Space", " ", Vector2(200, 44)))
	bottom.add_child(_make_key("<-", "BACKSPACE", Vector2(70, 44)))
	bottom.add_child(_make_key("Done", "DONE", Vector2(70, 44)))
	_vbox.add_child(bottom)

func _make_key(label: String, emit_value: String, min_size: Vector2) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = min_size
	# Buttons grab focus on click by default, which would steal it away
	# from whatever LineEdit is being typed into -- settings_window.gd's
	# gui_focus_changed listener would then see focus move to this
	# button (not a LineEdit) and hide the keyboard after the very first
	# keypress.
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(func(): key_pressed.emit(emit_value))
	return btn
