#include "elrs_driver.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstring>

using namespace godot;
using namespace fpvr;

namespace {

constexpr uint8_t CRSF_SYNC_BYTE = 0xC8;
constexpr uint8_t CRSF_FRAMETYPE_GPS = 0x02;
constexpr uint8_t CRSF_FRAMETYPE_BATTERY_SENSOR = 0x08;
constexpr uint8_t CRSF_FRAMETYPE_LINK_STATISTICS = 0x14;
constexpr uint8_t CRSF_FRAMETYPE_RC_CHANNELS_PACKED = 0x16;
constexpr uint8_t CRSF_FRAMETYPE_ATTITUDE = 0x1E;
constexpr uint8_t CRSF_FRAMETYPE_FLIGHT_MODE = 0x21;

uint8_t crc8_dvb_s2(uint8_t crc, uint8_t a) {
	crc ^= a;
	for (int i = 0; i < 8; i++) {
		crc = (crc & 0x80) ? static_cast<uint8_t>((crc << 1) ^ 0xD5) : static_cast<uint8_t>(crc << 1);
	}
	return crc;
}

uint16_t read_u16_be(const uint8_t *p) {
	return static_cast<uint16_t>((p[0] << 8) | p[1]);
}

int32_t read_i32_be(const uint8_t *p) {
	uint32_t v = (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
			(static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
	return static_cast<int32_t>(v);
}

uint32_t read_u24_be(const uint8_t *p) {
	return (static_cast<uint32_t>(p[0]) << 16) | (static_cast<uint32_t>(p[1]) << 8) | static_cast<uint32_t>(p[2]);
}

} // namespace

void ElrsDriver::_bind_methods() {
	ClassDB::bind_static_method("ElrsDriver", D_METHOD("looks_like_crsf", "sample"), &ElrsDriver::looks_like_crsf);
	ClassDB::bind_method(D_METHOD("feed", "bytes"), &ElrsDriver::feed);
	ClassDB::bind_method(D_METHOD("get_gps"), &ElrsDriver::get_gps);
	ClassDB::bind_method(D_METHOD("get_battery"), &ElrsDriver::get_battery);
	ClassDB::bind_method(D_METHOD("get_link_stats"), &ElrsDriver::get_link_stats);
	ClassDB::bind_method(D_METHOD("get_flight_mode"), &ElrsDriver::get_flight_mode);
	ClassDB::bind_static_method("ElrsDriver", D_METHOD("pack_channels_frame", "channels"), &ElrsDriver::pack_channels_frame);
}

bool ElrsDriver::looks_like_crsf(const PackedByteArray &sample) {
	for (int i = 0; i + 3 < sample.size(); i++) {
		uint8_t sync = static_cast<uint8_t>(sample[i]);
		if (sync < 0xC0) {
			continue;
		}
		uint8_t len = static_cast<uint8_t>(sample[i + 1]);
		if (len < 2 || len > 62 || i + 2 + len > sample.size()) {
			continue;
		}
		uint8_t crc_calc = 0;
		for (int j = i + 2; j < i + 2 + len - 1; j++) {
			crc_calc = crc8_dvb_s2(crc_calc, static_cast<uint8_t>(sample[j]));
		}
		if (crc_calc == static_cast<uint8_t>(sample[i + 2 + len - 1])) {
			return true;
		}
	}
	return false;
}

void ElrsDriver::handle_frame(const uint8_t *payload, int payload_len, uint8_t type) {
	switch (type) {
		case CRSF_FRAMETYPE_GPS: {
			if (payload_len < 15) {
				break;
			}
			gps_latitude = read_i32_be(payload) / 1e7;
			gps_longitude = read_i32_be(payload + 4) / 1e7;
			gps_speed_mps = read_u16_be(payload + 8) / 10.0 * (1000.0 / 3600.0); // km/h*10 -> m/s
			gps_heading_deg = read_u16_be(payload + 10) / 100.0;
			gps_altitude_m = static_cast<double>(read_u16_be(payload + 12)) - 1000.0;
			gps_satellites = payload[14];
			has_gps = true;
			break;
		}
		case CRSF_FRAMETYPE_BATTERY_SENSOR: {
			if (payload_len < 8) {
				break;
			}
			battery_voltage_v = read_u16_be(payload) / 10.0;
			battery_current_a = read_u16_be(payload + 2) / 10.0;
			battery_capacity_used_mah = static_cast<int>(read_u24_be(payload + 4));
			battery_remaining_pct = payload[7];
			has_battery = true;
			break;
		}
		case CRSF_FRAMETYPE_LINK_STATISTICS: {
			if (payload_len < 10) {
				break;
			}
			uplink_rssi_1 = payload[0];
			uplink_rssi_2 = payload[1];
			uplink_link_quality = payload[2];
			uplink_snr = static_cast<int8_t>(payload[3]);
			uplink_tx_power = payload[6];
			downlink_rssi = payload[7];
			downlink_link_quality = payload[8];
			downlink_snr = static_cast<int8_t>(payload[9]);
			has_link_stats = true;
			break;
		}
		case CRSF_FRAMETYPE_FLIGHT_MODE: {
			flight_mode = String::utf8(reinterpret_cast<const char *>(payload), payload_len);
			break;
		}
		case CRSF_FRAMETYPE_ATTITUDE:
		default:
			break;
	}
}

void ElrsDriver::try_parse_buffer() {
	while (true) {
		if (rx_buffer.size() < 4) {
			return;
		}
		if (rx_buffer[0] < 0xC0) {
			rx_buffer.erase(rx_buffer.begin());
			continue;
		}
		uint8_t len = rx_buffer[1];
		if (len < 2 || len > 62) {
			rx_buffer.erase(rx_buffer.begin());
			continue;
		}
		size_t total = static_cast<size_t>(2) + len;
		if (rx_buffer.size() < total) {
			return; // wait for more bytes
		}
		uint8_t crc_calc = 0;
		for (size_t j = 2; j < total - 1; j++) {
			crc_calc = crc8_dvb_s2(crc_calc, rx_buffer[j]);
		}
		if (crc_calc != rx_buffer[total - 1]) {
			rx_buffer.erase(rx_buffer.begin());
			continue;
		}
		uint8_t type = rx_buffer[2];
		int payload_len = static_cast<int>(len) - 2; // minus type byte, minus crc byte
		handle_frame(rx_buffer.data() + 3, payload_len, type);
		rx_buffer.erase(rx_buffer.begin(), rx_buffer.begin() + total);
	}
}

void ElrsDriver::feed(const PackedByteArray &bytes) {
	for (int i = 0; i < bytes.size(); i++) {
		rx_buffer.push_back(static_cast<uint8_t>(bytes[i]));
	}
	if (rx_buffer.size() > 4096) {
		rx_buffer.erase(rx_buffer.begin(), rx_buffer.begin() + (rx_buffer.size() - 4096));
	}
	try_parse_buffer();
}

Dictionary ElrsDriver::get_gps() const {
	Dictionary d;
	d["has_fix"] = has_gps;
	d["latitude"] = gps_latitude;
	d["longitude"] = gps_longitude;
	d["altitude_m"] = gps_altitude_m;
	d["ground_speed_mps"] = gps_speed_mps;
	d["heading_deg"] = gps_heading_deg;
	d["satellites"] = gps_satellites;
	return d;
}

Dictionary ElrsDriver::get_battery() const {
	Dictionary d;
	d["has_data"] = has_battery;
	d["voltage_v"] = battery_voltage_v;
	d["current_a"] = battery_current_a;
	d["capacity_used_mah"] = battery_capacity_used_mah;
	d["remaining_pct"] = battery_remaining_pct;
	return d;
}

Dictionary ElrsDriver::get_link_stats() const {
	Dictionary d;
	d["has_data"] = has_link_stats;
	d["uplink_rssi_1"] = uplink_rssi_1;
	d["uplink_rssi_2"] = uplink_rssi_2;
	d["uplink_link_quality"] = uplink_link_quality;
	d["uplink_snr"] = uplink_snr;
	d["uplink_tx_power"] = uplink_tx_power;
	d["downlink_rssi"] = downlink_rssi;
	d["downlink_link_quality"] = downlink_link_quality;
	d["downlink_snr"] = downlink_snr;
	return d;
}

String ElrsDriver::get_flight_mode() const {
	return flight_mode;
}

PackedByteArray ElrsDriver::pack_channels_frame(const Array &channels) {
	uint8_t packed[22] = { 0 };
	int bit_index = 0;
	for (int ch = 0; ch < 16; ch++) {
		uint16_t value = 0;
		if (ch < channels.size()) {
			value = static_cast<uint16_t>(static_cast<int>(channels[ch])) & 0x7FF;
		}
		for (int b = 0; b < 11; b++) {
			if (value & (1 << b)) {
				packed[bit_index / 8] |= static_cast<uint8_t>(1 << (bit_index % 8));
			}
			bit_index++;
		}
	}

	uint8_t type = CRSF_FRAMETYPE_RC_CHANNELS_PACKED;
	uint8_t len = 1 + 22 + 1; // type + payload + crc

	uint8_t crc = 0;
	crc = crc8_dvb_s2(crc, type);
	for (int i = 0; i < 22; i++) {
		crc = crc8_dvb_s2(crc, packed[i]);
	}

	PackedByteArray frame;
	frame.resize(2 + len);
	frame[0] = CRSF_SYNC_BYTE;
	frame[1] = len;
	frame[2] = type;
	for (int i = 0; i < 22; i++) {
		frame[3 + i] = packed[i];
	}
	frame[3 + 22] = crc;
	return frame;
}
