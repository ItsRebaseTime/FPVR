#ifndef FPVR_INFERENCE_ENGINE_H
#define FPVR_INFERENCE_ENGINE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <net.h>

namespace fpvr {

// Runs object-detection inference on decoded FPV frames via NCNN. GPU
// (Vulkan, via NCNN's own Vulkan compute backend on the Adreno GPU) only --
// deliberately no CPU fallback: the Snapdragon's CPU cores aren't powerful
// enough for this workload at a usable rate, and sustained CPU inference
// would drain battery far faster than the GPU path. An NPU (Hexagon/QNN)
// backend is a planned addition once Qualcomm's QNN backend libraries are
// actually available on-device (as of writing, SteamOS ships none).
//
// Model output decoding (box/class extraction from the raw forward-pass
// tensors) is architecture-specific -- detect() currently decodes
// NanoDet-Plus-m specifically (see nanodet_decoder.h for the model choice
// and why: permissively licensed, unlike Ultralytics YOLOv8). Swapping in
// a different model means swapping in a different decoder there, and
// updating detect()'s preprocessing (mean/norm/channel-order) to match.
class InferenceEngine : public godot::RefCounted {
	GDCLASS(InferenceEngine, godot::RefCounted)

protected:
	static void _bind_methods();

private:
	ncnn::Net net;
	bool loaded = false;
	godot::String active_backend = "none";
	// NCNN's load_model(const unsigned char*) references this memory rather
	// than copying it (for zero-copy weight loading), so it must outlive
	// the Net -- kept here for exactly that reason, never read directly.
	godot::PackedByteArray retained_model_bytes;
	// NanoDet-Plus-m's own fixed input resolution -- see
	// nanodet_decoder.h/.cpp. Settable via set_net_input_size() for
	// benchmark_ms() to still probe other sizes for raw throughput
	// numbers, but detect() always uses this value since the decoder's
	// grid-prior math depends on it matching the loaded model exactly.
	int net_input_size = 416;

	// Resizes/letterboxes the given RGB8 frame to net_input_size x
	// net_input_size and returns it as an NCNN Mat in the network's expected
	// layout (CHW, normalized 0..1). Used by benchmark_ms(), which only
	// cares about raw throughput, not correct detections -- detect() uses
	// nanodet_preprocess() instead, which matches the actual loaded
	// model's expected mean/norm/channel order.
	ncnn::Mat preprocess(const godot::PackedByteArray &rgb_bytes, int width, int height, int net_input_size) const;
	ncnn::Mat nanodet_preprocess(const godot::PackedByteArray &rgb_bytes, int width, int height) const;

public:
	InferenceEngine();
	~InferenceEngine();

	// True if NCNN's Vulkan compute backend can see at least one GPU on this
	// device. Lazily creates the process-wide GPU instance on first call.
	static bool is_vulkan_available();

	// Selects the backend before loading -- "vulkan" or "auto" (currently
	// equivalent to "vulkan"; "auto" is the name Settings exposes since an
	// NPU option may follow later). Any other value (including "cpu")
	// fails rather than silently running on CPU. Must be called, and
	// succeed, before load_param/load_model.
	bool select_backend(const godot::String &backend);

	// Loads from in-memory buffers rather than filesystem paths -- the
	// param/bin files ship as regular Godot resources (loaded via
	// FileAccess on the GDScript side) rather than needing a real OS path,
	// which an exported project's embedded .pck doesn't give res:// files.
	// Mirrors NCNN's own load_param()/load_model() split (param first,
	// since it's needed to interpret the weight blob). `param_text` is the
	// plain-text .param content. `bin_bytes` is the raw .bin weight data,
	// retained for the lifetime of this engine since NCNN references
	// rather than copies it.
	bool load_param(const godot::String &param_text);
	bool load_model(const godot::PackedByteArray &bin_bytes);
	bool is_loaded() const;
	godot::String get_active_backend() const;

	// Must match the loaded model's actual fixed input resolution --
	// defaults to 416 (NanoDet-Plus-m_416's own size). detect()'s grid
	// priors are computed from this, so getting it wrong silently
	// produces garbage boxes rather than an error.
	void set_net_input_size(int size);

	// Explicitly releases the Net's Vulkan resources (and, if this is the
	// last live engine, the whole GPU instance) right now, in a
	// controlled order, rather than leaving it to whatever order C++
	// destructors happen to run in during process exit. Already called
	// from the destructor, so callers don't need to call this themselves
	// -- it exists as its own method mainly so the ordering is explicit
	// and testable. Good hygiene, but NOT what actually fixed this
	// project's real exit-time crash on Steam Frame hardware -- see
	// pin_self_against_unmap() in register_types.cpp for that story.
	void shutdown();

	// Runs `iterations` forward passes on the given frame (resized once,
	// outside the timed loop) and returns the average time per pass in
	// milliseconds. For bench-measuring real hardware throughput (see the
	// plan's performance table) before output decoding exists.
	double benchmark_ms(const godot::PackedByteArray &rgb_bytes, int width, int height, int net_input_size, int iterations);

	// `target_classes` is which of NanoDet's 80 COCO classes to actually
	// decode (see coco_labels.h for the index table -- 0=person, 2=car,
	// 7=truck, 5=bus, etc.); only these are checked per anchor, and NMS
	// runs separately within each class (see nanodet_decoder.h for why).
	// Passing more classes costs a little more CPU-side decode work per
	// detect() call, not extra GPU time -- the forward pass already
	// computes scores for all 80 regardless.
	//
	// Array[Dictionary], each with x/y/w/h as 0..1 fractions of the model
	// input frame (not pixel coordinates -- callers map that onto whatever
	// they're actually displaying, e.g. detection_overlay_content.gd onto
	// its SubViewport, without needing to know net_input_size),
	// "confidence", "class_id" (a target_classes value), "class_name"
	// (from coco_labels.h). "referee_excluded" is NOT set here (left for
	// the caller, e.g. detection_service.gd, via check_vest_color() below,
	// and only meaningful for class_id == 0/person -- this class has no
	// Settings dependency by design). Returns an empty array if no model
	// is loaded.
	godot::Array detect(const godot::PackedByteArray &rgb_bytes, int width, int height, float confidence_threshold, const godot::PackedInt32Array &target_classes);

	// GDScript-facing wrapper around referee_filter::is_vest_colored() --
	// see that file for the actual pixel logic/reasoning. bbox_x/y/w/h are
	// 0..1 fractions of the full rgb_bytes frame (same convention as
	// detect(), describing a person's *full-body* box); this narrows to
	// the torso third (vertically) itself before sampling, so callers
	// don't need to do that narrowing at every call site. hue is degrees
	// (0..360), sat/val are 0..1 -- matches Settings.detection_vest_hue_min
	// etc. Static since it needs no model/GPU state at all.
	static bool check_vest_color(
			const godot::PackedByteArray &rgb_bytes, int width, int height,
			float bbox_x, float bbox_y, float bbox_w, float bbox_h,
			float hue_min_deg, float hue_max_deg,
			float sat_min, float sat_max,
			float val_min, float val_max);
};

} // namespace fpvr

#endif // FPVR_INFERENCE_ENGINE_H
