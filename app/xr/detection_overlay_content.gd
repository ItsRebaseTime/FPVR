extends Control
## Draws detection bounding boxes over the FPV video feed, plus a legend
## panel in a left-side strip -- the AI counterpart to
## elrs_hud_overlay_content.gd, using the same "transparent Control inside
## a SubViewport on a quad" trick (see detection_overlay.gd).
##
## DetectionService.detections_updated gives each detection's x/y/w/h as
## 0..1 fractions of the model's input frame (see
## core/src/ai/inference_engine.h's detect() doc comment) specifically so
## this mapping is just a multiply by the rendering canvas's own pixel
## size -- no need to know the model's input resolution, the source UVC
## frame's resolution, or how fpv_overlay.gd's quad is currently sized;
## sync_size() already keeps this SubViewport's aspect matched to the
## video, so a 0..1 fraction here lands in the same relative spot it did
## in the model's input frame.
##
## That canvas size is get_viewport().size, NOT this Control's own `size`
## property -- see _canvas_size's doc comment below for why: `size` comes
## back scaled by an unrelated content-scale factor, which previously
## caused a real, shipped bug (boxes correctly shaped but consistently
## offset toward bottom-right).
##
## No more inline "name confidence%" text drawn at each box: field testing
## showed that for a detection that fills most of the frame, the label
## (drawn just above the box's top-left corner) lands off the visible area
## entirely -- there's nowhere on-screen left to put it. The legend panel
## is the fix: a fixed, always-on-screen left-side strip listing which
## classes are currently active and how many of each, color-matched to the
## box outlines so the mapping is learnable at a glance rather than
## re-read every time.

const BOX_WIDTH := 3.0
const REFEREE_COLOR := Color(1.0, 0.85, 0.1, 1.0) # kept distinct from plain "person" on purpose -- a referee exclusion is the one thing worth visually calling out differently from the rest

# One fixed, memorable color per class -- never reassigned/recycled at
# runtime, so the same color always means the same thing across a whole
# session. class_id -> Color; see core/src/ai/coco_labels.h for the index
# table. Chosen to stay visually distinct from REFEREE_COLOR and from each
# other at a glance, not just numerically different.
const CLASS_COLORS := {
	0: Color(0.25, 1.0, 0.35, 1.0), # person -- green
	2: Color(0.35, 0.65, 1.0, 1.0), # car -- blue
	5: Color(0.85, 0.35, 1.0, 1.0), # bus -- purple
	7: Color(1.0, 0.55, 0.1, 1.0), # truck -- orange
}
const DEFAULT_COLOR := Color(0.85, 0.85, 0.85, 1.0) # any future class not in CLASS_COLORS yet

# Legend panel layout -- a "thin vertical window" on the left, per the
# user's request, not a full-width HUD element competing with the video.
const LEGEND_WIDTH := 170.0
const LEGEND_PADDING := 10.0
const LEGEND_ROW_HEIGHT := 26.0
const LEGEND_DOT_RADIUS := 6.0
const LEGEND_FONT_SIZE := 16
const LEGEND_BG_COLOR := Color(0.0, 0.0, 0.0, 0.55)
const LEGEND_TEXT_COLOR := Color(1.0, 1.0, 1.0, 1.0)

# Debug diagnostic panel -- top-right, so it doesn't collide with the
# legend (top-left). Settings.detection_show_debug_info-gated. Exists
# specifically to root-cause a reported bug where boxes are correctly
# *sized* but consistently offset in *position*, reproducible with the
# camera held still (so it isn't frame-to-frame detection latency) --
# showing the numbers at each stage (raw fraction -> model-input pixels
# -> this Control's own pixel space, which is what _draw_boxes() above
# actually uses) pinpoints which stage the offset is introduced at,
# rather than guessing from the rendered image alone.
const DEBUG_FONT_SIZE := 14
const DEBUG_LINE_HEIGHT := 18.0
const DEBUG_BG_COLOR := Color(0.0, 0.0, 0.0, 0.65)
const DEBUG_TEXT_COLOR := Color(1.0, 1.0, 0.6, 1.0)
const DEBUG_PANEL_WIDTH := 430.0
const DEBUG_MAX_DETECTIONS_SHOWN := 6

# Fixed display order -- always the same rows in the same order when
# present, rather than shuffling based on whatever order detections
# happened to come back in this frame, so the legend doesn't jitter.
const LEGEND_ORDER := [0, "referee", 2, 7, 5] # person, referee, car, truck, bus

