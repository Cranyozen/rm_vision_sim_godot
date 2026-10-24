extends SceneTree

## Phase 2 (rclgd) integration check. Run inside the ROS 2 Humble container
## with a real display (the feed image needs GPU rendering):
##
##   godot --path . --script res://tests/phase2_ros_check.gd
##
## Verifies, against the live ROS graph:
##   - rclgd is loaded and Main started the RosBackend
##   - /image_raw is 1280x1024 rgb8 at >= 20 Hz
##   - /image_raw/compressed is JPEG at >= 40 Hz
##   - /camera_info intrinsics match SimConfig and arrive
##   - /tf has the field-rooted chain map->odom->gimbal_link, with map->odom
##     carrying the chassis position; static gimbal->camera and
##     camera->optical resolve through tf2
##   - /serial/receive carries mode 1 and the gimbal angles
##   - a /cmd_gimbal message moves the simulated gimbal
##   - a /cmd_chassis Twist moves the chassis
## Expects: PHASE2_ROS: PASS

const TOPIC_IMAGE_RAW := "/image_raw"
const TOPIC_IMAGE_COMPRESSED := "/image_raw/compressed"
const TOPIC_CAMERA_INFO := "/camera_info"
const TOPIC_SERIAL := "/serial/receive"
const TOPIC_CMD_GIMBAL := "/armor_solver/cmd_gimbal"
const TOPIC_CMD_CHASSIS := "/cmd_chassis"

var _main
var _failures: Array[String] = []

var _raw_count := 0
var _jpg_count := 0
var _info_count := 0
var _serial_count := 0
var _tf_count := 0

var _raw_msg = null
var _jpg_msg = null
var _info_msg = null
var _serial_msg = null

var _probe: Object = null
var _probe_subs: Array = []
var _tf_listener: Object = null
var _headless := DisplayServer.get_name() == "headless"
var _pub_gimbal: Object = null
var _pub_chassis: Object = null


func _initialize() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	_run.call_deferred()


func _check(name: String, ok: bool, detail := "") -> void:
	print(("  ok   " if ok else "  FAIL ") + name + ("  " + detail if detail != "" else ""))
	if not ok:
		_failures.append(name)


func _wait(seconds: float) -> void:
	var end := Time.get_ticks_usec() + int(seconds * 1e6)
	while Time.get_ticks_usec() < end:
		await process_frame


func _new_msg(type: String):
	var msg = ClassDB.instantiate("RosMsg")
	if msg == null:
		return null
	msg.call("init", type)
	return msg


func _qos(reliability: int, depth: int) -> Object:
	var qos = ClassDB.instantiate("RosQoS")
	qos.set("reliability", reliability)
	qos.set("history", 0)
	qos.set("depth", depth)
	qos.set("durability", 0)
	return qos


