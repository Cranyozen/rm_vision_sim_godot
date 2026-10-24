extends SceneTree

## Headless Phase 3 scene check: scenario loading, field switching (1v1 / 3v3 /
## flat), target motion stepping, runtime target count and YAML save/reload.
##
## Usage:
##   godot --headless --path . --script res://tests/phase3_scene_check.gd
## Expects: PHASE3_SCENE: PASS
##
## Main instantiates GLB scenes, so it is built in _process after the first
## frame (never in _initialize) to avoid the Godot 4.7.2 headless GLB crash.

var _main
var _failures: Array[String] = []
var _frame := 0
var _done := false


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 2:
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		return false
	if _frame < 4 or _done:
		return _done
	_done = true
	_run_checks()
	if _failures.is_empty():
		print("PHASE3_SCENE: PASS")
		quit(0)
	else:
		printerr("PHASE3_SCENE: FAIL (%d): %s" % [_failures.size(), ", ".join(_failures)])
		quit(1)
	return true


func _send_key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _check(name: String, ok: bool, detail := "") -> void:
	print(("  ok   " if ok else "  FAIL ") + name + ("  " + detail if detail != "" else ""))
	if not ok:
		_failures.append(name)


func _run_checks() -> void:
	_check("Main built", _main != null and _main._controller != null)

	# --- default scenario ---------------------------------------------------
	_check("startup scenario is 1v1_static",
		_main._scenario_path.ends_with("1v1_static.yaml"), _main._scenario_path)
	_check("field is 1v1", _main._field_id == "rmul2027_1v1", _main._field_id)
	_check("four targets from YAML", _main._targets.size() == 4, str(_main._targets.size()))
	_check("static targets report not moving",
		not _main._targets[0].is_moving() and not _main._targets[3].is_moving())
	_check("ego placed at the scenario pose",
		_main._controller.chassis_position.distance_to(Vector3(0.0, 0.0, 2.2)) < 1e-3,
		str(_main._controller.chassis_position))

	# --- motion scenario ----------------------------------------------------
	_main._apply_scenario_path("res://scenarios/1v1_line.yaml")
	_check("1v1_line loaded", _main._scenario_path.ends_with("1v1_line.yaml"))
	_check("1v1_line field is 1v1", _main._field_id == "rmul2027_1v1")
	_check("1v1_line has three targets", _main._targets.size() == 3, str(_main._targets.size()))
	var moving := 0
	for target in _main._targets:
		if target.is_moving():
			moving += 1
	_check("two moving targets (line pingpong + line loop)", moving == 2, str(moving))

	var mover = null
	for target in _main._targets:
		if target.is_moving():
			mover = target
			break
	_main._sim_time = 0.0
	_main._step_target_motion()
	var at_start: Vector3 = mover.global_position
	_main._sim_time = 2.0
	_main._step_target_motion()
	var at_two: Vector3 = mover.global_position
	_main._sim_time = 1.0
	_main._step_target_motion()
	var at_one: Vector3 = mover.global_position
	_check("line target moves between t=0 and t=2", at_start.distance_to(at_two) > 0.5,
		"%.2f m" % at_start.distance_to(at_two))
	_check("line target passes the midpoint at t=1",
		at_start.distance_to(at_one) > 0.2 and at_two.distance_to(at_one) > 0.2)

	# --- 3v3 field ----------------------------------------------------------
	_main._apply_scenario_path("res://scenarios/3v3_spin.yaml")
	_check("3v3_spin loaded", _main._field_id == "rmul2027_3v3", _main._field_id)
	_check("3v3 field node shifted by -0.10 m",
		absf(_main._field_node.position.y - SimConfig.FIELD_3V3_Y_OFFSET) < 1e-4,
		"y=%.3f" % _main._field_node.position.y)
	_check("3v3 collision exists", _main._field_collision != null)
	_check("3v3 has four targets", _main._targets.size() == 4, str(_main._targets.size()))
	var spin_moving := 0
	for target in _main._targets:
		if target.is_moving():
			spin_moving += 1
	_check("3v3 has three spinning targets", spin_moving == 3, str(spin_moving))
	_main._controller.place(Vector3(0.0, 0.0, 99.0), 0.0)
	_check("3v3 chassis clamp keeps ego inside the field",
		_main._controller.chassis_position.z <= 3.7001,
		"z=%.2f" % _main._controller.chassis_position.z)

	# --- flat field ---------------------------------------------------------
	_main._apply_scenario_path("res://scenarios/flat_range.yaml")
	_check("flat_range loaded", _main._field_id == "flat", _main._field_id)
	_check("flat field has a generated floor",
		_main._field_node.find_child("FlatFloor", true, false) != null)
	var flat_moving := 0
	for target in _main._targets:
		if target.is_moving():
			flat_moving += 1
	_check("flat_range has three moving targets", flat_moving == 3, str(flat_moving))
	_main._controller.place(Vector3(0.0, 0.0, 99.0), 0.0)
	_check("flat chassis clamp keeps ego inside the 20x20 field",
		_main._controller.chassis_position.z <= 9.7001,
		"z=%.2f" % _main._controller.chassis_position.z)

	# --- target count override ---------------------------------------------
	_main._set_target_count(6)
	_check("target count override grows the target set", _main._targets.size() == 6,
		str(_main._targets.size()))
	_main._set_target_count(2)
	_check("target count override shrinks the target set", _main._targets.size() == 2,
		str(_main._targets.size()))

	# --- save + reload ------------------------------------------------------
	_main._apply_scenario_path("res://scenarios/1v1_line.yaml")
	_main._apply_motion_settings({
		"type": "polyline", "mode": "loop", "speed": 1.5, "spin_deg_s": 45.0,
	})
	_main._save_scenario()
	var saved_scenario_path: String = _main._scenario_path
	_check("UI save wrote a YAML scenario", saved_scenario_path.begins_with("user://scenarios/"),
		saved_scenario_path)
	var reloaded := ScenarioStore.load_scenario(saved_scenario_path)
	_check("saved YAML validates and reloads", reloaded.get("ok", false),
		"; ".join(PackedStringArray(reloaded.get("errors", []))))
	if reloaded.get("ok", false):
		_check("saved motion type survives the round trip",
			String(reloaded["data"]["targets"][0]["motion"]["type"]) == "polyline")
		_check("saved target count survives the round trip",
			(reloaded["data"]["targets"] as Array).size() == 3)

	# --- camera preset / publish / panel wiring -----------------------------
	_main._apply_camera_preset("cad")
	_check("camera preset cad switches the mount",
		_main._ego.camera_mount_preset == "cam_direction",
		_main._ego.camera_mount_preset)
	_main._apply_camera_preset("qyg")
	_check("camera preset qyg restores the gimbal mount",
		_main._ego.camera_mount_preset == "gimbal",
		_main._ego.camera_mount_preset)
	_main._scenario["camera"]["yaw_offset_deg"] = 3.7
	_main._apply_camera_preset("qyg_trim")
	_check("qyg_trim applies the scenario yaw trim",
		is_equal_approx(_main._ego.camera_yaw_offset_deg, 3.7),
		"%.1f" % _main._ego.camera_yaw_offset_deg)
	_main._apply_camera_preset("qyg")
	_check("qyg ignores the scenario yaw trim",
		is_equal_approx(_main._ego.camera_yaw_offset_deg, 0.0),
		"%.1f" % _main._ego.camera_yaw_offset_deg)
	_main._on_panel_publish_toggled(false)
	_check("panel ROS publish toggle pauses the backend",
		_main._ros != null and not _main._ros.enabled)
	_main._on_panel_publish_toggled(true)
	_check("panel ROS publish toggle resumes the backend",
		_main._ros != null and _main._ros.enabled)
	_main._set_scenario_panel_open(true)
	_check("scenario panel opens", _main._scenario_panel.is_open() and _main._panel_open)
	_check("panel state exposes scenario/field/motion",
		String(_main._panel_state().get("scenario_name", "")) != ""
		and String(_main._panel_state().get("field", "")) != ""
		and String(_main._panel_state().get("motion_summary", "")) != "")
	_main._set_scenario_panel_open(false)
	_check("scenario panel closes", not _main._scenario_panel.is_open() and not _main._panel_open)
	_main._set_scenario_panel_open(true)
	_main._scenario_panel.set_open(false)  # simulate the panel CLOSE button
	_main._sync_panel_state()
	_check("CLOSE button syncs Main's panel/input state",
		not _main._panel_open and not _main._scenario_panel.is_open())

	# --- keyboard shortcuts (Tab / F8 / F9) via synthetic input -------------
	_send_key(KEY_TAB)
	_check("Tab opens the scenario panel", _main._panel_open and _main._scenario_panel.is_open())
	_send_key(KEY_TAB)
	_check("Tab closes the scenario panel", not _main._panel_open)
	var before_cycle: String = _main._scenario_path
	_send_key(KEY_F9)
	_check("F9 cycles to another scenario", _main._scenario_path != before_cycle,
		"%s -> %s" % [before_cycle, _main._scenario_path])
	var cycled: String = _main._scenario_path
	_send_key(KEY_F8)
	_check("F8 reloads the current scenario", _main._scenario_path == cycled)

	# --- scenario cycling ---------------------------------------------------
	_main._cycle_scenario()
	_check("F9-style cycling selects another scenario",
		_main._scenario_path != "" and _main._scenario_path.ends_with(".yaml"))

	# Do not leave the generated user:// scenario behind for real runs.
	if saved_scenario_path.begins_with("user://"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(saved_scenario_path))
