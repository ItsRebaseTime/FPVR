extends Node
## Autoload singleton: runs person-detection inference on the FPV video
## stream in the background, at an adjustable rate decoupled from the video
## framerate -- smooth video display is the priority (see the plan at
## /home/itsrebasetime/.claude/plans/i-want-to-add-transient-lemur.md),
## detection is a best-effort background process, never something the
## render/display path waits on.
##
## Mirrors hardware_hub.gd's split: a background Thread owns the actual
## InferenceEngine.detect() calls (GPU dispatch + NCNN's own CPU-side
## pre/post-processing can take a few ms, which would otherwise stall
## whatever thread calls it), while this class's _ready()/_exit_tree() own
## the thread's lifecycle and a Mutex-guarded "latest frame" handoff from
## HardwareHub's video_frame_ready signal (main thread) to the detection
## loop (background thread).
##
## Model: NanoDet-Plus-m_416, a permissively-licensed (Apache-2.0)
## detector trained on all 80 COCO classes -- see app/assets/models/README.md
## for provenance/license and core/src/ai/nanodet_decoder.h for the decode
## implementation and why this model was chosen over Ultralytics YOLOv8
## (AGPL-3.0). This project only decodes a few of those 80 classes (see
## TARGET_CLASSES_* below) -- checking more costs a little extra CPU-side
## decode work per detect() call, not extra GPU time, since the forward
## pass already computes scores for all 80 regardless of which we read.

signal detections_updated(detections: Array)

const MODEL_DIR := "res://assets/models/"
const MODEL_PARAM := MODEL_DIR + "nanodet-plus-m_416.param"
const MODEL_BIN := MODEL_DIR + "nanodet-plus-m_416.bin"
const MODEL_INPUT_SIZE := 416

# COCO class indices -- see core/src/ai/coco_labels.h for the full table.
const COCO_PERSON := 0
const COCO_CAR := 2
const COCO_BUS := 5
const COCO_TRUCK := 7
const TARGET_CLASSES_PEOPLE_ONLY: PackedInt32Array = [COCO_PERSON]
const TARGET_CLASSES_WITH_VEHICLES: PackedInt32Array = [COCO_PERSON, COCO_CAR, COCO_BUS, COCO_TRUCK]

var _engine := InferenceEngine.new()
var _model_loaded := false

var _thread: Thread
var _running := false

var _frame_mutex := Mutex.new()
var _latest_rgb_bytes: PackedByteArray
var _latest_width := 0
var _latest_height := 0
var _has_new_frame := false

func _ready() -> void:
	HardwareHub.video_frame_ready.connect(_on_video_frame_ready)
	_load_model()

	_running = true
	_thread = Thread.new()
	_thread.start(_detection_loop)

func _exit_tree() -> void:
	_running = false
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()

func is_model_loaded() -> bool:
	return _model_loaded

func get_active_backend() -> String:
	return _engine.get_active_backend()

func _load_model() -> void:
	if not _engine.select_backend(Settings.detection_backend):
		print("DetectionService: no usable GPU backend available -- detection disabled")
		return

	var param_text := FileAccess.get_file_as_string(MODEL_PARAM)
	var bin_bytes := FileAccess.get_file_as_bytes(MODEL_BIN)
	if param_text.is_empty() or bin_bytes.is_empty():
		print("DetectionService: model files not found at ", MODEL_DIR)
		return
	if not _engine.load_param(param_text):
		print("DetectionService: load_param failed")
		return
	if not _engine.load_model(bin_bytes):
		print("DetectionService: load_model failed")
		return
	_engine.set_net_input_size(MODEL_INPUT_SIZE)

	_model_loaded = true
	print("DetectionService: model loaded, backend=", _engine.get_active_backend())

## Converts whatever HardwareHub handed us (MJPEG or already-RGB8, see
## hardware_hub.gd's doc comment) to a plain RGB8 byte buffer -- the only
## format InferenceEngine.detect() understands -- and hands it to the
## detection thread. Runs on the main thread (it's a signal callback), so
## it stays a cheap copy/decode with no inference in it.
##
## For MJPEG, width/height are taken from the *decoded Image*, not the
## signal's own width/height parameters -- those describe what was
## negotiated with the camera at open time, which isn't guaranteed to be
## the size every actual JPEG frame decodes to (fpv_overlay.gd's display
## path never hits this, since it hands the Image straight to
## ImageTexture.create_from_image() without needing explicit dimensions
## at all). A mismatch here doesn't throw an error -- InferenceEngine's
## preprocessing just reads rgb_bytes assuming the wrong row stride,
## scrambling the model's input into noise, which silently produces a
## spurious, mislocated, low-confidence detection rather than a crash.
func _on_video_frame_ready(bytes: PackedByteArray, format: String, width: int, height: int) -> void:
	var rgb_bytes: PackedByteArray
	if format == "mjpeg":
		var image := Image.new()
		if image.load_jpg_from_buffer(bytes) != OK:
			return
		if image.get_format() != Image.FORMAT_RGB8:
			image.convert(Image.FORMAT_RGB8)
		rgb_bytes = image.get_data()
		width = image.get_width()
		height = image.get_height()
	else:
		rgb_bytes = bytes

	_frame_mutex.lock()
	_latest_rgb_bytes = rgb_bytes
	_latest_width = width
	_latest_height = height
	_has_new_frame = true
	_frame_mutex.unlock()

