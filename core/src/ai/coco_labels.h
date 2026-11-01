#ifndef FPVR_COCO_LABELS_H
#define FPVR_COCO_LABELS_H

namespace fpvr {

// The 80 class names NanoDet-Plus-m_416 was trained on (COCO), in the
// model's own output order -- same list nanodet.h's own demo ships,
// index-for-index. See nanodet_decoder.h for which of these this
// project actually decodes.
inline const char *coco_label_name(int class_id) {
	static const char *labels[80] = {
		"person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
		"fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
		"elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
		"skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard",
		"tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
		"sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
		"potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone",
		"microwave", "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase", "scissors", "teddy bear",
		"hair drier", "toothbrush"
	};
	if (class_id < 0 || class_id >= 80) {
		return "unknown";
	}
	return labels[class_id];
}

} // namespace fpvr

#endif // FPVR_COCO_LABELS_H
