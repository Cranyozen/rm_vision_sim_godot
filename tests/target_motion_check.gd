extends SceneTree

## Headless check for the Phase 3 target motion engine:
## - deterministic path sampling for line / polyline (t = 0, middle, end);
## - once clamps at the end and sets `finished`, loop wraps, pingpong reverses;
## - polyline loop includes the closing segment, once / pingpong stay open;
## - spin once stops after one full turn, loop keeps turning, pingpong sweeps;
## - TargetRig.step_motion() moves the root and the centre / armour TF frames
##   derived from global transforms follow;
## - static targets and rigs without motion never move.
##
## Usage: godot --headless --path . --script res://tests/target_motion_check.gd
## Expects: TARGET_MOTION_CHECK: PASS

const TOL := 1e-3

var _frames := 0
var _done := false
var _failures: Array[String] = []

var _path_rig: TargetRig
var _spin_rig: TargetRig
var _static_rig: TargetRig


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		# Build after the SceneTree is running: instantiating GLB armour from
		# _initialize crashes on Godot 4.7.2 headless (see target_rig_check.gd).
		_path_rig = _new_target("MotionTarget", Vector3(-1.0, 0.0, -1.0), 20.0)
		root.add_child(_path_rig)
		_spin_rig = _new_target("SpinTarget", Vector3(1.0, 0.0, -1.0), 10.0)
		root.add_child(_spin_rig)
		_static_rig = _new_target("StaticTarget", Vector3(3.0, 0.0, 3.0), 0.0)
		root.add_child(_static_rig)
		return false
	if _frames < 3:
		return false
	if _done:
		return true
	_done = true
	_run_checks()
	if _failures.is_empty():
		print("TARGET_MOTION_CHECK: PASS")
		quit(0)
	else:
		printerr("TARGET_MOTION_CHECK: FAIL (%d): %s" % [_failures.size(), ", ".join(_failures)])
		quit(1)
	return true


func _new_target(node_name: String, pos: Vector3, yaw: float) -> TargetRig:
	var target := TargetRig.new()
	target.name = node_name
	target.team = "red"
	target.number = "1"
	target.position = pos
	target.yaw_deg = yaw
	return target


func _motion(config: Dictionary, base_position: Vector3, base_yaw_deg: float) -> TargetMotion:
	return TargetMotion.from_config(config, base_position, base_yaw_deg)


func _check(name: String, ok: bool, detail := "") -> void:
	print(("  ok   " if ok else "  FAIL ") + name + ("  " + detail if detail != "" else ""))
	if not ok:
		_failures.append(name)


func _near(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) <= TOL


func _near_float(a: float, b: float) -> bool:
	return absf(a - b) <= TOL


func _near_deg(a: float, b: float) -> bool:
	return absf(angle_difference(deg_to_rad(a), deg_to_rad(b))) <= deg_to_rad(0.05)


func _plate_global(frames: Array[Dictionary], index: int) -> Vector3:
	var plate: Node3D = frames[index]["plate"]
	return plate.global_position


func _run_checks() -> void:
	_check_line_path()
	_check_polyline_path()
	_check_spin()
	_check_rig_motion()
	_check_static()


# --- path motion -------------------------------------------------------------

