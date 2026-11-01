#ifndef FPVR_COT_MESSAGE_H
#define FPVR_COT_MESSAGE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace fpvr {

// Builds Cursor-on-Target (CoT) XML events for ATAK. Stock ATAK listens for
// these on its default SA multicast group with no plugin required, so this
// is the entire "integration surface" with ATAK: we just emit well-formed
// CoT, ATAK does the rest.
class CotMessage : public godot::RefCounted {
	GDCLASS(CotMessage, godot::RefCounted)

protected:
	static void _bind_methods();

public:
	// Builds a position event. `extra_detail_xml` lets callers splice extra
	// <detail> children (e.g. <track/>, <status battery=".../>) without this
	// class needing to know about every possible payload shape.
	static godot::String build_position_event(
			const godot::String &uid,
			const godot::String &callsign,
			const godot::String &cot_type,
			double lat,
			double lon,
			double hae_m,
			double ce_m,
			double le_m,
			double stale_seconds,
			const godot::String &extra_detail_xml);

	// Convenience builder for the UAV marker, embedding ground speed/course
	// as a <track/> element, which is the standard CoT convention.
	static godot::String build_uav_event(
			const godot::String &uid,
			const godot::String &callsign,
			double lat,
			double lon,
			double hae_m,
			double speed_mps,
			double course_deg,
			double stale_seconds);
};

} // namespace fpvr

#endif // FPVR_COT_MESSAGE_H
