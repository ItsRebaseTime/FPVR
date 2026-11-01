extends Control
## Draws detection bounding boxes over the FPV video feed, plus a legend
## panel in a left-side strip -- the AI counterpart to
## elrs_hud_overlay_content.gd, using the same "transparent Control inside
## a SubViewport on a quad" trick (see detection_overlay.gd).
##
## DetectionService.detections_updated gives each detection's x/y/w/h as
## 0..1 fractions of the model's input frame (see
## core/src/ai/inference_engine.h's detect() doc comment) specifically so
## this mapping is just a multiply by this Control's own size -- no need to
## know the model's input resolution, the source UVC frame's resolution, or
## how fpv_overlay.gd's quad is currently sized; sync_size() already keeps
## this SubViewport's aspect matched to the video, so a 0..1 fraction here
## lands in the same relative spot it did in the model's input frame.
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

# Fixed display order -- always the same rows in the same order when
# present, rather than shuffling based on whatever order detections
# happened to come back in this frame, so the legend doesn't jitter.
const LEGEND_ORDER := [0, "referee", 2, 7, 5] # person, referee, car, truck, bus

var _detections: Array = []

func _ready() -> void:
	DetectionService.detections_updated.connect(_on_detections_updated)

func _on_detections_updated(detections: Array) -> void:
	_detections = detections
	queue_redraw()

func _draw() -> void:
	_draw_boxes()
	_draw_legend()

func _draw_boxes() -> void:
	for detection in _detections:
		var rect := Rect2(
			detection.get("x", 0.0) * size.x,
			detection.get("y", 0.0) * size.y,
			detection.get("w", 0.0) * size.x,
			detection.get("h", 0.0) * size.y,
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
