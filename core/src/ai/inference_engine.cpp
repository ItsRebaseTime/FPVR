#include "inference_engine.h"

#include "coco_labels.h"
#include "nanodet_decoder.h"
#include "referee_filter.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <gpu.h>

#include <vector>

using namespace godot;
using namespace fpvr;

namespace {

bool gpu_instance_created = false;
int live_engine_count = 0;

} // namespace

void InferenceEngine::_bind_methods() {
	ClassDB::bind_static_method("InferenceEngine", D_METHOD("is_vulkan_available"), &InferenceEngine::is_vulkan_available);
	ClassDB::bind_method(D_METHOD("select_backend", "backend"), &InferenceEngine::select_backend);
	ClassDB::bind_method(D_METHOD("load_param", "param_text"), &InferenceEngine::load_param);
	ClassDB::bind_method(D_METHOD("load_model", "bin_bytes"), &InferenceEngine::load_model);
	ClassDB::bind_method(D_METHOD("is_loaded"), &InferenceEngine::is_loaded);
	ClassDB::bind_method(D_METHOD("get_active_backend"), &InferenceEngine::get_active_backend);
	ClassDB::bind_method(D_METHOD("set_net_input_size", "size"), &InferenceEngine::set_net_input_size);
	ClassDB::bind_method(D_METHOD("shutdown"), &InferenceEngine::shutdown);
	ClassDB::bind_method(D_METHOD("benchmark_ms", "rgb_bytes", "width", "height", "net_input_size", "iterations"), &InferenceEngine::benchmark_ms);
	ClassDB::bind_method(D_METHOD("detect", "rgb_bytes", "width", "height", "confidence_threshold", "target_classes"), &InferenceEngine::detect);
	ClassDB::bind_static_method("InferenceEngine", D_METHOD("check_vest_color", "rgb_bytes", "width", "height", "bbox_x", "bbox_y", "bbox_w", "bbox_h", "hue_min_deg", "hue_max_deg", "sat_min", "sat_max", "val_min", "val_max"), &InferenceEngine::check_vest_color);
}

InferenceEngine::InferenceEngine() {
	live_engine_count++;
}

InferenceEngine::~InferenceEngine() {
	shutdown();
}

void InferenceEngine::shutdown() {
	if (!loaded) {
		return;
	}
	loaded = false;
	live_engine_count--;

	// Explicit, ordered cleanup rather than leaving it to whatever order
	// C++ destructors happen to run in during process exit -- good
	// hygiene on its own, but NOTE: this alone did not fix the real
	// exit-time crash this project hit on Steam Frame hardware (confirmed
	// by testing: the crash reproduced 100% of the time even with this
	// exact ordering already in place). The actual fix was
	// pin_self_against_unmap() in register_types.cpp -- see that
	// function's doc comment for the full story (a dangling
	// atexit()-registered callback into code this library's own
	// premature dlclose() had unmapped, not a GPU-resource-ordering bug
	// at all). Kept here anyway: it's still correct for the (currently
	// hypothetical) case where more than one InferenceEngine coexists.
	net.clear();

	if (live_engine_count <= 0) {
		ncnn::destroy_gpu_instance();
	}
}

bool InferenceEngine::is_vulkan_available() {
	if (!gpu_instance_created) {
		if (ncnn::create_gpu_instance() != 0) {
			return false;
		}
		gpu_instance_created = true;
	}
	return ncnn::get_gpu_count() > 0;
}

bool InferenceEngine::select_backend(const String &backend) {
	loaded = false;
	active_backend = "none";

	// No CPU fallback by design -- see the class doc comment. "auto" is
	// accepted today as a synonym for "vulkan" since that's the only
	// backend that exists yet; it's a distinct Settings-facing name so an
	// NPU option can be added later without renaming this one.
	if (backend != "vulkan" && backend != "auto") {
		return false;
	}
	if (!is_vulkan_available()) {
		return false;
	}

	net.opt.use_vulkan_compute = true;
	net.set_vulkan_device(0);
	active_backend = "vulkan (gpu)";
	return true;
}

bool InferenceEngine::load_param(const String &param_text) {
	return net.load_param_mem(param_text.utf8().get_data()) == 0;
}

bool InferenceEngine::load_model(const PackedByteArray &bin_bytes) {
	// Retained for the Net's lifetime: load_model(const unsigned char*)
	// references this buffer rather than copying it.
	retained_model_bytes = bin_bytes;
	if (net.load_model(retained_model_bytes.ptr()) == 0) {
		return false;
	}
	loaded = true;
	return true;
}

bool InferenceEngine::is_loaded() const {
	return loaded;
}

String InferenceEngine::get_active_backend() const {
	return active_backend;
}

void InferenceEngine::set_net_input_size(int size) {
	net_input_size = size;
}

