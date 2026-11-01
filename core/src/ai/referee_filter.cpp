#include "referee_filter.h"

#include <algorithm>
#include <cmath>

namespace {

// Standard RGB(0..255) -> HSV(hue 0..360, sat/val 0..1) conversion.
void rgb_to_hsv(uint8_t r8, uint8_t g8, uint8_t b8, float &h, float &s, float &v) {
	float r = r8 / 255.0f, g = g8 / 255.0f, b = b8 / 255.0f;
	float max_c = std::max({ r, g, b });
	float min_c = std::min({ r, g, b });
	float delta = max_c - min_c;

	v = max_c;
	s = (max_c <= 0.0f) ? 0.0f : (delta / max_c);

	if (delta <= 0.0f) {
		h = 0.0f;
	} else if (max_c == r) {
		h = 60.0f * std::fmod((g - b) / delta, 6.0f);
	} else if (max_c == g) {
		h = 60.0f * (((b - r) / delta) + 2.0f);
	} else {
		h = 60.0f * (((r - g) / delta) + 4.0f);
	}
	if (h < 0.0f) {
		h += 360.0f;
	}
}

bool hue_in_range(float h, float hue_min_deg, float hue_max_deg) {
	if (hue_min_deg <= hue_max_deg) {
		return h >= hue_min_deg && h <= hue_max_deg;
	}
	// Wraps across 0/360 (e.g. a red range like 350..10).
	return h >= hue_min_deg || h <= hue_max_deg;
}

} // namespace

namespace fpvr {
namespace referee_filter {

bool is_vest_colored(
		const uint8_t *rgb, int width, int height,
		int bbox_x, int bbox_y, int bbox_w, int bbox_h,
		float hue_min_deg, float hue_max_deg,
		float sat_min, float sat_max,
		float val_min, float val_max,
		float match_fraction_threshold) {
	int x0 = std::max(0, bbox_x);
	int y0 = std::max(0, bbox_y);
	int x1 = std::min(width, bbox_x + bbox_w);
	int y1 = std::min(height, bbox_y + bbox_h);
	if (x1 <= x0 || y1 <= y0) {
		return false;
	}

	int total = 0;
	int matched = 0;
	// Every pixel in a torso-sized region is still thousands of samples;
	// a stride keeps this cheap without needing a real subsample/area
	// average, since neighboring pixels of clothing fabric are highly
	// correlated anyway.
	const int stride = 2;
	for (int y = y0; y < y1; y += stride) {
		const uint8_t *row = rgb + (size_t)y * width * 3;
		for (int x = x0; x < x1; x += stride) {
			const uint8_t *px = row + (size_t)x * 3;
			float h, s, v;
			rgb_to_hsv(px[0], px[1], px[2], h, s, v);
			total++;
			if (hue_in_range(h, hue_min_deg, hue_max_deg) && s >= sat_min && s <= sat_max && v >= val_min && v <= val_max) {
				matched++;
			}
		}
	}

	if (total == 0) {
		return false;
	}
	return (float)matched / (float)total >= match_fraction_threshold;
}

} // namespace referee_filter
} // namespace fpvr
