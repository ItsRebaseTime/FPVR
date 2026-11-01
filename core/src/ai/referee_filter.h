#ifndef FPVR_REFEREE_FILTER_H
#define FPVR_REFEREE_FILTER_H

#include <cstdint>

namespace fpvr {
namespace referee_filter {

// Checks whether a person detection's torso region contains enough
// high-visibility-vest-colored pixels to flag it as a referee rather than
// a player -- an appearance cue (what they're wearing), deliberately not a
// pose/posture cue, since referees and players do all the same physical
// things on an airsoft field. See InferenceEngine::check_vest_color()'s
// doc comment (inference_engine.h) for the GDScript-facing wrapper this
// backs, and the plan's section B for why appearance beats pose here.
//
// `rgb` is a full RGB8 frame (3 bytes/pixel, row-major). `bbox_*` is the
// *torso* region in pixel space -- sampling just the torso third of a
// person's full bounding box rather than the whole box avoids false
// negatives/positives from skin tone, hair, weapon, or background pixels
// included in a looser full-body box; callers are expected to have
// already narrowed bbox_y/bbox_h to roughly the torso before calling this
// (InferenceEngine::check_vest_color() does that narrowing itself from a
// full-body box).
//
// hue is 0..360 degrees, sat/val are 0..1 (standard HSV). A pixel
// "matches" if its hue falls in [hue_min_deg, hue_max_deg] (wrapping
// across 360 if hue_min_deg > hue_max_deg, so a range like 350..10 covers
// red without needing two separate calls) and its saturation/value both
// fall in their given [min, max] ranges. Returns true if at least
// `match_fraction_threshold` (0..1) of sampled pixels match.
bool is_vest_colored(
		const uint8_t *rgb, int width, int height,
		int bbox_x, int bbox_y, int bbox_w, int bbox_h,
		float hue_min_deg, float hue_max_deg,
		float sat_min, float sat_max,
		float val_min, float val_max,
		float match_fraction_threshold = 0.3f);

} // namespace referee_filter
} // namespace fpvr

#endif // FPVR_REFEREE_FILTER_H
