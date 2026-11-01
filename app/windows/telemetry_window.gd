extends PanelContainer
## ELRS link stats, UAV battery, GNSS accuracy, headset battery and a
## best-effort network status -- the catch-all status window. Everything
## here is read from HardwareHub/OS, so new metrics just mean adding a line,
## not touching any other window.

@onready var _label: RichTextLabel = $Margin/Label

func _process(_delta: float) -> void:
	_label.text = "\n".join(_build_lines())

func _build_lines() -> PackedStringArray:
	var lines: PackedStringArray = []
	lines.append("[b]ELRS Link[/b]")
	var link: Dictionary = HardwareHub.get_uav_link_stats()
	if link.get("has_data", false):
		lines.append("  Uplink LQ: %d%%  RSSI: %d/%d dBm  SNR: %d dB" % [
			link["uplink_link_quality"], link["uplink_rssi_1"], link["uplink_rssi_2"], link["uplink_snr"]
		])
		lines.append("  Downlink LQ: %d%%  RSSI: %d dBm  TX power: %d" % [
			link["downlink_link_quality"], link["downlink_rssi"], link["uplink_tx_power"]
		])
	else:
		lines.append("  no ELRS receiver detected")

	lines.append("")
	lines.append("[b]UAV Battery[/b]")
	var batt: Dictionary = HardwareHub.get_uav_battery()
	if batt.get("has_data", false):
		lines.append("  %.1f V   %.1f A   %d%% remaining   %d mAh used" % [
			batt["voltage_v"], batt["current_a"], batt["remaining_pct"], batt["capacity_used_mah"]
		])
	else:
		lines.append("  no telemetry")

	var mode := HardwareHub.get_uav_flight_mode()
	if mode != "":
		lines.append("  Flight mode: %s" % mode)

	lines.append("")
	lines.append("[b]GNSS Accuracy (self)[/b]")
	var fix: Dictionary = HardwareHub.get_self_gps_fix()
	if fix.get("has_fix", false):
		lines.append("  Fix quality: %d   HDOP: %.1f   Satellites: %d" % [
			fix["fix_quality"], fix["hdop"], fix["satellites"]
		])
	else:
		lines.append("  no fix")

	lines.append("")
	lines.append("[b]Headset[/b]")
	lines.append("  Battery: %s" % _headset_battery_text())
	lines.append("  Network: %s" % ("connected" if _has_network() else "no network interface"))

	lines.append("")
	lines.append("[b]Video driver[/b]")
	lines.append("  %s" % _video_driver_text())

	return lines

func _video_driver_text() -> String:
	var info: Dictionary = HardwareHub.get_video_driver_info()
	match info.get("backend", ""):
		"v4l2":
			return "kernel UVC driver (V4L2)"
		"usbfs_android":
			return "built-in driver (Android, by design)"
		"usbfs_fallback":
			return "FALLBACK -- %s" % info.get("warning", "")
		_:
			return "none (no video device)"

## Best-effort battery readout. On Linux (including the Steam Frame, which
## runs a Linux/SteamOS userspace) this reads the standard power_supply
## sysfs tree; Android will need its own JNI-backed source later, kept
## behind this same function so no caller needs to change.
func _headset_battery_text() -> String:
	if OS.get_name() != "Linux":
		return "unknown (no reader for this platform yet)"
	var dir := DirAccess.open("/sys/class/power_supply")
	if dir == null:
		return "unknown"
	for entry in dir.get_directories():
		if entry.begins_with("BAT") or entry.begins_with("battery"):
			var f := FileAccess.open("/sys/class/power_supply/%s/capacity" % entry, FileAccess.READ)
			if f != null:
				# sysfs pseudo-files report size 0 via stat, so read a line
				# rather than get_as_text() (which trusts file length).
				return "%s%%" % f.get_line().strip_edges()
	return "unknown (no battery device found)"

func _has_network() -> bool:
	for addr in IP.get_local_addresses():
		if addr != "127.0.0.1" and addr != "::1" and not addr.begins_with("fe80"):
			return true
	return false
