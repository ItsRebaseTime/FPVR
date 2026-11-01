extends Control
## Linux PC flat shell: lays out the three shared window scenes side by
## side and feeds the ATAK bridge from HardwareHub. This is the reuse proof
## -- the windows and hub are identical to what the VR/Android shells use.

func _ready() -> void:
	var bridge = load("res://bridge/atak_bridge.gd").new()
	add_child(bridge)
	bridge.set_process(true)
	_feed_bridge(bridge)

func _feed_bridge(bridge: Node) -> void:
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.timeout.connect(func():
		bridge.update_self_fix(HardwareHub.get_self_gps_fix())
		bridge.update_uav_fix(HardwareHub.get_uav_fix())
	)
	add_child(timer)
	timer.start()
