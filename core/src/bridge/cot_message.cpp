#include "cot_message.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstdio>
#include <ctime>
#include <string>

using namespace godot;
using namespace fpvr;

void CotMessage::_bind_methods() {
	ClassDB::bind_static_method("CotMessage", D_METHOD("build_position_event", "uid", "callsign", "cot_type", "lat", "lon", "hae_m", "ce_m", "le_m", "stale_seconds", "extra_detail_xml"), &CotMessage::build_position_event);
	ClassDB::bind_static_method("CotMessage", D_METHOD("build_uav_event", "uid", "callsign", "lat", "lon", "hae_m", "speed_mps", "course_deg", "stale_seconds"), &CotMessage::build_uav_event);
}

namespace {

std::string iso8601_utc(time_t t) {
	struct tm tm_utc;
	gmtime_r(&t, &tm_utc);
	char buf[32];
	strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
	return std::string(buf);
}

std::string xml_escape(const String &s) {
	std::string out;
	std::string in = s.utf8().get_data();
	for (char c : in) {
		switch (c) {
			case '&': out += "&amp;"; break;
			case '<': out += "&lt;"; break;
			case '>': out += "&gt;"; break;
			case '"': out += "&quot;"; break;
			case '\'': out += "&apos;"; break;
			default: out += c; break;
		}
	}
	return out;
}

} // namespace

String CotMessage::build_position_event(
		const String &uid,
		const String &callsign,
		const String &cot_type,
		double lat,
		double lon,
		double hae_m,
		double ce_m,
		double le_m,
		double stale_seconds,
		const String &extra_detail_xml) {
	time_t now = time(nullptr);
	std::string time_str = iso8601_utc(now);
	std::string stale_str = iso8601_utc(now + static_cast<time_t>(stale_seconds));

	char buf[2048];
	snprintf(buf, sizeof(buf),
			"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
			"<event version=\"2.0\" uid=\"%s\" type=\"%s\" how=\"m-g\" "
			"time=\"%s\" start=\"%s\" stale=\"%s\">"
			"<point lat=\"%.7f\" lon=\"%.7f\" hae=\"%.1f\" ce=\"%.1f\" le=\"%.1f\"/>"
			"<detail><contact callsign=\"%s\"/>%s</detail>"
			"</event>",
			xml_escape(uid).c_str(), xml_escape(cot_type).c_str(),
			time_str.c_str(), time_str.c_str(), stale_str.c_str(),
			lat, lon, hae_m, ce_m, le_m,
			xml_escape(callsign).c_str(), extra_detail_xml.utf8().get_data());

	return String::utf8(buf);
}

String CotMessage::build_uav_event(
		const String &uid,
		const String &callsign,
		double lat,
		double lon,
		double hae_m,
		double speed_mps,
		double course_deg,
		double stale_seconds) {
	char track[256];
	snprintf(track, sizeof(track), "<track speed=\"%.2f\" course=\"%.1f\"/>", speed_mps, course_deg);

	// a-f-A-M-F-Q: friendly, air track, military, fixed/rotary-wing, UAV (quad).
	return build_position_event(uid, callsign, "a-f-A-M-F-Q", lat, lon, hae_m, 15.0, 15.0, stale_seconds, String::utf8(track));
}
