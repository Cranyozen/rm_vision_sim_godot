extends SceneTree

## Headless check for the four-armour target rig (rules S120/S121/S124/S125):
## - four armour modules, two opposed pairs on the body ±X / ±Y axes;
## - the lower pair's plate-centre midpoint is the target centre and the upper
##   pair is centred directly above it;
## - 75 deg mounting, direction vectors on the body axes, perpendicular group
##   lines and no cross-axis offset;
## - lower-edge limits and the adjustable centre height / group offset / spans;
## - out-of-range layout values are clamped back into a compliant layout.
##
## Usage: godot --headless --path . --script res://tests/target_rig_check.gd
## Expects: TARGET_RIG_CHECK: PASS

var _frames := 0
var _rig: TargetRig
var _tuned: TargetRig
var _clamped: TargetRig
var _done := false
var _failures: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		# Build after the SceneTree is running: instantiating GLB scenes from
		# _initialize crashes on Godot 4.7.2 headless.
		_rig = _new_target("CheckTarget", "small", "3", Vector3.ZERO)
		root.add_child(_rig)

		_tuned = _new_target("TunedTarget", "large", "1", Vector3(0.5, 0.0, -1.0))
		_tuned.center_height_m = 0.30
		_tuned.group_height_offset_m = 0.02
		_tuned.x_group_span_m = 0.66
		_tuned.y_group_span_m = 0.54
		_tuned.lower_group = "y"
		_tuned.yaw_deg = 30.0
		root.add_child(_tuned)

		_clamped = _new_target("ClampedTarget", "small", "2", Vector3(-1.0, 0.0, -1.0))
		_clamped.lower_group = "z"
		_clamped.center_height_m = 0.90
		_clamped.group_height_offset_m = 0.50
		_clamped.x_group_span_m = 0.01
		_clamped.y_group_span_m = 0.01
		root.add_child(_clamped)
		return false
	if _frames < 3:
		return false
	if _done:
		return true
	_done = true
	_run_checks()
	if _failures.is_empty():
		print("TARGET_RIG_CHECK: PASS")
		quit(0)
	else:
		printerr("TARGET_RIG_CHECK: FAIL (%d): %s" % [_failures.size(), ", ".join(_failures)])
		quit(1)
	return true


func _new_target(node_name: String, size_name: String, number: String, pos: Vector3) -> TargetRig:
	var target := TargetRig.new()
	target.name = node_name
	target.team = "red"
	target.armor_size = size_name
	target.number = number
	target.position = pos
	return target


func _check(name: String, ok: bool, detail := "") -> void:
	print(("  ok   " if ok else "  FAIL ") + name + ("  " + detail if detail != "" else ""))
	if not ok:
		_failures.append(name)


