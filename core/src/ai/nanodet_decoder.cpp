#include "nanodet_decoder.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace {

using fpvr::nanodet_decoder::Detection;

const int NUM_CLASSES = 80; // COCO
const int REG_MAX = 7; // 8 DFL bins per side (0..reg_max)
const int STRIDES[] = { 8, 16, 32, 64 };
const int NUM_STRIDES = 4;

struct CenterPrior {
	int x, y, stride;
};

std::vector<CenterPrior> generate_grid_center_priors(int input_size) {
	std::vector<CenterPrior> priors;
	for (int s = 0; s < NUM_STRIDES; s++) {
		int stride = STRIDES[s];
		int feat = (input_size + stride - 1) / stride; // ceil
		for (int y = 0; y < feat; y++) {
			for (int x = 0; x < feat; x++) {
				priors.push_back({ x, y, stride });
			}
		}
	}
	return priors;
}

// Same approximate-exp trick nanodet.cpp itself uses -- exact precision
// doesn't matter here, only the softmax it feeds into does, and that's
// scale-invariant to this approximation's error.
float fast_exp(float x) {
	union {
		uint32_t i;
		float f;
	} v{};
	v.i = (uint32_t)((1 << 23) * (1.4426950409f * x + 126.93490512f));
	return v.f;
}

void softmax(const float *src, float *dst, int length) {
	float max_v = src[0];
	for (int i = 1; i < length; i++) {
		max_v = std::max(max_v, src[i]);
	}
	float sum = 0.0f;
	for (int i = 0; i < length; i++) {
		dst[i] = fast_exp(src[i] - max_v);
		sum += dst[i];
	}
	for (int i = 0; i < length; i++) {
		dst[i] /= sum;
	}
}

// Distribution-Focal-Loss decode: `dfl` points at 4*(REG_MAX+1) raw
// logits (left/top/right/bottom, each REG_MAX+1 bins); each group's
// softmax-weighted bin index, times stride, is that side's pixel
// distance from the anchor's center point.
void decode_distances(const float *dfl, int stride, float dis[4]) {
	float bins[REG_MAX + 1];
	for (int side = 0; side < 4; side++) {
		softmax(dfl + side * (REG_MAX + 1), bins, REG_MAX + 1);
		float d = 0.0f;
		for (int bin = 0; bin <= REG_MAX; bin++) {
			d += bin * bins[bin];
		}
		dis[side] = d * stride;
	}
}

// Only compares boxes within the same class -- a car and a person
// overlapping in frame shouldn't suppress each other.
void nms_per_class(std::vector<Detection> &boxes, float nms_threshold) {
	std::sort(boxes.begin(), boxes.end(), [](const Detection &a, const Detection &b) { return a.confidence > b.confidence; });
	std::vector<float> areas(boxes.size());
	for (size_t i = 0; i < boxes.size(); i++) {
		areas[i] = std::max(0.0f, boxes[i].w) * std::max(0.0f, boxes[i].h);
	}
	for (size_t i = 0; i < boxes.size(); i++) {
		for (size_t j = i + 1; j < boxes.size();) {
			if (boxes[i].class_id != boxes[j].class_id) {
				j++;
				continue;
			}
			float xx1 = std::max(boxes[i].x, boxes[j].x);
			float yy1 = std::max(boxes[i].y, boxes[j].y);
			float xx2 = std::min(boxes[i].x + boxes[i].w, boxes[j].x + boxes[j].w);
			float yy2 = std::min(boxes[i].y + boxes[i].h, boxes[j].y + boxes[j].h);
			float w = std::max(0.0f, xx2 - xx1);
			float h = std::max(0.0f, yy2 - yy1);
			float inter = w * h;
			float ovr = inter / (areas[i] + areas[j] - inter);
			if (ovr >= nms_threshold) {
				boxes.erase(boxes.begin() + j);
				areas.erase(areas.begin() + j);
			} else {
				j++;
			}
		}
	}
}

} // namespace

namespace fpvr {
namespace nanodet_decoder {

std::vector<Detection> decode(const ncnn::Mat &output, int input_size, const std::vector<int> &target_classes, float confidence_threshold, float nms_threshold) {
	std::vector<CenterPrior> priors = generate_grid_center_priors(input_size);
	std::vector<Detection> candidates;

	int num_points = std::min((int)priors.size(), output.h);
	for (int i = 0; i < num_points; i++) {
		const float *row = output.row(i);
		const CenterPrior &prior = priors[i];

		// Box distances only depend on the anchor, not the class, so
		// they're decoded at most once per anchor even if multiple
		// target classes match here.
		bool box_decoded = false;
		float x1 = 0, y1 = 0, x2 = 0, y2 = 0;

		// Class scores are already sigmoid-activated inside the model
		// graph itself (see the .param dump this was ported from) -- no
		// activation needed here. Checking each target class's score
		// directly, rather than only decoding whichever class has the
		// highest score at this anchor, catches detections an
		// overlapping higher-scoring class at the same anchor would
		// otherwise hide.
		for (int class_id : target_classes) {
			float score = row[class_id];
			if (score <= confidence_threshold) {
				continue;
			}

			if (!box_decoded) {
				float ct_x = prior.x * prior.stride;
				float ct_y = prior.y * prior.stride;
				float dis[4];
				decode_distances(row + NUM_CLASSES, prior.stride, dis);
				x1 = std::max(ct_x - dis[0], 0.0f);
				y1 = std::max(ct_y - dis[1], 0.0f);
				x2 = std::min(ct_x + dis[2], (float)input_size);
				y2 = std::min(ct_y + dis[3], (float)input_size);
				box_decoded = true;
			}

			Detection det;
			det.x = x1 / input_size;
			det.y = y1 / input_size;
			det.w = (x2 - x1) / input_size;
			det.h = (y2 - y1) / input_size;
			det.confidence = score;
			det.class_id = class_id;
			candidates.push_back(det);
		}
	}

	nms_per_class(candidates, nms_threshold);
	return candidates;
}

} // namespace nanodet_decoder
} // namespace fpvr
