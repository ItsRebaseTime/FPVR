extends Node
## Throwaway bench harness for the AI inference layer (see the plan at
## /home/itsrebasetime/.claude/plans/i-want-to-add-transient-lemur.md) --
## not wired into any shell/autoload. Loads the real NanoDet-Plus-m_416
## person detector (see app/assets/models/README.md) and times detect()
## end to end (preprocess + forward pass + DFL decode + NMS, not just the
## raw forward pass benchmark_ms() measures) on a synthetic frame, to get
## real detect()-call throughput numbers on actual hardware. Run directly:
##   godot --path app --headless app/tests/ai_inference_bench.tscn
##
## The synthetic frame is random noise at the UVC stream's native
## resolution (HardwareHub.VIDEO_WIDTH/HEIGHT) -- it won't trigger real
## person detections (there's no learned pattern in noise), which is
## fine: this measures throughput/crash-safety, not detection accuracy.
## Accuracy needs a real camera pointed at real people, which is the
## plan's own verification-plan item for that, not this harness.

const MODEL_DIR := "res://assets/models/"
const MODEL_PARAM := MODEL_DIR + "nanodet-plus-m_416.param"
const MODEL_BIN := MODEL_DIR + "nanodet-plus-m_416.bin"
const NET_INPUT_SIZE := 416
const FRAME_WIDTH := 1280
const FRAME_HEIGHT := 720
const ITERATIONS := 30
const TARGET_CLASSES: PackedInt32Array = [0, 2, 5, 7] # person, car, bus, truck -- see coco_labels.h

func _ready() -> void:
	print("Vulkan available: ", InferenceEngine.is_vulkan_available())

	var param_text := FileAccess.get_file_as_string(MODEL_PARAM)
	var bin_bytes := FileAccess.get_file_as_bytes(MODEL_BIN)
	print("param_text len=%d bin_bytes len=%d" % [param_text.length(), bin_bytes.size()])

	var engine := InferenceEngine.new()
	if not engine.select_backend("vulkan"):
		print("select_backend failed")
		get_tree().quit(1)
		return
	if not engine.load_param(param_text):
		print("load_param failed")
		get_tree().quit(1)
		return
	if not engine.load_model(bin_bytes):
		print("load_model failed")
		get_tree().quit(1)
		return
	engine.set_net_input_size(NET_INPUT_SIZE)

	print("Active backend: ", engine.get_active_backend())

	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var frame := PackedByteArray()
	frame.resize(FRAME_WIDTH * FRAME_HEIGHT * 3)
	for i in range(frame.size()):
		frame[i] = rng.randi_range(0, 255)

	# One untimed warm-up call -- same rationale as benchmark_ms()'s own
	# warm-up pass (first-ever Vulkan dispatch pays one-time pipeline
	# setup cost).
	engine.detect(frame, FRAME_WIDTH, FRAME_HEIGHT, 0.3, TARGET_CLASSES)

	var start_usec := Time.get_ticks_usec()
	var total_detections := 0
	for i in range(ITERATIONS):
		var detections: Array = engine.detect(frame, FRAME_WIDTH, FRAME_HEIGHT, 0.3, TARGET_CLASSES)
		total_detections += detections.size()
	var elapsed_usec := Time.get_ticks_usec() - start_usec
	var avg_ms := (elapsed_usec / 1000.0) / ITERATIONS

	print("detect() on %dx%d -> %dx%d: avg_ms=%.2f hz=%.1f (total detections across %d noise frames: %d, expected ~0)" % [
		FRAME_WIDTH, FRAME_HEIGHT, NET_INPUT_SIZE, NET_INPUT_SIZE, avg_ms, 1000.0 / avg_ms, ITERATIONS, total_detections
	])

	get_tree().quit()
