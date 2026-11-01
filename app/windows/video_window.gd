extends PanelContainer
## UAV video feed window. Purely a consumer of HardwareHub's video stream --
## knows nothing about USB/V4L2, so it works unmodified in any shell (flat
## or wrapped in a SubViewport+quad for VR).

@onready var _texture_rect: TextureRect = $Margin/Content/TextureRect
@onready var _status_label: Label = $Margin/Content/StatusLabel
@onready var _warning_label: Label = $Margin/Content/WarningLabel

func _ready() -> void:
	HardwareHub.video_frame_ready.connect(_on_frame)
	_update_status()

func _process(_delta: float) -> void:
	_update_status()

func _update_status() -> void:
	_status_label.visible = not HardwareHub.has_video()
	var driver_info: Dictionary = HardwareHub.get_video_driver_info()
	var warning: String = driver_info.get("warning", "")
	_warning_label.visible = warning != ""
	if warning != "":
		_warning_label.text = "WARNING: " + warning

func _on_frame(bytes: PackedByteArray, format: String, width: int, height: int) -> void:
	var image := Image.new()
	if format == "mjpeg":
		if image.load_jpg_from_buffer(bytes) != OK:
			return
	else:
		image.set_data(width, height, false, Image.FORMAT_RGB8, bytes)
	_texture_rect.texture = ImageTexture.create_from_image(image)