ncnn::Mat InferenceEngine::preprocess(const PackedByteArray &rgb_bytes, int width, int height, int net_input_size) const {
	ncnn::Mat in = ncnn::Mat::from_pixels_resize(rgb_bytes.ptr(), ncnn::Mat::PIXEL_RGB, width, height, net_input_size, net_input_size);
	const float norm_vals[3] = { 1 / 255.f, 1 / 255.f, 1 / 255.f };
	in.substract_mean_normalize(nullptr, norm_vals);
	return in;
}

// NanoDet-Plus's own expected preprocessing (BGR channel order, specific
// per-channel mean/norm) -- ported from nanodet.cpp's preprocess(), see
// nanodet_decoder.h for why these particular values. Unlike preprocess()
// above (generic 0..1 normalization for benchmark_ms()), this must match
// exactly what the model was trained/exported with.
ncnn::Mat InferenceEngine::nanodet_preprocess(const PackedByteArray &rgb_bytes, int width, int height) const {
	ncnn::Mat in = ncnn::Mat::from_pixels_resize(rgb_bytes.ptr(), ncnn::Mat::PIXEL_RGB2BGR, width, height, net_input_size, net_input_size);
	const float mean_vals[3] = { 103.53f, 116.28f, 123.675f };
	const float norm_vals[3] = { 0.017429f, 0.017507f, 0.017125f };
	in.substract_mean_normalize(mean_vals, norm_vals);
	return in;
}

double InferenceEngine::benchmark_ms(const PackedByteArray &rgb_bytes, int width, int height, int net_input_size, int iterations) {
	if (!loaded || iterations <= 0) {
		return -1.0;
	}

	ncnn::Mat in = preprocess(rgb_bytes, width, height, net_input_size);

	// One untimed warm-up pass: first-ever Vulkan dispatch on a pipeline
	// pays for shader/descriptor-set setup that every later call skips, and
	// that one-time cost would otherwise dominate a short benchmark.
	{
		ncnn::Extractor ex = net.create_extractor();
		ex.input(net.input_names()[0], in);
		ncnn::Mat out;
		ex.extract(net.output_names()[0], out);
	}

	uint64_t start_usec = Time::get_singleton()->get_ticks_usec();
	for (int i = 0; i < iterations; i++) {
		ncnn::Extractor ex = net.create_extractor();
		ex.input(net.input_names()[0], in);
		ncnn::Mat out;
		ex.extract(net.output_names()[0], out);
	}
	uint64_t elapsed_usec = Time::get_singleton()->get_ticks_usec() - start_usec;

	return (double)elapsed_usec / 1000.0 / (double)iterations;
}

bool InferenceEngine::check_vest_color(
		const PackedByteArray &rgb_bytes, int width, int height,
		float bbox_x, float bbox_y, float bbox_w, float bbox_h,
		float hue_min_deg, float hue_max_deg,
		float sat_min, float sat_max,
		float val_min, float val_max) {
	// Torso third of the full-body box, vertically -- see referee_filter.h's
	// doc comment on why (skin/hair/weapon/background pixels in a looser
	// full-body box would otherwise dilute the vest-color signal).
	float torso_y = bbox_y + bbox_h / 3.0f;
	float torso_h = bbox_h / 3.0f;

	int px_x = (int)(bbox_x * width);
	int px_y = (int)(torso_y * height);
	int px_w = (int)(bbox_w * width);
	int px_h = (int)(torso_h * height);

	return referee_filter::is_vest_colored(
			rgb_bytes.ptr(), width, height,
			px_x, px_y, px_w, px_h,
			hue_min_deg, hue_max_deg, sat_min, sat_max, val_min, val_max);
}

Array InferenceEngine::detect(const PackedByteArray &rgb_bytes, int width, int height, float confidence_threshold, const PackedInt32Array &target_classes) {
	Array results;
	if (!loaded || target_classes.is_empty()) {
		return results;
	}

	ncnn::Mat in = nanodet_preprocess(rgb_bytes, width, height);

	ncnn::Extractor ex = net.create_extractor();
	ex.input(net.input_names()[0], in);
	ncnn::Mat out;
	ex.extract(net.output_names()[0], out);

	std::vector<int> classes(target_classes.ptr(), target_classes.ptr() + target_classes.size());
	const float NMS_THRESHOLD = 0.5f;
	std::vector<nanodet_decoder::Detection> detections = nanodet_decoder::decode(out, net_input_size, classes, confidence_threshold, NMS_THRESHOLD);

	for (const nanodet_decoder::Detection &det : detections) {
		Dictionary d;
		d["x"] = det.x;
		d["y"] = det.y;
		d["w"] = det.w;
		d["h"] = det.h;
		d["confidence"] = det.confidence;
		d["class_id"] = det.class_id;
		d["class_name"] = coco_label_name(det.class_id);
		results.push_back(d);
	}

	return results;
}
