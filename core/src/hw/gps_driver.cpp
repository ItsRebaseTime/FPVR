#include "gps_driver.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>
#include <cstdlib>
#include <vector>

using namespace godot;
using namespace fpvr;

void GpsDriver::_bind_methods() {
	ClassDB::bind_static_method("GpsDriver", D_METHOD("looks_like_nmea", "sample"), &GpsDriver::looks_like_nmea);
	ClassDB::bind_static_method("GpsDriver", D_METHOD("looks_like_ubx", "sample"), &GpsDriver::looks_like_ubx);
	ClassDB::bind_method(D_METHOD("feed", "bytes"), &GpsDriver::feed);
	ClassDB::bind_method(D_METHOD("get_fix"), &GpsDriver::get_fix);
}

bool GpsDriver::looks_like_nmea(const PackedByteArray &sample) {
	for (int i = 0; i < sample.size(); i++) {
		if (sample[i] == '$') {
			return true;
		}
	}
	return false;
}

bool GpsDriver::looks_like_ubx(const PackedByteArray &sample) {
	for (int i = 0; i + 1 < sample.size(); i++) {
		if (static_cast<uint8_t>(sample[i]) == 0xB5 && static_cast<uint8_t>(sample[i + 1]) == 0x62) {
			return true;
		}
	}
	return false;
}

namespace {

std::vector<std::string> split_fields(const std::string &sentence) {
	std::vector<std::string> fields;
	std::string cur;
	for (char c : sentence) {
		if (c == ',' || c == '*') {
			fields.push_back(cur);
			cur.clear();
		} else {
			cur += c;
		}
	}
	fields.push_back(cur);
	return fields;
}

bool checksum_ok(const std::string &sentence) {
	size_t star = sentence.find('*');
	if (star == std::string::npos || star + 2 >= sentence.size()) {
		return false;
	}
	uint8_t calc = 0;
	for (size_t i = 1; i < star; i++) { // skip leading '$'
		calc ^= static_cast<uint8_t>(sentence[i]);
	}
	uint8_t given = static_cast<uint8_t>(strtol(sentence.substr(star + 1, 2).c_str(), nullptr, 16));
	return calc == given;
}

// NMEA lat/lon are DDMM.MMMM / DDDMM.MMMM (degrees + minutes concatenated).
double dm_to_degrees(const std::string &field, int degree_digits) {
	if (field.empty()) {
		return 0.0;
	}
	double raw = atof(field.c_str());
	double degrees = floor(raw / 100.0);
	// recompute using the known digit split to avoid ambiguity for lon (3 degree digits)
	(void)degree_digits;
	double minutes = raw - degrees * 100.0;
	return degrees + minutes / 60.0;
}

} // namespace

void GpsDriver::parse_gga(const std::string &sentence) {
	std::vector<std::string> f = split_fields(sentence);
	// $xxGGA,time,lat,N/S,lon,E/W,quality,numSV,HDOP,alt,M,geoidSep,M,dgpsAge,dgpsId*cs
	if (f.size() < 10) {
		return;
	}
	double lat = dm_to_degrees(f[2], 2);
	if (!f[3].empty() && f[3][0] == 'S') {
		lat = -lat;
	}
	double lon = dm_to_degrees(f[4], 3);
	if (!f[5].empty() && f[5][0] == 'W') {
		lon = -lon;
	}
	fix_quality = f[6].empty() ? 0 : atoi(f[6].c_str());
	satellites = f[7].empty() ? 0 : atoi(f[7].c_str());
	hdop = f[8].empty() ? 99.0 : atof(f[8].c_str());
	altitude_m = f[9].empty() ? 0.0 : atof(f[9].c_str());

	if (fix_quality > 0) {
		latitude = lat;
		longitude = lon;
		has_fix_latlon = true;
	}
}

void GpsDriver::parse_rmc(const std::string &sentence) {
	std::vector<std::string> f = split_fields(sentence);
	// $xxRMC,time,status,lat,N/S,lon,E/W,speedKnots,course,date,magVar,magVarDir,mode*cs
	if (f.size() < 9) {
		return;
	}
	bool active = !f[2].empty() && f[2][0] == 'A';
	double lat = dm_to_degrees(f[3], 2);
	if (!f[4].empty() && f[4][0] == 'S') {
		lat = -lat;
	}
	double lon = dm_to_degrees(f[5], 3);
	if (!f[6].empty() && f[6][0] == 'W') {
		lon = -lon;
	}
	double speed_knots = f[7].empty() ? 0.0 : atof(f[7].c_str());
	double course = f[8].empty() ? 0.0 : atof(f[8].c_str());

	ground_speed_mps = speed_knots * 0.514444;
	course_deg = course;

	if (active) {
		latitude = lat;
		longitude = lon;
		has_fix_latlon = true;
	}
}

void GpsDriver::parse_sentence(const std::string &sentence) {
	if (sentence.size() < 6 || sentence[0] != '$') {
		return;
	}
	if (!checksum_ok(sentence)) {
		return;
	}
	// sentence[1..2] is talker id (GP/GN/GL/GA...), [3..5] is sentence type
	std::string type = sentence.substr(3, 3);
	if (type == "GGA") {
		parse_gga(sentence);
	} else if (type == "RMC") {
		parse_rmc(sentence);
	}
}

void GpsDriver::feed(const PackedByteArray &bytes) {
	for (int i = 0; i < bytes.size(); i++) {
		char c = static_cast<char>(bytes[i]);
		if (c == '\n' || c == '\r') {
			if (!line_buffer.empty()) {
				parse_sentence(line_buffer);
				line_buffer.clear();
			}
		} else {
			line_buffer += c;
			if (line_buffer.size() > 256) {
				line_buffer.clear(); // malformed/garbage, resync on next '$'
			}
		}
	}
}

Dictionary GpsDriver::get_fix() const {
	Dictionary d;
	d["has_fix"] = has_fix_latlon && fix_quality > 0;
	d["fix_quality"] = fix_quality;
	d["latitude"] = latitude;
	d["longitude"] = longitude;
	d["altitude_m"] = altitude_m;
	d["hdop"] = hdop;
	// Rough-but-standard rule of thumb (HDOP * ~5m UERE for consumer GNSS)
	// so this is directly comparable, in meters, to a platform location
	// API's reported accuracy (e.g. Android Location.getAccuracy()) --
	// see HardwareHub's best-source merge on Android.
	d["accuracy_m"] = hdop * 5.0;
	d["satellites"] = satellites;
	d["ground_speed_mps"] = ground_speed_mps;
	d["course_deg"] = course_deg;
	return d;
}