var _detections: Array = []
var _frame_info: Dictionary = {}

# The actual pixel size of the SubViewport this Control is being drawn
# into -- used for all box/legend/debug-panel math below INSTEAD OF this
# Control's own `size` property. Root-caused a real bug (boxes correctly
# shaped but consistently offset toward bottom-right, reproducible with
# the camera held completely still so it wasn't detection-latency lag):
# this Control's `size` silently comes back as exactly 2x what the
# SubViewport actually renders at (confirmed reproducible at multiple
# SubViewport sizes, always precisely 2.0x, on both a desktop dev machine
# and the real Steam Frame) -- Godot's full-rect-anchor auto-resize
# appears to pull in the host display's own content-scale-factor when
# resolving a Control's size against its parent SubViewport, which
# `get_viewport().size` is immune to since it reports the SubViewport's
# own configured resolution directly, not a layout-resolved value.
var _canvas_size: Vector2

func _ready() -> void:
	DetectionService.detections_updated.connect(_on_detections_updated)

func _on_detections_updated(detections: Array, frame_info: Dictionary) -> void:
	_detections = detections
	_frame_info = frame_info
	queue_redraw()

func _draw() -> void:
	_canvas_size = Vector2(get_viewport().size)
	_draw_boxes()
	_draw_legend()
	if Settings.detection_show_debug_info:
		_draw_debug_info()

func _draw_boxes() -> void:
	for detection in _detections:
		var rect := Rect2(
			detection.get("x", 0.0) * _canvas_size.x,
			detection.get("y", 0.0) * _canvas_size.y,
			detection.get("w", 0.0) * _canvas_size.x,
			detection.get("h", 0.0) * _canvas_size.y,
		)
		var is_referee: bool = detection.get("referee_excluded", false)
		var color: Color = REFEREE_COLOR if is_referee else CLASS_COLORS.get(detection.get("class_id", -1), DEFAULT_COLOR)
		draw_rect(rect, color, false, BOX_WIDTH)

## class_name (from coco_labels.h) -> display label, title-cased. "person"
## and "referee" are kept as separate legend rows even though a referee is
## just a person detection with referee_excluded=true -- distinguishing
## them is the whole point of the feature (see referee_filter.cpp).
func _legend_label(key) -> String:
	return "Referee" if key is String else String(coco_label_for(key)).capitalize()

func _legend_color(key) -> Color:
	return REFEREE_COLOR if key is String else CLASS_COLORS.get(key, DEFAULT_COLOR)

## LEGEND_ORDER/counts keys are either an int class_id or the String
## "referee" -- comparing an int to a String directly with == is a
## runtime type error in GDScript (unlike Python), so every place that
## needs to tell them apart checks `is String` instead.
func coco_label_for(class_id: int) -> String:
	for detection in _detections:
		if detection.get("class_id", -1) == class_id:
			return detection.get("class_name", "class %d" % class_id)
	return "class %d" % class_id

func _draw_legend() -> void:
	var counts := {}
	for detection in _detections:
		var class_id = detection.get("class_id", -1)
		var key = "referee" if (class_id == 0 and detection.get("referee_excluded", false)) else class_id
		counts[key] = counts.get(key, 0) + 1

	var rows: Array = []
	for key in LEGEND_ORDER:
		if counts.has(key):
			rows.append(key)
	# Any class that shows up but wasn't anticipated in LEGEND_ORDER still
	# gets listed, just after the fixed set, rather than silently dropped.
	for key in counts:
		if not rows.has(key):
			rows.append(key)

	if rows.is_empty():
		return

	var panel_height: float = LEGEND_PADDING * 2.0 + rows.size() * LEGEND_ROW_HEIGHT
	draw_rect(Rect2(0, 0, LEGEND_WIDTH, panel_height), LEGEND_BG_COLOR, true)

	var font := ThemeDB.fallback_font
	var dot_x := LEGEND_PADDING + LEGEND_DOT_RADIUS
	var name_x := LEGEND_PADDING + LEGEND_DOT_RADIUS * 2.0 + 10.0
	var count_right_x := LEGEND_WIDTH - LEGEND_PADDING

	for i in range(rows.size()):
		var key = rows[i]
		var row_center_y: float = LEGEND_PADDING + i * LEGEND_ROW_HEIGHT + LEGEND_ROW_HEIGHT * 0.5
		var text_baseline_y: float = row_center_y + LEGEND_FONT_SIZE * 0.35

		draw_circle(Vector2(dot_x, row_center_y), LEGEND_DOT_RADIUS, _legend_color(key))
		draw_string(font, Vector2(name_x, text_baseline_y), _legend_label(key), HORIZONTAL_ALIGNMENT_LEFT, -1, LEGEND_FONT_SIZE, LEGEND_TEXT_COLOR)
		# Right-aligned count, anchored to the panel's own right edge, so
		# counts line up in a column regardless of how long each class
		# name is -- "aligned like a table" per the user's request,
		# without needing a real table/grid container in a _draw() context.
		draw_string(font, Vector2(name_x, text_baseline_y), str(counts[key]), HORIZONTAL_ALIGNMENT_RIGHT, count_right_x - name_x, LEGEND_FONT_SIZE, LEGEND_TEXT_COLOR)

