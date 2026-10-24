extends SceneTree

## Headless ROS graph check for the target TF contract:
##   map -> target_<team>_<number>                      (target centre, dynamic /tf)
##   target_<team>_<number> -> ..._armor_px|nx|py|ny    (strike faces, /tf_static)
##
## Phase 3: the target centre edges are republished on /tf at
## RosConfig.TARGET_TF_HZ (30 Hz) so motion is visible to tf2 consumers, while
## the armour strike-face edges stay static children of the centre frame. This
## check also loads a moving scenario and verifies the centre TF follows it.
##
## Run inside the ROS 2 Humble container (rclgd loaded); it needs no renderer,
## because target TFs are published independently of the camera stream:
##
##   docker/run.sh godot --headless --script res://tests/target_tf_check.gd
##
## Expects: TARGET_TF: PASS

var _main
var _failures: Array[String] = []
var _probe: Object = null
var _subs: Array = []
var _listener: Object = null


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
	_probe.call("init", "target_tf_probe")
	_listener = _probe.call("create_tf_listener", 10.0)
	await _wait(1.0)

	var targets: Array = _main._targets
	_check("four targets in the scene", targets.size() == 4, str(targets.size()))

	var centers_ok := true
	var armor_ok := true
	var detail := ""
	for target in targets:
		var center_frame := RosConfig.target_frame_id(target.team, target.number)
		var center_lookup = _listener.call("lookup_transform", "map", center_frame)
		if center_lookup == null:
			centers_ok = false
			detail = "%s missing: %s" % [center_frame, _listener.call("get_last_error")]
			continue
		var expected_center: Transform3D = target.get_center_global_transform()
		if (center_lookup.origin - expected_center.origin).length() > 1e-3:
			centers_ok = false
			detail = "%s origin %s != %s" % [center_frame, center_lookup.origin,
				expected_center.origin]
		if absf(angle_difference(
				center_lookup.basis.get_euler().y,
				expected_center.basis.get_euler().y)) > 0.01:
			centers_ok = false
			detail = "%s yaw mismatch" % center_frame

		for armor in target.get_armor_frames():
			var armor_frame := RosConfig.target_armor_frame_id(
				target.team, target.number, String(armor["suffix"]))
			var pose = _listener.call("lookup_transform", center_frame, armor_frame)
			if pose == null:
				armor_ok = false
				detail = "%s missing: %s" % [armor_frame, _listener.call("get_last_error")]
				continue
			var basis: Basis = armor["body_basis"]
			var position: Vector3 = armor["body_position"]
			var expected := Transform3D(
				SimConfig.body_basis_to_godot(basis),
				SimConfig.body_to_godot(position))
			if (pose.origin - expected.origin).length() > 1e-3 \
					or absf(pose.basis.z.normalized().dot(expected.basis.z.normalized())) < 0.9999:
				armor_ok = false
				detail = "%s pose %s != %s" % [armor_frame, pose.origin, expected.origin]
	_check("map -> target centre TF resolves and matches the rig", centers_ok, detail)
	_check("target centre -> armour strike-face TF resolves and matches", armor_ok, detail)

	# Phase 3: load a moving scenario; the centre TF must follow the target.
	_main._apply_scenario_path("res://scenarios/1v1_line.yaml")
	await _wait(0.4)
	var mover = null
	for target in _main._targets:
		if target.is_moving():
			mover = target
			break
	if mover == null:
		_check("moving scenario has a moving target", false)
	else:
		var moving_frame := RosConfig.target_frame_id(mover.team, mover.number)
		var first = _listener.call("lookup_transform", "map", moving_frame)
		await _wait(0.6)
		var second = _listener.call("lookup_transform", "map", moving_frame)
		var moved: bool = first != null and second != null \
			and (second.origin - first.origin).length() > 0.05
		_check("moving target centre TF follows motion on /tf", moved,
			"" if first == null or second == null else "%.2f m" % (second.origin - first.origin).length())

	_finish()


func _finish() -> void:
	_subs.clear()
	_probe = null
	_listener = null
	await process_frame
	await process_frame
	if _failures.is_empty():
		print("TARGET_TF: PASS")
		quit(0)
	else:
		printerr("TARGET_TF: FAIL (%d): %s" % [_failures.size(), ", ".join(_failures)])
		quit(1)
