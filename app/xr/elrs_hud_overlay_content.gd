extends Control
## ELRS HUD content: link quality/RSSI, UAV battery, and flight mode,
## anchored to corners so the rest of the overlay stays transparent over
## the video feed -- a lean flight-relevant subset of
## telemetry_window.gd's fuller status readout (that window also covers
## GNSS/headset battery/network/video-driver, which don't belong on a
## flight HUD), read from the exact same HardwareHub calls.

@onready var _link_label: Label = $LinkLabel
@onready var _battery_label: Label = $BatteryLabel
@onready var _mode_label: Label = $ModeLabel

func _process(_delta: float) -> void:
	var link: Dictionary = HardwareHub.get_uav_link_stats()
	if link.get("has_data", false):
		_link_label.text = "LQ %d%%  RSSI %d/%d dBm" % [
			link["uplink_link_quality"], link["uplink_rssi_1"], link["uplink_rssi_2"]
		]
	else:
		_link_label.text = "No ELRS link"

	var batt: Dictionary = HardwareHub.get_uav_battery()
	if batt.get("has_data", false):
		_battery_label.text = "%.1fV  %d%%" % [batt["voltage_v"], batt["remaining_pct"]]
	else:
		_battery_label.text = "No battery data"

	_mode_label.text = HardwareHub.get_uav_flight_mode()