func _run() -> void:
	await _wait(1.0)
	var ros = _main._ros
	_check("RosBackend exists", ros != null)
	if ros == null:
		_finish()
		return
	_check("rclgd backend available", ros.available, ros.failure)
	if not ros.available:
		_finish()
		return

	_probe = ClassDB.instantiate("RosNode")
	_probe.call("init", "phase2_probe")
	# Keep every subscription alive: rclgd objects are RefCounted and a dropped
	# reference silently unsubscribes.
	_probe_subs.append(_probe.call("create_subscription", TOPIC_IMAGE_RAW, "sensor_msgs/msg/Image",
		Callable(self, "_on_raw"), _qos(1, 1)))
	_probe_subs.append(_probe.call("create_subscription", TOPIC_IMAGE_COMPRESSED, "sensor_msgs/msg/CompressedImage",
		Callable(self, "_on_jpg"), _qos(1, 1)))
	_probe_subs.append(_probe.call("create_subscription", TOPIC_CAMERA_INFO, "sensor_msgs/msg/CameraInfo",
		Callable(self, "_on_info"), _qos(1, 1)))
	_probe_subs.append(_probe.call("create_subscription", TOPIC_SERIAL, "rm_interfaces/msg/SerialReceiveData",
		Callable(self, "_on_serial"), _qos(1, 1)))
	_probe_subs.append(_probe.call("create_subscription", "/tf", "tf2_msgs/msg/TFMessage",
		Callable(self, "_on_tf"), _qos(0, 100)))
	_tf_listener = _probe.call("create_tf_listener", 10.0)
	_pub_gimbal = _probe.call("create_publisher", TOPIC_CMD_GIMBAL,
		"rm_interfaces/msg/GimbalCmd", _qos(0, 10))
	_pub_chassis = _probe.call("create_publisher", TOPIC_CMD_CHASSIS,
		"rm_interfaces/msg/ChassisCmd", _qos(0, 10))

	# Let discovery + the publishers settle, then measure for 2 s.
	await _wait(1.0)
	_raw_count = 0
	_jpg_count = 0
	_info_count = 0
	_serial_count = 0
	_tf_count = 0
	var t0 := Time.get_ticks_usec()
	await _wait(2.0)
	var elapsed := float(Time.get_ticks_usec() - t0) / 1e6
	var raw_hz := float(_raw_count) / elapsed
	var jpg_hz := float(_jpg_count) / elapsed
	var info_hz := float(_info_count) / elapsed
	var serial_hz := float(_serial_count) / elapsed
	var tf_hz := float(_tf_count) / elapsed
	print("  measured: raw %.1f Hz  jpg %.1f Hz  info %.1f Hz  serial %.1f Hz  tf %.1f Hz"
		% [raw_hz, jpg_hz, info_hz, serial_hz, tf_hz])

	if _headless:
		print("  headless: camera image checks skipped (no renderer)")
	else:
		_check("raw image >= 20 Hz", raw_hz >= 20.0, "%.1f" % raw_hz)
		_check("compressed image >= 40 Hz", jpg_hz >= 40.0, "%.1f" % jpg_hz)
	_check("camera_info >= 8 Hz", info_hz >= 8.0, "%.1f" % info_hz)
	_check("serial >= 40 Hz", serial_hz >= 40.0, "%.1f" % serial_hz)
	# One TF sample per rendered frame, so the ceiling is the render rate; the
	# solver only needs coverage at image stamps. 100 Hz target needs >100 fps.
	_check("tf >= 45 Hz", tf_hz >= 45.0, "%.1f" % tf_hz)

	if _headless:
		pass
	elif _raw_msg != null:
		_check("raw encoding rgb8", String(_raw_msg.get("encoding")) == "rgb8")
		_check("raw size 1280x1024",
			int(_raw_msg.get("width")) == SimConfig.FEED_WIDTH
			and int(_raw_msg.get("height")) == SimConfig.FEED_HEIGHT)
		var data: PackedByteArray = _raw_msg.get("data")
		_check("raw data length", data.size() == SimConfig.FEED_WIDTH * SimConfig.FEED_HEIGHT * 3,
			str(data.size()))
		_check("raw frame_id", String(_raw_msg.get("header").get("frame_id")) == RosConfig.FRAME_CAMERA_OPTICAL)
	elif not _headless:
		_check("raw image received", false)

	if _headless:
		pass
	elif _jpg_msg != null:
		_check("compressed format jpeg", String(_jpg_msg.get("format")) == "jpeg")
		var jpeg: PackedByteArray = _jpg_msg.get("data")
		_check("compressed is a JPEG stream", jpeg.size() > 2 and jpeg[0] == 0xFF and jpeg[1] == 0xD8,
			"%d bytes" % jpeg.size())
	elif not _headless:
		_check("compressed image received", false)

	if _info_msg != null:
		var k: PackedFloat64Array = _info_msg.get("k")
		var ints := SimConfig.feed_intrinsics()
		_check("camera_info width/height",
			int(_info_msg.get("width")) == SimConfig.FEED_WIDTH
			and int(_info_msg.get("height")) == SimConfig.FEED_HEIGHT)
		_check("camera_info fx/fy/cx/cy match SimConfig",
			is_equal_approx(k[0], float(ints["fx"]))
			and is_equal_approx(k[4], float(ints["fy"]))
			and is_equal_approx(k[2], float(ints["cx"]))
			and is_equal_approx(k[5], float(ints["cy"])),
			"k=[%.2f,0,%.2f; 0,%.2f,%.2f]" % [k[0], k[2], k[4], k[5]])
		var d: PackedFloat64Array = _info_msg.get("d")
		_check("camera_info D = 0 (Phase 2)", d.size() == 5 and d[0] == 0.0 and d[4] == 0.0)
	else:
		_check("camera_info received", false)

	if _serial_msg != null:
		_check("serial mode = 1", int(_serial_msg.get("mode")) == 1)
		_check("serial bullet_speed > 0", float(_serial_msg.get("bullet_speed")) > 0.0,
			str(_serial_msg.get("bullet_speed")))
	else:
		_check("serial received", false)

	if _tf_listener != null:
		var gimbal = _tf_listener.call("lookup_transform", "odom", "gimbal_link")
		_check("tf odom -> gimbal_link resolves", gimbal != null,
			"" if gimbal != null else String(_tf_listener.call("get_last_error")))
		var camera = _tf_listener.call("lookup_transform", "gimbal_link", "camera_link")
		_check("tf gimbal_link -> camera_link resolves", camera != null,
			"" if camera != null else String(_tf_listener.call("get_last_error")))
		var optical = _tf_listener.call("lookup_transform", "camera_link", "camera_optical_frame")
		_check("tf camera_link -> camera_optical_frame resolves", optical != null,
			"" if optical != null else String(_tf_listener.call("get_last_error")))
		var map_odom = _tf_listener.call("lookup_transform", "map", "odom")
		_check("tf map -> odom resolves (field-rooted TF)", map_odom != null,
			"" if map_odom != null else String(_tf_listener.call("get_last_error")))
		# lookup_transform returns a Godot-space Transform3D (rclgd applies the
		# inverse ROS mapping). odom is the gimbal-base frame in the field, so
		# map->odom origin equals the gimbal joint's Godot position.
		var gimbal_link = _main._ego.get_gimbal_link()
		var expected: Vector3 = gimbal_link.global_position
		var expected_yaw := deg_to_rad(_main._controller.chassis_yaw_deg)
		if map_odom != null:
			_check("tf map -> odom carries the chassis position",
				(map_odom.origin - expected).length() < 1e-4,
				"map->odom=%s expected=%s" % [map_odom.origin, expected])
			_check("tf map -> odom carries the chassis yaw",
				absf(angle_difference(map_odom.basis.get_euler().y, expected_yaw)) < 0.05,
				"yaw %.3f expected %.3f" % [map_odom.basis.get_euler().y, expected_yaw])
		if gimbal != null:
			_check("tf odom -> gimbal_link has zero translation (QYG contract)",
				gimbal.origin.length() < 1e-6, "origin=%s" % gimbal.origin)
			var map_gimbal = _tf_listener.call("lookup_transform", "map", "gimbal_link")
			_check("tf map -> gimbal_link starts at the field position",
				map_gimbal != null and (map_gimbal.origin - expected).length() < 1e-4,
				"map->gimbal=%s expected=%s" % [
					map_gimbal.origin if map_gimbal != null else "null", expected])

	# /cmd_gimbal -> simulated gimbal. Wait for discovery first.
	await _wait(0.5)
	var before_yaw: float = _main._controller.gimbal_yaw_deg
	var before_pitch: float = _main._controller.gimbal_pitch_deg
	var cmd = _new_msg("rm_interfaces/msg/GimbalCmd")
	cmd.set("yaw", 12.5)
	cmd.set("pitch", -7.0)
	cmd.set("distance", 3.0)
	cmd.set("id", "3")
	_pub_gimbal.call("publish", cmd)
	await _wait(0.5)
	_check("cmd_gimbal moves the gimbal yaw",
		absf(_main._controller.gimbal_yaw_deg - 12.5) < 0.01,
		"%.2f -> %.2f" % [before_yaw, _main._controller.gimbal_yaw_deg])
	_check("cmd_gimbal moves the gimbal pitch",
		absf(_main._controller.gimbal_pitch_deg - (-7.0)) < 0.01,
		"%.2f -> %.2f" % [before_pitch, _main._controller.gimbal_pitch_deg])

	# /cmd_chassis -> kinematic chassis.
	await _wait(0.2)
	var pos0: Vector3 = _main._controller.chassis_position
	var chassis = _new_msg("rm_interfaces/msg/ChassisCmd")
	var twist = chassis.get("twist")
	var linear = twist.get("linear")
	linear.set("x", 1.0)
	linear.set("y", 0.0)
	linear.set("z", 0.0)
	var angular = twist.get("angular")
	angular.set("x", 0.0)
	angular.set("y", 0.0)
	angular.set("z", 0.0)
	chassis.set("is_spining", false)
	chassis.set("is_navigating", true)
	_pub_chassis.call("publish", chassis)
	await _wait(0.4)
	var moved: float = (_main._controller.chassis_position - pos0).length()
	_check("cmd_chassis drives the chassis", moved > 0.05, "moved %.3f m" % moved)
	await _wait(0.1)
	var map_odom_after = _tf_listener.call("lookup_transform", "map", "odom")
	var chassis_after: Vector3 = _main._ego.get_gimbal_link().global_position
	_check("tf map -> odom follows the moving chassis",
		map_odom_after != null and (map_odom_after.origin - chassis_after).length() < 0.05,
		"map->odom=%s gimbal=%s" % [
			map_odom_after.origin if map_odom_after != null else "null", chassis_after])

	var stats: Dictionary = ros.get_stats()
	print("  backend stats: ", stats)
	_check("frame time budget (< 16.6 ms)", _main._smoothed_frame_ms < 16.6,
		"%.2f ms" % _main._smoothed_frame_ms)

	_finish()


func _finish() -> void:
	# Unsubscribe and let queued main-thread callbacks drain before quitting;
	# otherwise deferred methods can fire after the SceneTree script is freed.
	_probe_subs.clear()
	_probe = null
	_tf_listener = null
	await process_frame
	await process_frame
	if _failures.is_empty():
		print("PHASE2_ROS: PASS")
		quit(0)
	else:
		printerr("PHASE2_ROS: FAIL (%d): %s" % [_failures.size(), ", ".join(_failures)])
		quit(1)


func _on_raw(msg) -> void:
	_raw_count += 1
	_raw_msg = msg


func _on_jpg(msg) -> void:
	_jpg_count += 1
	_jpg_msg = msg


func _on_info(msg) -> void:
	_info_count += 1
	_info_msg = msg


func _on_serial(msg) -> void:
	_serial_count += 1
	_serial_msg = msg


func _on_tf(_msg) -> void:
	_tf_count += 1