func _run_checks() -> void:
	# --- default layout -----------------------------------------------------
	var frames := _rig.get_armor_frames()
	_check("four armour modules", frames.size() == 4, str(frames.size()))
	_check("default layout satisfies S120/S121/S124/S125",
		_rig.check_installation().is_empty(), ", ".join(_rig.check_installation()))
	_check("tuned layout satisfies the rules", _tuned.check_installation().is_empty(),
		", ".join(_tuned.check_installation()))

	var suffices: Array[String] = []
	for frame in frames:
		suffices.append(String(frame["suffix"]))
	_check("strike-face frames px/nx/py/ny",
		suffices == ["armor_px", "armor_nx", "armor_py", "armor_ny"], str(suffices))

	# Target centre = midpoint of the lower (X) pair; upper pair above it.
	var lower := Vector3.ZERO
	var upper := Vector3.ZERO
	for frame in frames:
		var center: Vector3 = frame["body_center"]
		if String(frame["group"]) == "x":
			lower += center
		else:
			upper += center
	lower /= 2.0
	upper /= 2.0
	_check("target centre is the lower pair midpoint", lower.length() < 1e-6, str(lower))
	_check("upper pair is directly above the target centre",
		absf(upper.x) < 1e-6 and absf(upper.y) < 1e-6
			and absf(upper.z - TargetRig.DEFAULT_GROUP_HEIGHT_OFFSET_M) < 1e-6, str(upper))

	var center_tf := _rig.get_center_global_transform()
	var drop := ArmorPlate.lower_edge_drop("small")
	_check("target centre height adjustable / on the floor anchor",
		absf(center_tf.origin.y - TargetRig.DEFAULT_CENTER_HEIGHT_M) < 1e-6,
		"y=%.4f" % center_tf.origin.y)
	var expected_edge := TargetRig.DEFAULT_CENTER_HEIGHT_M - drop
	var lower_edges: Array[float] = []
	for frame in frames:
		lower_edges.append(frame["lower_edge_m"])
	_check("lower group edge height matches the armour envelope",
		absf(lower_edges[0] - expected_edge) < 1e-6, "%.4f" % lower_edges[0])
	var edge_min: float = lower_edges.min()
	var edge_max: float = lower_edges.max()
	_check("S124 lower-edge spread equals the group offset",
		absf((edge_max - edge_min) - TargetRig.DEFAULT_GROUP_HEIGHT_OFFSET_M) < 1e-6,
		"%.4f" % (edge_max - edge_min))

	# S120: normal points 15 deg up, projection is the body axis.
	var first_basis: Basis = frames[0]["body_basis"]
	var normal := first_basis.z
	_check("mounting angle 75 deg to the ground",
		absf(rad_to_deg(acos(absf(normal.dot(Vector3(0.0, 0.0, -1.0))))) - 75.0) < 0.01,
		"%.3f deg" % rad_to_deg(acos(absf(normal.dot(Vector3(0.0, 0.0, -1.0))))))
	_check("strike-face normal tilts 15 deg up",
		absf(rad_to_deg(asin(normal.z)) - ArmorPlate.MOUNT_TILT_DEG) < 0.01,
		"%.3f deg" % rad_to_deg(asin(normal.z)))
	var frame_position: Vector3 = frames[0]["body_position"]
	var frame_center: Vector3 = frames[0]["body_center"]
	_check("strike-face centre is on the face plane",
		absf(frame_position.distance_to(frame_center + normal * ArmorPlate.STRIKE_FACE_Z)) < 1e-9)

	# --- adjustable layout (tuned target) ----------------------------------
	var tuned_center := _tuned.get_center_global_transform()
	_check("tuned centre height / yaw applied",
		absf(tuned_center.origin.y - 0.30) < 1e-6
			and absf(angle_difference(tuned_center.basis.get_euler().y, deg_to_rad(30.0))) < 1e-5,
		"y=%.3f yaw=%.2f" % [tuned_center.origin.y,
			rad_to_deg(tuned_center.basis.get_euler().y)])
	var tuned_frames := _tuned.get_armor_frames()
	var y_span := 0.0
	var x_height := 0.0
	for frame in tuned_frames:
		var center: Vector3 = frame["body_center"]
		if String(frame["group"]) == "y":
			y_span = maxf(y_span, absf(center.y) * 2.0)
		else:
			x_height = center.z
	_check("per-group spans are independent", absf(y_span - 0.54) < 1e-6 and absf(x_height - 0.02) < 1e-6,
		"y_span=%.3f x_group_z=%.3f" % [y_span, x_height])
	_check("lower_group='y' puts the Y pair at the target centre",
		absf(y_height_of(tuned_frames, "y")) < 1e-9 and absf(y_height_of(tuned_frames, "x") - 0.02) < 1e-9)

	# Strike-face world pose: target yaw is applied by the rig transform.
	var tuned_basis: Basis = tuned_frames[0]["body_basis"]
	var tuned_position: Vector3 = tuned_frames[0]["body_position"]
	var module_center: Vector3 = tuned_frames[0]["body_center"]
	var plate: Node3D = tuned_frames[0]["plate"]
	var module_world := tuned_center * SimConfig.body_to_godot(module_center)
	var normal_world := (tuned_center.basis * SimConfig.body_to_godot(tuned_basis.z)).normalized()
	var strike_world := module_world + normal_world * ArmorPlate.STRIKE_FACE_Z
	var expected_strike := tuned_center * SimConfig.body_to_godot(tuned_position)
	_check("armour plate follows the rig yaw / span",
		(plate.global_position - module_world).length() < 1e-6,
		"%s vs %s" % [plate.global_position, module_world])
	_check("strike face sits on the rendered plate front",
		(strike_world - expected_strike).length() < 1e-6,
		"%s vs %s" % [strike_world, expected_strike])
	var plate_normal := (plate.global_transform.basis * Vector3(0.0, 0.0, 1.0)).normalized()
	var plate_up := (plate.global_transform.basis * Vector3(0.0, 1.0, 0.0)).normalized()
	var body_up: Vector3 = tuned_basis.y
	var expected_up := (tuned_center.basis * SimConfig.body_to_godot(body_up)).normalized()
	_check("rendered plate orientation matches its strike-face frame",
		plate_normal.dot(normal_world) > 0.99999 and plate_up.dot(expected_up) > 0.99999)

	# --- clamping -----------------------------------------------------------
	_check("out-of-range layout is clamped into a compliant target",
		_clamped.check_installation().is_empty(), ", ".join(_clamped.check_installation()))
	_check("S124 offset clamped to 100 mm",
		absf(_clamped.group_height_offset_m - TargetRig.MAX_GROUP_HEIGHT_OFFSET_M) < 1e-9,
		"%.4f" % _clamped.group_height_offset_m)
	_check("S125 centre height clamped",
		_clamped.center_height_m <= TargetRig.MAX_LOWER_EDGE_HEIGHT_M + drop
			- _clamped.group_height_offset_m + 1e-9,
		"%.4f" % _clamped.center_height_m)
	_check("span clamped to at least one armour width",
		absf(_clamped.x_group_span_m - ArmorPlate.envelope_for("small").x) < 1e-9
			and absf(_clamped.y_group_span_m - ArmorPlate.envelope_for("small").x) < 1e-9)
	_check("invalid lower_group falls back to 'x'", _clamped.lower_group == "x")


func y_height_of(frames: Array[Dictionary], group: String) -> float:
	var total := 0.0
	var count := 0
	for frame in frames:
		if String(frame["group"]) == group:
			var center: Vector3 = frame["body_center"]
			total += center.z
			count += 1
	return total / float(maxi(count, 1))
