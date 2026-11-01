#ifndef FPVR_NANODET_DECODER_H
#define FPVR_NANODET_DECODER_H

#include <mat.h>

#include <vector>

namespace fpvr {
namespace nanodet_decoder {

// Decodes a NanoDet-Plus raw forward-pass output into detections for a
// caller-chosen subset of its 80 COCO classes (person, car, truck, ...).
//
// The model: NanoDet-Plus-m, 416x416 input, COCO 80-class, officially
// published by its author (RangiLyu) under Apache-2.0 at
// https://github.com/RangiLyu/nanodet, pre-converted to NCNN format in
// that repo's v1.0.0-alpha-1 release ("nanodet-plus-m_416_ncnn.zip") --
// chosen specifically over Ultralytics' YOLOv8 for this permissive
// license: YOLOv8 is AGPL-3.0, which would obligate this project's own
// source to go AGPL too once distributed to teammates (see the plan's
// discussion). The decode math below is a close port of that repo's own
// demo_ncnn/nanodet.cpp (same Apache-2.0 license as the model), adapted
// to: (a) only decode `target_classes` rather than all 80 -- this
// project only cares about a handful of COCO classes, and checking each
// anchor's score for exactly those classes directly, independent of
// which class would otherwise "win" at that anchor, actually catches
// more of them than the original multi-class argmax would (e.g. a
// person box at an anchor where "backpack" scores marginally higher
// isn't silently dropped); (b) NMS runs per class rather than across all
// classes at once, so a car and a person that happen to overlap don't
// suppress each other; (c) returns boxes as 0..1 fractions of the input
// frame rather than pixel coordinates, matching
// InferenceEngine::detect()'s documented contract.
//
// Model-specific constants (REG_MAX, STRIDES) are hardcoded here rather
// than parameterized, since this decoder is specific to this one
// model's head architecture -- swapping in a different model means
// swapping in a different decoder, not reconfiguring this one.
// coco_labels.h has the full class name table target_classes indexes into.
struct Detection {
	float x, y, w, h; // 0..1 fractions of the input frame
	float confidence;
	int class_id; // COCO class index, see coco_labels.h
};

std::vector<Detection> decode(const ncnn::Mat &output, int input_size, const std::vector<int> &target_classes, float confidence_threshold, float nms_threshold);

} // namespace nanodet_decoder
} // namespace fpvr

#endif // FPVR_NANODET_DECODER_H