func _check_line_path() -> void:
	# Y values are deliberately non-zero: path points are floor anchored.
	var line := _motion({
		"type": "line",
		"mode": "pingpong",
		"speed": 1.0,
		"waypoints": [[0.0, 5.0, 0.0], [0.0, 5.0, -2.0]],
	}, Vector3.ZERO, 25.0)
	_check("line path length", _near_float(line.path_length(), 2.0), "%.3f" % line.path_length())
	_check("line reports moving", line.is_moving())
	line.update(0.0)
	_check("line t=0 at the start", _near(line.current_position, Vector3(0.0, 0.0, 0.0)),
		str(line.current_position))
	line.update(1.0)
	_check("line t=mid at half the path", _near(line.current_position, Vector3(0.0, 0.0, -1.0)),
		str(line.current_position))
	_check("path motion keeps the scenario yaw", _near_deg(line.current_yaw_deg, 25.0),
		"%.3f deg" % line.current_yaw_deg)
	line.update(2.0)
	_check("line t=end at the far end", _near(line.current_position, Vector3(0.0, 0.0, -2.0)),
		str(line.current_position))
	line.update(3.0)
	_check("line pingpong reverses at the end", _near(line.current_position, Vector3(0.0, 0.0, -1.0)),
		str(line.current_position))
	_check("pingpong never reports finished", not line.finished)

	var pose := line.get_pose()
	_check("get_pose() matches the sampled state",
		_near(pose.origin, line.current_position)
			and _near_deg(rad_to_deg(pose.basis.get_euler().y), line.current_yaw_deg))

	# One waypoint: the path runs from the rig position to that waypoint.
	var single := _motion({
		"type": "line",
		"mode": "once",
		"speed": 1.0,
		"waypoints": [[3.0, 1.0, 4.0]],
	}, Vector3.ZERO, 0.0)
	_check("single-waypoint line starts at the rig position",
		_near_float(single.path_length(), 5.0), "%.3f" % single.path_length())
	single.update(2.5)
	_check("single-waypoint line half-way", _near(single.current_position, Vector3(1.5, 0.0, 2.0)),
		str(single.current_position))
	single.update(10.0)
	_check("single-waypoint line clamps at the waypoint",
		_near(single.current_position, Vector3(3.0, 0.0, 4.0)) and single.finished)

	# Loop wraps around to the start.
	var line_loop := _motion({
		"type": "line",
		"mode": "loop",
		"speed": 1.0,
		"waypoints": [[0.0, 0.0, 0.0], [0.0, 0.0, -2.0]],
	}, Vector3.ZERO, 0.0)
	line_loop.update(2.0)
	_check("line loop returns to the start at one length",
		_near(line_loop.current_position, Vector3(0.0, 0.0, 0.0)), str(line_loop.current_position))
	line_loop.update(2.5)
	_check("line loop wraps past the end", _near(line_loop.current_position, Vector3(0.0, 0.0, -0.5)),
		str(line_loop.current_position))


func _check_polyline_path() -> void:
	var points := [[0.0, 0.0, 0.0], [2.0, 0.0, 0.0], [2.0, 0.0, -2.0]]
	var closing := sqrt(8.0)
	var open_length := 4.0

	var loop := _motion({
		"type": "polyline",
		"mode": "loop",
		"speed": 1.0,
		"waypoints": points,
	}, Vector3.ZERO, 0.0)
	_check("polyline loop length includes the closing segment",
		_near_float(loop.path_length(), open_length + closing), "%.3f" % loop.path_length())
	loop.update(0.0)
	_check("polyline t=0 at the first waypoint",
		_near(loop.current_position, Vector3(0.0, 0.0, 0.0)), str(loop.current_position))
	loop.update(2.0)
	_check("polyline t=mid at the second waypoint",
		_near(loop.current_position, Vector3(2.0, 0.0, 0.0)), str(loop.current_position))
	loop.update(4.0)
	_check("polyline t=end at the last waypoint",
		_near(loop.current_position, Vector3(2.0, 0.0, -2.0)), str(loop.current_position))
	loop.update(loop.path_length())
	_check("polyline loop closes back to the first waypoint",
		_near(loop.current_position, Vector3(0.0, 0.0, 0.0)), str(loop.current_position))
	loop.update(loop.path_length() + 0.5)
	_check("polyline loop wraps onto the first segment",
		_near(loop.current_position, Vector3(0.5, 0.0, 0.0)), str(loop.current_position))
	_check("polyline reports moving", loop.is_moving())

	var once := _motion({
		"type": "polyline",
		"mode": "once",
		"speed": 1.0,
		"waypoints": points,
	}, Vector3.ZERO, 0.0)
	_check("polyline once length is the open path", _near_float(once.path_length(), open_length),
		"%.3f" % once.path_length())
	once.update(3.0)
	_check("polyline once samples mid-path",
		_near(once.current_position, Vector3(2.0, 0.0, -1.0)) and not once.finished,
		str(once.current_position))
	once.update(100.0)
	_check("polyline once clamps at the last waypoint and finishes",
		_near(once.current_position, Vector3(2.0, 0.0, -2.0)) and once.finished,
		str(once.current_position))