## Shows the numbers at every stage of the coordinate pipeline:
##   - this SubViewport's actual render resolution (get_viewport().size,
##     what _draw_boxes() above actually multiplies fractions by -- see
##     _canvas_size) vs. this Control's own `size` property, left in here
##     specifically so the ~2x discrepancy that caused the original bug
##     stays visible/verifiable on-device rather than just in a comment.
##   - the source camera frame size and the model's fixed input size,
##     from frame_info (see detection_service.gd's detections_updated
##     signal doc comment).
##   - per detection: the raw 0..1 fraction InferenceEngine.detect()
##     returned, that fraction converted to model-input-pixel-space
##     (fraction * net_input_size) purely for human cross-reference, and
##     that same fraction converted to this Control's pixel space
##     (fraction * size) -- the literal numbers _draw_boxes() uses to
##     draw the rect. If that last column visually lands on the object
##     when you'd expect it to, the bug is downstream of this script
##     (the quad/texture mapping, not this math); if it doesn't, the bug
##     is in this math or in what detect() returned.
func _draw_debug_info() -> void:
	var font := ThemeDB.fallback_font
	var viewport_size: Vector2 = get_viewport().size

	var lines: Array[String] = []
	lines.append("viewport.size: %dx%d (used for drawing)" % [int(viewport_size.x), int(viewport_size.y)])
	lines.append("this Control.size: %dx%d (NOT used -- see note below)" % [int(size.x), int(size.y)])
	lines.append("source frame: %dx%d" % [_frame_info.get("source_width", -1), _frame_info.get("source_height", -1)])
	lines.append("model input: %dx%d" % [_frame_info.get("net_input_size", -1), _frame_info.get("net_input_size", -1)])
	lines.append("")

	var net_size: int = _frame_info.get("net_input_size", 416)
	var shown := 0
	for detection in _detections:
		if shown >= DEBUG_MAX_DETECTIONS_SHOWN:
			lines.append("... (%d more)" % (_detections.size() - shown))
			break
		var x: float = detection.get("x", 0.0)
		var y: float = detection.get("y", 0.0)
		var w: float = detection.get("w", 0.0)
		var h: float = detection.get("h", 0.0)
		var cls: String = detection.get("class_name", "?")
		lines.append("%s frac(%.3f,%.3f %.3fx%.3f)" % [cls, x, y, w, h])
		lines.append("  model_px(%d,%d %dx%d) canvas_px(%d,%d %dx%d)" % [
			int(x * net_size), int(y * net_size), int(w * net_size), int(h * net_size),
			int(x * _canvas_size.x), int(y * _canvas_size.y), int(w * _canvas_size.x), int(h * _canvas_size.y),
		])
		shown += 1

	var panel_width := DEBUG_PANEL_WIDTH
	var panel_height: float = lines.size() * DEBUG_LINE_HEIGHT + 12.0
	var panel_x := _canvas_size.x - panel_width
	draw_rect(Rect2(panel_x, 0, panel_width, panel_height), DEBUG_BG_COLOR, true)

	for i in range(lines.size()):
		draw_string(font, Vector2(panel_x + 8.0, 16.0 + i * DEBUG_LINE_HEIGHT), lines[i], HORIZONTAL_ALIGNMENT_LEFT, panel_width - 16.0, DEBUG_FONT_SIZE, DEBUG_TEXT_COLOR)