## Background thread: sleeps for the configured interval, grabs whatever
## frame is newest (dropping any frames that arrived in between -- this is
## deliberately a sampler, not a queue, since a backlog of stale frames
## would only add latency with no benefit), and runs inference on it.
##
## Reads Settings.detection_rate_hz/detection_enabled/
## detection_confidence_threshold directly from this thread without a
## mutex -- they're plain numeric/bool fields the Settings window writes
## one at a time from the main thread, so the worst case is this loop
## using a value that's one tick stale, never a crash. Not worth a lock
## for that.
func _detection_loop() -> void:
	while _running:
		var interval_sec: float = 1.0 / maxf(Settings.detection_rate_hz, 0.01)
		OS.delay_msec(int(interval_sec * 1000.0))
		if not _running:
			break
		if not _model_loaded or not Settings.detection_enabled:
			continue

		_frame_mutex.lock()
		var have_frame := _has_new_frame
		var rgb_bytes := _latest_rgb_bytes
		var width := _latest_width
		var height := _latest_height
		_has_new_frame = false
		_frame_mutex.unlock()

		if not have_frame:
			continue

		var target_classes := TARGET_CLASSES_WITH_VEHICLES if Settings.detection_include_vehicles else TARGET_CLASSES_PEOPLE_ONLY
		var detections: Array = _engine.detect(rgb_bytes, width, height, Settings.detection_confidence_threshold, target_classes)
		if Settings.detection_referee_exclusion_enabled:
			_apply_referee_exclusion(detections, rgb_bytes, width, height)
		_add_position_estimates(detections)
		print("DetectionService: inference on %dx%d frame -> %d detection(s)" % [width, height, detections.size()])
		call_deferred("emit_signal", "detections_updated", detections)

## Flags each person detection as referee_excluded (in place) via
## InferenceEngine.check_vest_color() -- an appearance cue (the vest a
## referee is wearing), not a posture one, since referees and players do
## all the same physical things on the field. See referee_filter.cpp's
## doc comment for the actual pixel logic. Doesn't apply to non-person
## classes (vehicles don't wear referee vests) -- those are left
## unflagged rather than running a meaningless pixel check on them.
func _apply_referee_exclusion(detections: Array, rgb_bytes: PackedByteArray, width: int, height: int) -> void:
	var hsv := _vest_hsv_range()

	for detection in detections:
		if detection.get("class_id", -1) != COCO_PERSON:
			continue
		detection["referee_excluded"] = InferenceEngine.check_vest_color(
			rgb_bytes, width, height,
			detection.get("x", 0.0), detection.get("y", 0.0), detection.get("w", 0.0), detection.get("h", 0.0),
			hsv["hue_min"], hsv["hue_max"], hsv["sat_min"], hsv["sat_max"], hsv["val_min"], hsv["val_max"],
		)

## Derives an HSV match window from Settings.detection_vest_color (the
## color picked in the Settings UI) and detection_vest_color_tolerance
## (0..1, how wide a net it casts), rather than storing 6 raw min/max
## fields the way v1 did -- a color wheel can't drive 6 independent
## sliders, but it can drive one color + one tolerance. Hue tolerance
## scales 5..90 degrees, sat/val tolerance scales 0..0.5, deliberately
## nonlinear with hue since hue is the primary discriminator for a vest
## color and sat/val mostly just need to rule out very dark/washed-out
## versions of it.
func _vest_hsv_range() -> Dictionary:
	var color := Settings.detection_vest_color
	var tol: float = Settings.detection_vest_color_tolerance
	var hue_deg := color.h * 360.0
	var hue_tol_deg: float = lerpf(5.0, 90.0, tol)
	return {
		"hue_min": fmod(hue_deg - hue_tol_deg + 360.0, 360.0),
		"hue_max": fmod(hue_deg + hue_tol_deg, 360.0),
		"sat_min": clampf(color.s - lerpf(0.0, 0.5, tol), 0.0, 1.0),
		"sat_max": 1.0,
		"val_min": clampf(color.v - lerpf(0.0, 0.5, tol), 0.0, 1.0),
		"val_max": 1.0,
	}

## Adds a ground-position estimate (lat/lon/range/bearing) to each
## detection, in place, via DetectionGeolocation -- see that file for the
## actual math/assumptions. HardwareHub.get_uav_fix() is safe to call from
## this background thread: it's a plain Dictionary snapshot HardwareHub's
## own _process() rebuilds each tick on the main thread, not something
## this thread mutates.
func _add_position_estimates(detections: Array) -> void:
	var uav_fix: Dictionary = HardwareHub.get_uav_fix()
	for detection in detections:
		var center := Vector2(
			detection.get("x", 0.0) + detection.get("w", 0.0) * 0.5,
			detection.get("y", 0.0) + detection.get("h", 0.0) * 0.5,
		)
		var estimate := DetectionGeolocation.estimate_ground_position(
			uav_fix, center, Settings.camera_tilt_deg, Settings.camera_hfov_deg, Settings.camera_vfov_deg)
		detection["position_estimate"] = estimate