# --- spin motion -------------------------------------------------------------

func _check_spin() -> void:
	var spin_once := _motion({
		"type": "spin",
		"mode": "once",
		"spin_deg_s": 90.0,
	}, Vector3(2.0, 0.0, 2.0), 10.0)
	_check("spin path length is zero", _near_float(spin_once.path_length(), 0.0))
	_check("spin reports moving", spin_once.is_moving())
	spin_once.update(1.0)
	_check("spin once turns at spin_deg_s", _near_deg(spin_once.current_yaw_deg, 100.0),
		"%.3f deg" % spin_once.current_yaw_deg)
	_check("spin keeps the base position", _near(spin_once.current_position, Vector3(2.0, 0.0, 2.0)),
		str(spin_once.current_position))
	_check("spin once is not finished during the turn", not spin_once.finished)
	spin_once.update(10.0)
	_check("spin once stops after one full turn",
		_near_deg(spin_once.current_yaw_deg, 370.0) and spin_once.finished,
		"%.3f deg" % spin_once.current_yaw_deg)
	spin_once.update(100.0)
	_check("spin once clamps (no over-rotation)",
		_near_deg(spin_once.current_yaw_deg, 370.0) and spin_once.finished,
		"%.3f deg" % spin_once.current_yaw_deg)

	var spin_loop := _motion({
		"type": "spin",
		"mode": "loop",
		"spin_deg_s": 90.0,
	}, Vector3.ZERO, 0.0)
	spin_loop.update(5.0)
	_check("spin loop keeps turning", _near_deg(spin_loop.current_yaw_deg, 450.0) and not spin_loop.finished,
		"%.3f deg" % spin_loop.current_yaw_deg)

	var spin_pingpong := _motion({
		"type": "spin",
		"mode": "pingpong",
		"spin_deg_s": 90.0,
	}, Vector3.ZERO, 0.0)
	spin_pingpong.update(2.0)
	_check("spin pingpong forward sweep", _near_deg(spin_pingpong.current_yaw_deg, 180.0),
		"%.3f deg" % spin_pingpong.current_yaw_deg)
	spin_pingpong.update(4.0)
	_check("spin pingpong reaches one full turn", _near_deg(spin_pingpong.current_yaw_deg, 360.0),
		"%.3f deg" % spin_pingpong.current_yaw_deg)
	spin_pingpong.update(6.0)
	_check("spin pingpong reverses", _near_deg(spin_pingpong.current_yaw_deg, 180.0),
		"%.3f deg" % spin_pingpong.current_yaw_deg)
	spin_pingpong.update(8.0)
	_check("spin pingpong returns to the base yaw", _near_deg(spin_pingpong.current_yaw_deg, 0.0),
		"%.3f deg" % spin_pingpong.current_yaw_deg)

	var spin_clockwise := _motion({
		"type": "spin",
		"mode": "once",
		"spin_deg_s": -180.0,
	}, Vector3.ZERO, 0.0)
	spin_clockwise.update(5.0)
	_check("negative spin_deg_s turns clockwise and clamps",
		_near_deg(spin_clockwise.current_yaw_deg, -360.0) and spin_clockwise.finished,
		"%.3f deg" % spin_clockwise.current_yaw_deg)


# --- rig runtime pose / TF frames -------------------------------------------

