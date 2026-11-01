#ifndef FPVR_GPS_DRIVER_H
#define FPVR_GPS_DRIVER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <string>

namespace fpvr {

// Parses NMEA 0183 sentences (GGA/RMC) coming off a USB GPS receiver.
// UBX binary framing (0xB5 0x62 sync) is recognized by looks_like_ubx() for
// device classification but full UBX message decoding is not implemented
// yet -- NMEA already carries everything this app needs (fix, lat/lon,
// altitude, HDOP, satellite count, ground speed/course).
class GpsDriver : public godot::RefCounted {
	GDCLASS(GpsDriver, godot::RefCounted)

protected:
	static void _bind_methods();

private:
	std::string line_buffer;

	bool has_fix_latlon = false;
	double latitude = 0.0;
	double longitude = 0.0;
	double altitude_m = 0.0;
	double hdop = 99.0;
	int fix_quality = 0; // 0 = no fix, 1 = GPS fix, 2 = DGPS fix, ...
	int satellites = 0;
	double ground_speed_mps = 0.0;
	double course_deg = 0.0;

	void parse_sentence(const std::string &sentence);
	void parse_gga(const std::string &sentence);
	void parse_rmc(const std::string &sentence);

public:
	static bool looks_like_nmea(const godot::PackedByteArray &sample);
	static bool looks_like_ubx(const godot::PackedByteArray &sample);

	void feed(const godot::PackedByteArray &bytes);
	godot::Dictionary get_fix() const;
};

} // namespace fpvr

#endif // FPVR_GPS_DRIVER_H
