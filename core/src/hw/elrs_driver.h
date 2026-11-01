#ifndef FPVR_ELRS_DRIVER_H
#define FPVR_ELRS_DRIVER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <cstdint>
#include <vector>

namespace fpvr {

// Parses CRSF frames coming from an ELRS receiver's UART-over-USB link and
// builds outgoing RC_CHANNELS_PACKED frames to send back to an ELRS
// transmitter module. See TBS Crossfire / ExpressLRS CRSF protocol spec.
class ElrsDriver : public godot::RefCounted {
	GDCLASS(ElrsDriver, godot::RefCounted)

protected:
	static void _bind_methods();

private:
	std::vector<uint8_t> rx_buffer;

	bool has_gps = false;
	double gps_latitude = 0.0;
	double gps_longitude = 0.0;
	double gps_altitude_m = 0.0;
	double gps_speed_mps = 0.0;
	double gps_heading_deg = 0.0;
	int gps_satellites = 0;

	bool has_battery = false;
	double battery_voltage_v = 0.0;
	double battery_current_a = 0.0;
	int battery_capacity_used_mah = 0;
	int battery_remaining_pct = 0;

	bool has_link_stats = false;
	int uplink_rssi_1 = 0;
	int uplink_rssi_2 = 0;
	int uplink_link_quality = 0;
	int uplink_snr = 0;
	int uplink_tx_power = 0;
	int downlink_rssi = 0;
	int downlink_link_quality = 0;
	int downlink_snr = 0;

	godot::String flight_mode;

	void handle_frame(const uint8_t *payload, int payload_len, uint8_t type);
	void try_parse_buffer();

public:
	static bool looks_like_crsf(const godot::PackedByteArray &sample);

	void feed(const godot::PackedByteArray &bytes);

	godot::Dictionary get_gps() const;
	godot::Dictionary get_battery() const;
	godot::Dictionary get_link_stats() const;
	godot::String get_flight_mode() const;

	// channels: Array of 16 ints, each 0..1984 (CRSF RC range, 172..1811 is
	// the usable -100%..100% band; 0/992/1984-ish correspond to stick
	// extremes, see ExpressLRS docs). Returns a ready-to-write CRSF frame.
	static godot::PackedByteArray pack_channels_frame(const godot::Array &channels);
};

} // namespace fpvr

#endif // FPVR_ELRS_DRIVER_H