func _check_rig_motion() -> void:
	var frames := _path_rig.get_armor_frames()
	_check("rig still builds four armour modules", frames.size() == 4, str(frames.size()))
	var center_before := _path_rig.get_center_global_transform()
	var plates_before: Array[Vector3] = []
	for i in frames.size():
		plates_before.append(_plate_global(frames, i))

	_path_rig.motion = _motion({
		"type": "line",
		"mode": "pingpong",
		"speed": 1.0,
		"waypoints": [[-1.0, 0.0, -1.0], [-1.0, 0.0, 3.0]],
	}, _path_rig.position, _path_rig.yaw_deg)
	_check("rig reports motion after assigning TargetMotion", _path_rig.is_moving())

	_path_rig.step_motion(0.0)
	_check("step_motion(0) keeps the initial rig pose",
		_near(_path_rig.global_position, Vector3(-1.0, 0.0, -1.0))
			and _near(_path_rig.get_center_global_transform().origin, center_before.origin),
		str(_path_rig.global_position))

	_path_rig.step_motion(1.0)
	var center_after := _path_rig.get_center_global_transform()
	_check("target root follows the path", _near(_path_rig.global_position, Vector3(-1.0, 0.0, 0.0)),
		str(_path_rig.global_position))
	_check("centre TF follows the root",
		_near(center_after.origin, center_before.origin + Vector3(0.0, 0.0, 1.0)),
		str(center_after.origin))
	_check("centre TF keeps the scenario yaw and height",
		_near_deg(rad_to_deg(center_after.basis.get_euler().y), 20.0)
			and _near_float(center_after.origin.y, center_before.origin.y),
		"yaw=%.2f y=%.3f" % [rad_to_deg(center_after.basis.get_euler().y), center_after.origin.y])
	var plates_follow := true
	for i in frames.size():
		if not _near(_plate_global(frames, i), plates_before[i] + Vector3(0.0, 0.0, 1.0)):
			plates_follow = false
	_check("armour plate world poses follow the root", plates_follow)

	_path_rig.step_motion(4.0)
	_check("path end pose applied to the rig",
		_near(_path_rig.get_center_global_transform().origin,
			center_before.origin + Vector3(0.0, 0.0, 4.0)),
		str(_path_rig.global_position))
	_path_rig.step_motion(5.0)
	_check("rig pingpong reverses at the end",
		_near(_path_rig.get_center_global_transform().origin,
			center_before.origin + Vector3(0.0, 0.0, 3.0)),
		str(_path_rig.global_position))

	# Spin: the centre stays put, every plate orbits it.
	var spin_frames := _spin_rig.get_armor_frames()
	var spin_center_before := _spin_rig.get_center_global_transform()
	var spin_plate_before := _plate_global(spin_frames, 0)
	_spin_rig.motion = _motion({
		"type": "spin",
		"mode": "loop",
		"spin_deg_s": 90.0,
	}, _spin_rig.position, _spin_rig.yaw_deg)
	_spin_rig.step_motion(1.0)
	var spin_center_after := _spin_rig.get_center_global_transform()
	var spin_plate_after := _plate_global(spin_frames, 0)
	_check("spin rotates the rig root", _near_deg(
		rad_to_deg(spin_center_after.basis.get_euler().y), 100.0),
		"%.2f deg" % rad_to_deg(spin_center_after.basis.get_euler().y))
	_check("spin keeps the target centre in place",
		_near(spin_center_after.origin, spin_center_before.origin), str(spin_center_after.origin))
	_check("armour orbits the centre while spinning",
		_near_float(spin_plate_after.distance_to(spin_center_after.origin),
			spin_plate_before.distance_to(spin_center_before.origin))
			and spin_plate_after.distance_to(spin_plate_before) > 0.01,
		"moved %.3f m" % spin_plate_after.distance_to(spin_plate_before))


# --- static ------------------------------------------------------------------

func _check_static() -> void:
	var center_before := _static_rig.get_center_global_transform()
	var plate_before := _plate_global(_static_rig.get_armor_frames(), 0)
	_check("rig without motion reports not moving", not _static_rig.is_moving())
	_static_rig.step_motion(10.0)
	_check("rig without motion never moves",
		_near(_static_rig.get_center_global_transform().origin, center_before.origin)
			and _near(_plate_global(_static_rig.get_armor_frames(), 0), plate_before))

	_static_rig.motion = _motion({"type": "static"}, _static_rig.position, _static_rig.yaw_deg)
	_check("static TargetMotion reports not moving",
		not _static_rig.is_moving() and not _static_rig.motion.is_moving())
	_static_rig.step_motion(10.0)
	_check("static target never moves",
		_near(_static_rig.get_center_global_transform().origin, center_before.origin)
			and _near(_plate_global(_static_rig.get_armor_frames(), 0), plate_before))
	_check("static motion is finished from the start", _static_rig.motion.finished)
