extends Node
## Shares our own position and the UAV's position/telemetry with ATAK
## running on a companion phone, as standard Cursor-on-Target (CoT) events.
## No ATAK-side plugin needed: ATAK already listens for CoT on this address.
##
## Bluetooth PAN and USB-ethernet-gadget "transports" mentioned in the
## architecture plan are not separate code paths -- once either is set up as
## a network interface, it's just another route to the same UDP destination,
## so this one node covers all three bearer options. Only the target address
## changes (point it at the phone's IP on whichever interface is active).
##
## Shared verbatim by every shell (VR / Android / Linux) -- instantiate once
## and feed it fixes each frame.

const DEFAULT_ATAK_SA_MULTICAST := "239.2.3.1"
const DEFAULT_ATAK_SA_PORT := 6969
const SEND_INTERVAL := 1.0 # seconds between CoT broadcasts (ATAK default SA rate)
const STALE_SECONDS := 20.0
const DETECTION_STALE_SECONDS := 10.0 # shorter than self/UAV: a stale detection is more likely to be plain wrong than a stale GPS fix

@export var target_address: String = DEFAULT_ATAK_SA_MULTICAST
@export var target_port: int = DEFAULT_ATAK_SA_PORT
@export var self_uid: String = "FPVR-SELF"
@export var self_callsign: String = "FPVR"
@export var uav_uid: String = "FPVR-UAV"
@export var uav_callsign: String = "UAV"

var _socket: PacketPeerUDP
var _send_timer := 0.0

var _self_fix: Dictionary = {} # has_fix, latitude, longitude, altitude_m
var _uav_fix: Dictionary = {} # has_fix, latitude, longitude, altitude_m, ground_speed_mps, heading_deg
var _detections: Array = [] # latest from DetectionService.detections_updated

func _ready() -> void:
	_apply_settings()
	Settings.settings_changed.connect(_apply_settings)
	_connect_socket()
	DetectionService.detections_updated.connect(_on_detections_updated)

func _apply_settings() -> void:
	target_address = Settings.atak_target_address
	target_port = Settings.atak_target_port
	self_callsign = Settings.self_callsign
	uav_callsign = Settings.uav_callsign
	_connect_socket()

func _connect_socket() -> void:
	_socket = PacketPeerUDP.new()
	_socket.set_broadcast_enabled(true)
	_socket.connect_to_host(target_address, target_port)

func update_self_fix(fix: Dictionary) -> void:
	_self_fix = fix

func update_uav_fix(fix: Dictionary) -> void:
	_uav_fix = fix

func _on_detections_updated(detections: Array) -> void:
	_detections = detections

func _process(delta: float) -> void:
	_send_timer += delta
	if _send_timer < SEND_INTERVAL:
		return
	_send_timer = 0.0
	_broadcast()

func _broadcast() -> void:
	if _self_fix.get("has_fix", false):
		var xml := CotMessage.build_position_event(
			self_uid, self_callsign, "a-f-G-U-C",
			_self_fix["latitude"], _self_fix["longitude"], _self_fix.get("altitude_m", 0.0),
			10.0, 10.0, STALE_SECONDS, ""
		)
		_socket.put_packet(xml.to_utf8_buffer())

	if _uav_fix.get("has_fix", false):
		var xml := CotMessage.build_uav_event(
			uav_uid, uav_callsign,
			_uav_fix["latitude"], _uav_fix["longitude"], _uav_fix.get("altitude_m", 0.0),
			_uav_fix.get("ground_speed_mps", 0.0), _uav_fix.get("heading_deg", 0.0),
			STALE_SECONDS
		)
		_socket.put_packet(xml.to_utf8_buffer())

	if Settings.detection_send_to_atak:
		_broadcast_detections()

## Sends one CoT event per non-excluded detection with a resolved position
## estimate, over the same multicast socket self/UAV already use -- any
## teammate's ATAK/phone already on this network sees them with no new
## transport (see the plan's section F for why local multicast is v1's
## whole scope; a phone reachable only via LTE with no shared local
## network needs a separate TAK-server client, not built yet).
##
## cot_type "a-u-G" (unknown-ground) deliberately avoids asserting
## hostile/friendly from vision alone -- the ATAK operator reclassifies
## locally once they've visually confirmed. ce_m scales with range_m
## since the position estimate's own accuracy gets worse at longer range
## (see detection_geolocation.gd); le_m is a flat guess since the
## estimate assumes flat ground with no real altitude data at all.
##
## uid is just the detection's index in the current batch, not a stable
## per-person id -- there's no multi-frame tracking/re-identification yet,
## so this is a fresh, independent marker each tick rather than the same
## marker being updated. DETECTION_STALE_SECONDS makes stale ones vanish
## quickly rather than accumulate.
func _broadcast_detections() -> void:
	for i in range(_detections.size()):
		var detection: Dictionary = _detections[i]
		if detection.get("referee_excluded", false):
			continue
		var estimate: Dictionary = detection.get("position_estimate", {})
		if not estimate.get("has_estimate", false):
			continue
		var range_m: float = estimate.get("range_m", 50.0)
		# Not "class_name" -- that's a reserved GDScript keyword (the
		# class_name Foo declaration statement), not usable as a plain
		# identifier; using it here previously caused a parse error that
		# only ever surfaced at runtime (see the commit this comment was
		# added in) since this script is dynamically load()'d by path
		# rather than statically referenced, so Godot's export-time
		# resource scan never compiled it to catch the error ahead of time.
		var det_class_name: String = detection.get("class_name", "detection")
		var xml := CotMessage.build_position_event(
			"FPVR-DET-%d" % i, det_class_name.capitalize(), "a-u-G",
			estimate["latitude"], estimate["longitude"], 0.0,
			max(15.0, range_m * 0.15), 50.0, DETECTION_STALE_SECONDS, ""
		)
		_socket.put_packet(xml.to_utf8_buffer())
