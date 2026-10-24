extends Node3D

## Phase 3 entry point.
##
## Phase 1/2 features stay intact (1v1 field, four-armour targets, ego rig,
## 1280x1024 feed, operator/free cameras, optional rclgd ROS backend) and Phase 3
## adds:
## - scenario-driven worlds: field / ego / targets / camera / ROS settings are
##   read from YAML (ScenarioStore + ScenarioSchema) instead of hard-coded;
## - target motion (line / polyline / spin, once / loop / pingpong) stepped from
##   a deterministic simulation clock;
## - runtime scenario reload / switch, 1v1 / 3v3 / flat field switching, a UI
##   scenario panel and YAML save.
##
## Construction order matters: cameras exist before the world so the scenario's
## camera preset (FPV FOV) can be applied while building the ego, and the ROS
## backend starts last because it binds the final ego/targets.

const EGO_SCENE := preload("res://scenes/ego/EgoRig.tscn")
const HUD_SCENE := preload("res://scenes/ui/HUD.tscn")
## Phase 1 fallback ego start; scenarios normally override it.
const EGO_START := Vector3(0.0, 0.0, 2.2)

var _ego: EgoRig
var _controller: EgoController
var _feed_viewport: SubViewport
var _feed_camera: Camera3D
var _debug_camera: Camera3D
var _fpv_camera: Camera3D
var _fpv_mode := false
var _free_camera: Camera3D
var _free_camera_mode := false
var _free_cam_yaw := 0.0
var _free_cam_pitch := 0.0
var _free_speed := 4.0
var _hud: HUD
var _scenario_panel: ScenarioPanel
var _targets: Array[TargetRig] = []
var _ros: RosBackend

var _self_fpv := false
var _stat_timer := 0.0
var _smoothed_frame_ms := 0.0
var _fps := 0.0
var _fps_accum := 0.0
var _fps_frames := 0

# --- Phase 3 scenario state -------------------------------------------------
var _scenario: Dictionary = {}
var _scenario_path := ""
## Normalized target specs from the scenario (used to rebuild targets when the
## UI changes the target count, and as the template for YAML save).
var _target_specs: Array = []
var _field_id := SimConfig.FIELD_1V1
var _field_node: Node3D
var _field_collision: StaticBody3D
var _ego_start := EGO_START
var _ego_start_yaw := 0.0
var _camera_preset := "qyg"
var _sim_time := 0.0
var _panel_open := false
var _last_scenario_error := ""


func _ready() -> void:
	# UI language first: everything built below picks its locale from
	# TranslationServer (saved choice, else the OS locale).
	I18n.install()
	I18n.apply_startup_locale()
	_build_environment()
	_build_feed()
	_build_debug_camera()
	_build_fpv_camera()
	_load_startup_scenario()
	_build_hud()
	_build_scenario_panel()
	_sync_cameras()
	_build_ros()
	_update_stats()


func _process(delta: float) -> void:
	# Target motion runs on a deterministic clock, independent of which camera
	# owns the input. Scenarios restart it at 0 on load / F5 so results repeat.
	_sim_time += delta
	_step_target_motion()
	_sync_panel_state()

	if _free_camera_mode:
		_update_free_camera(delta)
	else:
		if not _panel_open:
			_update_operator(delta)
			if _ros != null:
				_ros.apply_commands(delta)
			_controller.step(delta)
		elif _controller != null:
			_controller.step(0.0)

	_sync_cameras()
	if _ros != null:
		_ros.process(delta)
	_smoothed_frame_ms = lerpf(_smoothed_frame_ms, delta * 1000.0, 0.10)
	_fps_accum += delta
	_fps_frames += 1
	if _fps_accum >= 0.25:
		_fps = float(_fps_frames) / _fps_accum
		_fps_accum = 0.0
		_fps_frames = 0
	_stat_timer += delta
	if _stat_timer >= 0.2:
		_stat_timer = 0.0
		_update_stats()


func _unhandled_input(event: InputEvent) -> void:
	# F10 toggles the UI language and must keep working while the scenario panel
	# owns input, so it is matched before the panel gate below.
	if event is InputEventKey:
		var lang_key := event as InputEventKey
		if lang_key.pressed and not lang_key.echo and lang_key.keycode == KEY_F10:
			_toggle_ui_locale()
			return

	# While the scenario panel is open it owns the pointer; only Tab / Escape
	# are handled here.
	if _panel_open:
		if event is InputEventKey:
			var panel_key := event as InputEventKey
			if panel_key.pressed and not panel_key.echo:
				if panel_key.keycode == KEY_TAB:
					_toggle_scenario_panel()
					return
				if panel_key.keycode == KEY_ESCAPE:
					_toggle_scenario_panel()
					return
		return

	if _free_camera_mode:
		if event is InputEventMouseMotion:
			var motion := event as InputEventMouseMotion
			_free_cam_yaw -= motion.relative.x * SimConfig.MOUSE_SENS_RAD_PER_PX
			_free_cam_pitch = clampf(_free_cam_pitch - motion.relative.y * SimConfig.MOUSE_SENS_RAD_PER_PX, -1.55, 1.55)
			return
		if event is InputEventMouseButton and event.pressed:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_free_speed = clampf(_free_speed * 1.15, 0.5, 30.0)
				return
			if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_free_speed = clampf(_free_speed / 1.15, 0.5, 30.0)
				return

	if _fpv_mode and event is InputEventMouseMotion:
		_controller.apply_mouse_look((event as InputEventMouseMotion).relative)
		return

	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_F1:
			_hud.toggle_feed_fullscreen()
		KEY_F2:
			_self_fpv = not _self_fpv
			_feed_camera.cull_mask = 3 if _self_fpv else 1
		KEY_F3:
			if not _free_camera_mode:
				_set_fpv_mode(not _fpv_mode)
		KEY_F4:
			_set_free_camera(not _free_camera_mode)
		KEY_F5:
			_reset_pose()
		KEY_F6:
			if _ros != null and _ros.available:
				_ros.toggle_enabled()
				_update_stats()
		KEY_F8:
			_reload_scenario()
		KEY_F9:
			_cycle_scenario()
		KEY_TAB:
			_toggle_scenario_panel()
		KEY_C:
			if not _free_camera_mode:
				_controller.follow_gimbal = not _controller.follow_gimbal
				_update_stats()
		KEY_ESCAPE:
			if _free_camera_mode:
				_set_free_camera(false)
			elif _fpv_mode:
				_set_fpv_mode(false)
			elif _hud.is_feed_fullscreen():
				_hud.close_feed_fullscreen()
			else:
				get_tree().quit()


## Operator input. Gimbal: Q/E yaw, R/F pitch, mouse look in FPV mode.
## Chassis: W/S forward/back, A/D strafe (mecanum), Shift boost. The chassis
## always drives unless the free camera owns the keyboard or the UI panel is
## open.
func _update_operator(delta: float) -> void:
	var yaw_dir := 0.0
	if Input.is_key_pressed(KEY_Q):
		yaw_dir -= 1.0
	if Input.is_key_pressed(KEY_E):
		yaw_dir += 1.0
	if yaw_dir != 0.0:
		_controller.add_gimbal_yaw(yaw_dir * SimConfig.GIMBAL_YAW_SPEED_DPS * delta)

	var pitch_dir := 0.0
	if Input.is_key_pressed(KEY_R):
		pitch_dir += 1.0
	if Input.is_key_pressed(KEY_F):
		pitch_dir -= 1.0
	if pitch_dir != 0.0:
		_controller.add_gimbal_pitch(pitch_dir * SimConfig.GIMBAL_PITCH_SPEED_DPS * delta)

	var forward := 0.0
	if Input.is_key_pressed(KEY_W):
		forward += 1.0
	if Input.is_key_pressed(KEY_S):
		forward -= 1.0
	var strafe := 0.0
	if Input.is_key_pressed(KEY_D):
		strafe += 1.0
	if Input.is_key_pressed(KEY_A):
		strafe -= 1.0
	_controller.move_chassis(forward, strafe, Input.is_key_pressed(KEY_SHIFT), delta)


## F5: back to the scenario's ego start pose and restart target motion (the
## deterministic clock makes scenario playback repeatable).
func _reset_pose() -> void:
	_set_free_camera(false)
	_fpv_mode = false
	if _fpv_camera != null:
		_fpv_camera.current = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_sim_time = 0.0
	if _controller != null:
		_controller.place(_ego_start, _ego_start_yaw)
	_step_target_motion()
	_self_fpv = false
	_debug_camera.current = true
	_feed_camera.cull_mask = 1
	_sync_cameras()
	_update_stats()


func _sync_cameras() -> void:
	if _ego == null:
		return
	var mount := _ego.get_camera_mount()
	if mount == null:
		return
	_feed_camera.global_transform = mount.global_transform
	if _free_camera_mode:
		return
	if _fpv_mode:
		_fpv_camera.global_transform = mount.global_transform
		return
	var target := _ego.global_position + Vector3(0.0, 0.30, 0.0)
	_debug_camera.global_position = target + Vector3(0.0, 1.55, 2.65)
	_debug_camera.look_at(target, Vector3.UP)


func _view_name() -> String:
	if _free_camera_mode:
		return I18n.t("FREE CAMERA")
	if _fpv_mode:
		return I18n.t("OPERATOR FPV")
	return I18n.t("THIRD-PERSON")


## F10: cycle the UI language, then re-localize every UI surface.
func _toggle_ui_locale() -> void:
	I18n.toggle_locale()
	_retranslate_ui()


## Re-localize the HUD and the scenario panel after a locale change.  The HUD
## owns its own texts (HUD.retranslate(), handled defensively so a HUD built
## before that method exists still works); the panel follows the "locale" state
## key.  Diagnostic print()/push_warning() text stays English on purpose.
func _retranslate_ui() -> void:
	if _hud != null and _hud.has_method("retranslate"):
		_hud.retranslate()
	if _scenario_panel != null:
		_scenario_panel.update_state(_panel_state())
	_update_stats()


## Language picked in the scenario panel: apply (and persist) it, then refresh
## the HUD / panel / stats readouts.
func _on_panel_language_changed(locale: String) -> void:
	I18n.set_locale(locale)
	_retranslate_ui()


func _update_stats() -> void:
	if _controller == null or _hud == null:
		return
	_hud.set_stats(_fps, _smoothed_frame_ms,
		_controller.gimbal_yaw_deg, _controller.gimbal_pitch_deg,
		_self_fpv, _free_camera_mode, _free_speed,
		_controller.chassis_position, _controller.chassis_speed_mps,
		_controller.follow_gimbal, _view_name(), _ros_status(),
		_scenario_name(), FieldRegistry.label(_field_id), _targets.size())
	if _scenario_panel != null:
		_scenario_panel.update_state(_panel_state())


func _ros_status() -> String:
	if _ros == null:
		return I18n.t("ROS: not started")
	return _ros.get_status_line()


func _exit_tree() -> void:
	if _ros != null:
		_ros.shutdown()


## First-person operator camera: wide FOV on the gimbal mount, mouse captured
## for aiming. Independent of the 17.2 deg vision feed.
func _set_fpv_mode(enabled: bool) -> void:
	if enabled == _fpv_mode:
		return
	_fpv_mode = enabled
	if enabled:
		_fpv_camera.current = true
		if not _panel_open:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_debug_camera.current = true
	_sync_cameras()
	_update_stats()


func _set_free_camera(enabled: bool) -> void:
	if enabled == _free_camera_mode:
		return
	_free_camera_mode = enabled
	if enabled:
		if _fpv_mode:
			_fpv_mode = false
			_fpv_camera.current = false
		if _free_camera == null:
			_build_free_camera()
		_free_camera.global_transform = _debug_camera.global_transform
		_free_cam_yaw = _free_camera.rotation.y
		_free_cam_pitch = clampf(_free_camera.rotation.x, -1.55, 1.55)
		_free_camera.current = true
		if not _panel_open:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_debug_camera.current = true
	_update_stats()


func _update_free_camera(delta: float) -> void:
	var basis := _free_camera.global_transform.basis
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move -= basis.z
	if Input.is_key_pressed(KEY_S):
		move += basis.z
	if Input.is_key_pressed(KEY_A):
		move -= basis.x
	if Input.is_key_pressed(KEY_D):
		move += basis.x
	move.y = 0.0
	if move.length_squared() > 0.0:
		move = move.normalized()
	if Input.is_key_pressed(KEY_E):
		move.y += 1.0
	if Input.is_key_pressed(KEY_F):
		move.y -= 1.0
	if move.length_squared() > 0.0:
		move = move.normalized()
		var speed := _free_speed * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		_free_camera.global_position += move * speed * delta
	_free_camera.rotation = Vector3(_free_cam_pitch, _free_cam_yaw, 0.0)


# --- scenario lifecycle -----------------------------------------------------

func _load_startup_scenario() -> void:
	var path := ScenarioStore.startup_scenario_path()
	var result := ScenarioStore.load_scenario(path)
	if result.get("ok", false):
		_scenario = result["data"]
		_scenario_path = path
		_report_scenario_messages(result)
	else:
		_last_scenario_error = "; ".join(PackedStringArray(result.get("errors", [])))
		push_warning("Main: scenario '%s' is invalid (%s); using the Phase 1 fallback world"
			% [path, _last_scenario_error])
		_scenario = _fallback_scenario()
		_scenario_path = ""
	_build_world(_scenario)


## Load a scenario file and rebuild the world in place (UI / F8 / F9).
func _apply_scenario_path(path: String) -> void:
	var result := ScenarioStore.load_scenario(path)
	if not result.get("ok", false):
		_last_scenario_error = "; ".join(PackedStringArray(result.get("errors", [])))
		push_warning("Main: cannot load scenario '%s': %s" % [path, _last_scenario_error])
		if _scenario_panel != null:
			_scenario_panel.update_state(_panel_state())
		return
	_report_scenario_messages(result)
	_scenario = result["data"]
	_scenario_path = path
	_last_scenario_error = ""
	_build_world(_scenario)
	_rebind_ros()
	_refresh_scenario_list()
	_update_stats()


func _reload_scenario() -> void:
	if _scenario_path == "":
		return
	_apply_scenario_path(_scenario_path)


func _cycle_scenario() -> void:
	var paths := ScenarioStore.list_scenarios()
	if paths.is_empty():
		return
	var index := paths.find(_scenario_path)
	index = (index + 1) % paths.size()
	_apply_scenario_path(paths[index])


## Build (or rebuild) the whole simulated world from normalized scenario data.
func _build_world(data: Dictionary) -> void:
	_clear_world()
	_sim_time = 0.0
	_scenario = data
	_field_id = String(data.get("field", SimConfig.FIELD_1V1))
	if not FieldRegistry.is_valid(_field_id):
		push_warning("Main: unknown field '%s'; using 1v1" % _field_id)
		_field_id = SimConfig.FIELD_1V1

	var camera: Dictionary = data.get("camera", {})
	_camera_preset = String(camera.get("preset", "qyg"))
	if not SimConfig.CAMERA_PRESETS.has(_camera_preset):
		push_warning("Main: unknown camera preset '%s'; using qyg" % _camera_preset)
		_camera_preset = "qyg"

	_build_field()
	_spawn_ego_from_scenario(data)
	_target_specs = []
	for spec in data.get("targets", []):
		_target_specs.append((spec as Dictionary).duplicate(true))
	_build_targets(_target_specs)
	_apply_camera_preset(_camera_preset)


func _clear_world() -> void:
	for target in _targets:
		if is_instance_valid(target):
			target.queue_free()
	_targets.clear()
	if _field_node != null and is_instance_valid(_field_node):
		_field_node.queue_free()
	_field_node = null
	if _field_collision != null and is_instance_valid(_field_collision):
		_field_collision.queue_free()
	_field_collision = null
	if _ego != null and is_instance_valid(_ego):
		_ego.queue_free()
	_ego = null
	_controller = null


func _build_field() -> void:
	_field_node = FieldRegistry.build_visual(_field_id)
	_field_node.name = "Field_%s" % _field_id
	add_child(_field_node)
	_field_collision = FieldRegistry.build_collision(_field_id)
	add_child(_field_collision)


func _spawn_ego_from_scenario(data: Dictionary) -> void:
	var ego_cfg: Dictionary = data.get("ego", {})
	var position := _vec3(ego_cfg.get("position", [EGO_START.x, 0.0, EGO_START.z]), EGO_START)
	position.y = 0.0
	_ego_start = position
	_ego_start_yaw = float(ego_cfg.get("yaw_deg", 0.0))

	_ego = EGO_SCENE.instantiate() as EgoRig
	_ego.name = "Ego"
	_ego.preset = String(ego_cfg.get("model", "vehicle"))
	_ego.camera_mount_preset = String(SimConfig.CAMERA_PRESETS[_camera_preset])
	_ego.camera_yaw_offset_deg = _camera_yaw_offset()
	_ego.position = position
	add_child(_ego)

	_controller = EgoController.new(_ego, position)
	_controller.set_field_bounds(FieldRegistry.get_spec(_field_id)["half_extents"])
	_controller.place(position, _ego_start_yaw)

	if _fpv_camera != null:
		_fpv_camera.fov = float(data.get("camera", {}).get("fpv_fov_deg", SimConfig.FPV_FOV_DEG))


func _build_targets(specs: Array) -> void:
	for target in _targets:
		if is_instance_valid(target):
			target.queue_free()
	_targets.clear()
	for i in specs.size():
		_add_target_from_spec(specs[i] as Dictionary, i)


func _add_target_from_spec(spec: Dictionary, index: int) -> void:
	var target := TargetRig.new()
	var team := String(spec.get("team", "red"))
	var number := String(spec.get("number", str(index + 1)))
	target.name = "Target_%s_%s_%d" % [team, number, index]
	target.team = team
	target.armor_size = String(spec.get("armor", "small"))
	target.number = number
	target.yaw_deg = float(spec.get("yaw_deg", 0.0))
	var position := _vec3(spec.get("position", [0.0, 0.0, -1.4]), Vector3(0.0, 0.0, -1.4))
	position.y = 0.0
	target.position = position

	var layout: Dictionary = spec.get("armor_layout", {})
	target.center_height_m = float(layout.get("center_height_m", TargetRig.DEFAULT_CENTER_HEIGHT_M))
	target.group_height_offset_m = float(layout.get("group_height_offset_m",
		TargetRig.DEFAULT_GROUP_HEIGHT_OFFSET_M))
	target.x_group_span_m = float(layout.get("x_group_span_m", 0.0))
	target.y_group_span_m = float(layout.get("y_group_span_m", 0.0))
	target.lower_group = String(layout.get("lower_group", "x"))

	var motion_cfg: Dictionary = spec.get("motion", {})
	if String(motion_cfg.get("type", "static")) != "static":
		target.motion = TargetMotion.from_config(motion_cfg, position, target.yaw_deg)

	add_child(target)
	_targets.append(target)


## Advance every target's motion from the deterministic simulation clock.
func _step_target_motion() -> void:
	for target in _targets:
		if is_instance_valid(target):
			target.step_motion(_sim_time)


func _rebind_ros() -> void:
	if _ros == null:
		return
	_ros.bind_robot(_ego, _controller)
	_ros.set_targets(_targets)
	_ros.apply_scenario(_scenario.get("ros", {}))


# --- UI: scenario panel ------------------------------------------------------

func _build_scenario_panel() -> void:
	_scenario_panel = ScenarioPanel.new()
	_scenario_panel.name = "ScenarioPanel"
	_hud.attach_scenario_panel(_scenario_panel)
	_scenario_panel.setup(ScenarioStore.list_scenarios(), _scenario_path, _panel_state())
	_scenario_panel.scenario_load_requested.connect(_on_panel_scenario_load)
	_scenario_panel.reload_requested.connect(_on_panel_reload)
	_scenario_panel.motion_apply_requested.connect(_on_panel_motion_apply)
	_scenario_panel.camera_preset_changed.connect(_on_panel_camera_preset)
	_scenario_panel.publish_toggled.connect(_on_panel_publish_toggled)
	_scenario_panel.target_count_changed.connect(_on_panel_target_count)
	_scenario_panel.save_requested.connect(_on_panel_save)
	_scenario_panel.language_changed.connect(_on_panel_language_changed)


## The panel's own CLOSE button only hides the panel; sync Main's input/mouse
## state so closing it that way does not leave the operator input paused.
func _sync_panel_state() -> void:
	if _panel_open and _scenario_panel != null and not _scenario_panel.is_open():
		_set_scenario_panel_open(false)


func _toggle_scenario_panel() -> void:
	if _scenario_panel == null:
		return
	_set_scenario_panel_open(not _scenario_panel.is_open())


func _set_scenario_panel_open(open: bool) -> void:
	_panel_open = open
	_scenario_panel.set_open(open)
	if open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif _fpv_mode or _free_camera_mode:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _scenario_panel.is_open():
		_scenario_panel.update_state(_panel_state())


func _on_panel_scenario_load(path: String) -> void:
	_apply_scenario_path(path)


func _on_panel_reload() -> void:
	_reload_scenario()


func _on_panel_camera_preset(preset: String) -> void:
	_apply_camera_preset(preset)


func _on_panel_publish_toggled(enabled: bool) -> void:
	if _ros != null:
		_ros.set_enabled(enabled)
	_update_stats()


func _on_panel_target_count(count: int) -> void:
	_set_target_count(count)


func _on_panel_motion_apply(settings: Dictionary) -> void:
	_apply_motion_settings(settings)


func _on_panel_save() -> void:
	_save_scenario()


## Apply a camera preset ("qyg" | "cad" | "qyg_trim"). The mount preset and the
## scenario's yaw trim are pushed into the whole ego rig rebuild only when the
## mount preset actually changes (EgoRig.set_camera_mount is otherwise live).
func _apply_camera_preset(preset: String) -> void:
	if not SimConfig.CAMERA_PRESETS.has(preset):
		push_warning("Main: unknown camera preset '%s'" % preset)
		return
	_camera_preset = preset
	if _ego == null:
		return
	var mount_preset := String(SimConfig.CAMERA_PRESETS[preset])
	var yaw_offset := _camera_yaw_offset()
	if _ego.camera_mount_preset != mount_preset:
		# The mount transform is derived from the model's CAM_DIRECTION node,
		# so it can be rebuilt without touching the rest of the rig.
		_ego.set_camera_mount(mount_preset, yaw_offset)
	else:
		_ego.camera_yaw_offset_deg = yaw_offset
		_ego.set_camera_mount(mount_preset, yaw_offset)
	_update_stats()


## Camera yaw trim for the active preset: only "qyg_trim" applies the
## scenario's `camera.yaw_offset_deg`; "qyg" is the calibrated zero-offset mount
## and "cad" uses the model's own CAM_DIRECTION pose (its own 3.7 deg yaw).
func _camera_yaw_offset() -> float:
	if _camera_preset != "qyg_trim":
		return 0.0
	return float(_scenario.get("camera", {}).get("yaw_offset_deg", 0.0))


func _set_target_count(count: int) -> void:
	count = clampi(count, 1, 12)
	var specs: Array = []
	for i in count:
		if i < _target_specs.size():
			specs.append((_target_specs[i] as Dictionary).duplicate(true))
		else:
			specs.append(_generated_target_spec(i))
	_build_targets(specs)
	_sim_time = 0.0
	_step_target_motion()
	if _ros != null:
		_ros.set_targets(_targets)
	_update_stats()


## A sensible fallback target for UI target-count increases: alternating teams,
## small armour, laid out in a row behind the field centre.
func _generated_target_spec(index: int) -> Dictionary:
	var limit := FieldRegistry.chassis_limit(_field_id)
	var x := clampf(-1.5 + 0.9 * float(index), -limit.x + 0.5, limit.x - 0.5)
	var z := clampf(-1.4 - 0.4 * float(index / 4), -limit.y + 0.5, limit.y - 0.5)
	return {
		"id": "ui_%d" % (index + 1),
		"team": "red" if index % 2 == 0 else "blue",
		"armor": "small",
		"number": str((index % 9) + 1),
		"position": [x, 0.0, z],
		"yaw_deg": 180.0,
		"armor_layout": {
			"center_height_m": TargetRig.DEFAULT_CENTER_HEIGHT_M,
			"group_height_offset_m": TargetRig.DEFAULT_GROUP_HEIGHT_OFFSET_M,
			"x_group_span_m": 0.0,
			"y_group_span_m": 0.0,
			"lower_group": "x",
		},
		"motion": _motion_config("static", "once", 1.0, 90.0, []),
	}


## Apply the UI motion overrides to every target. Static targets get a short
## generated line path when switched to a path motion, so the change is
## immediately visible. The simulation clock restarts so all motions stay
## deterministic.
func _apply_motion_settings(settings: Dictionary) -> void:
	var type := String(settings.get("type", "static"))
	var mode := String(settings.get("mode", "once"))
	var speed := float(settings.get("speed", 1.0))
	var spin := float(settings.get("spin_deg_s", 90.0))
	for target in _targets:
		if not is_instance_valid(target):
			continue
		var waypoints: Array = []
		if target.motion != null:
			waypoints = _waypoints_to_arrays(target.motion.waypoints)
		if type == "line" and waypoints.size() < 2:
			waypoints = _generated_path(target)
		elif type == "polyline" and waypoints.size() < 3:
			waypoints = _generated_path(target)
		if type == "spin":
			waypoints = []
		var cfg := _motion_config(type, mode, speed, spin, waypoints)
		if type == "static":
			target.motion = null
		else:
			target.motion = TargetMotion.from_config(cfg, target.position, target.yaw_deg)
	_sim_time = 0.0
	_step_target_motion()
	_update_stats()


func _generated_path(target: TargetRig) -> Array:
	var limit := FieldRegistry.chassis_limit(_field_id)
	var p := target.position
	var end_x := clampf(p.x + 1.5, -limit.x + 0.5, limit.x - 0.5)
	return [
		[p.x, 0.0, p.z],
		[end_x, 0.0, p.z],
	]


func _motion_config(type: String, mode: String, speed: float, spin_deg_s: float,
		waypoints: Array) -> Dictionary:
	return {
		"type": type,
		"mode": mode,
		"speed": speed,
		"spin_deg_s": spin_deg_s,
		"waypoints": waypoints,
	}


func _waypoints_to_arrays(points: Array) -> Array:
	var out: Array = []
	for point in points:
		var v: Vector3 = point
		out.append([v.x, 0.0, v.z])
	return out


## Serialize the current world into a scenario dictionary and write it to
## user://scenarios/<name>_edited.yaml (deterministic YamlWriter output).
func _save_scenario() -> void:
	var data := _current_scenario_data()
	var base_name := ScenarioStore.display_name(_scenario_path) if _scenario_path != "" \
		else String(_scenario.get("name", "scenario"))
	var path := ScenarioStore.USER_SCENARIO_DIR.path_join(base_name + "_edited.yaml")
	var result := ScenarioStore.save_scenario(path, data)
	if result.get("ok", false):
		_scenario_path = path
		_scenario = data
		_last_scenario_error = ""
		_refresh_scenario_list()
		print("Main: scenario saved to %s" % path)
	else:
		_last_scenario_error = String(result.get("error", "save failed"))
		push_warning("Main: scenario save failed: %s" % _last_scenario_error)
	_update_stats()


func _current_scenario_data() -> Dictionary:
	var data: Dictionary = _scenario.duplicate(true)
	data["name"] = ScenarioStore.display_name(_scenario_path) if _scenario_path != "" \
		else String(_scenario.get("name", "scenario"))
	var target_specs: Array = []
	for i in _targets.size():
		var spec: Dictionary = (_target_specs[i] as Dictionary).duplicate(true) \
			if i < _target_specs.size() else _generated_target_spec(i)
		var target := _targets[i]
		var motion_cfg: Dictionary
		if target.motion != null:
			motion_cfg = _motion_config(target.motion.type, target.motion.mode,
				target.motion.speed, target.motion.spin_deg_s,
				_waypoints_to_arrays(target.motion.waypoints))
		else:
			motion_cfg = _motion_config("static", "once", 1.0, 90.0, [])
		spec["motion"] = motion_cfg
		spec["position"] = [target.position.x, 0.0, target.position.z]
		spec["yaw_deg"] = rad_to_deg(target.rotation.y)
		target_specs.append(spec)
	data["targets"] = target_specs
	data["camera"] = (data.get("camera", {}) as Dictionary).duplicate(true)
	data["camera"]["preset"] = _camera_preset
	data["ros"] = (data.get("ros", {}) as Dictionary).duplicate(true)
	if _ros != null:
		data["ros"]["enabled"] = _ros.enabled
	return data


func _refresh_scenario_list() -> void:
	if _scenario_panel == null:
		return
	_scenario_panel.setup(ScenarioStore.list_scenarios(), _scenario_path, _panel_state())


func _panel_state() -> Dictionary:
	return {
		"scenario_path": _scenario_path,
		"scenario_name": _scenario_name(),
		"field": FieldRegistry.label(_field_id),
		"target_count": _targets.size(),
		"motion_summary": _motion_summary(),
		"camera_preset": _camera_preset,
		"ros_enabled": _ros != null and _ros.enabled,
		"ros_available": _ros != null and _ros.available,
		"ros_status": _ros_status(),
		"fps": _fps,
		"frame_ms": _smoothed_frame_ms,
		"error": _last_scenario_error,
		"locale": I18n.get_locale(),
	}


func _scenario_name() -> String:
	if _scenario_path != "":
		return ScenarioStore.display_name(_scenario_path)
	return String(_scenario.get("name", "fallback"))


func _motion_summary() -> String:
	var counts := {}
	var moving := 0
	for target in _targets:
		if is_instance_valid(target) and target.motion != null:
			var motion_type := String(target.motion.type)
			counts[motion_type] = int(counts.get(motion_type, 0)) + 1
			moving += 1
	if moving == 0:
		return I18n.t("static")
	var parts: Array[String] = []
	for motion_type in counts:
		parts.append("%d %s" % [int(counts[motion_type]), I18n.t(String(motion_type))])
	return I18n.t("moving %d: %s") % [moving, ", ".join(parts)]


func _report_scenario_messages(result: Dictionary) -> void:
	var warnings: PackedStringArray = result.get("warnings", PackedStringArray())
	for warning in warnings:
		push_warning("Scenario %s: %s" % [result.get("path", "?"), warning])


func _fallback_scenario() -> Dictionary:
	var raw := {
		"schema_version": 1,
		"name": "phase1_fallback",
		"field": SimConfig.FIELD_1V1,
		"targets": [
			{"team": "red", "armor": "small", "number": "3",
				"position": [0.0, 0.0, -1.4], "yaw_deg": 180.0},
			{"team": "blue", "armor": "small", "number": "2",
				"position": [-1.5, 0.0, -0.2], "yaw_deg": 135.0},
			{"team": "red", "armor": "large", "number": "1",
				"position": [1.5, 0.0, -0.2], "yaw_deg": -135.0},
			{"team": "blue", "armor": "small", "number": "5",
				"position": [1.9, 0.0, 1.2], "yaw_deg": -90.0},
		],
	}
	return ScenarioSchema.validate(raw)["data"]


func _vec3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Array and (value as Array).size() >= 3:
		var array := value as Array
		return Vector3(float(array[0]), float(array[1]), float(array[2]))
	return fallback


# --- construction -----------------------------------------------------------

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.11, 0.19, 0.30)
	sky_mat.sky_horizon_color = Color(0.52, 0.60, 0.68)
	sky_mat.ground_bottom_color = Color(0.045, 0.05, 0.055)
	sky_mat.ground_horizon_color = Color(0.30, 0.32, 0.34)
	sky_mat.sun_angle_max = 30.0
	sky_mat.sun_curve = 0.12
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.85
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.glow_enabled = false
	env.ssao_enabled = false
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-48.0, -35.0, 0.0)
	sun.light_color = Color(1.0, 0.95, 0.88)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	add_child(sun)

	# Soft fill from the opposite side so the ego's dark materials stay readable.
	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.rotation_degrees = Vector3(-22.0, 145.0, 0.0)
	fill.light_color = Color(0.62, 0.72, 0.90)
	fill.light_energy = 0.30
	fill.shadow_enabled = false
	add_child(fill)


func _build_feed() -> void:
	# Render a slightly larger canvas than the published 1280x1024 feed and
	# crop it, so the QYG principal point (off-centre by ~35 px left / 24 px
	# down) is preserved even though Godot's projection centre is always the
	# image centre.  All numbers come from SimConfig.
	var canvas := SimConfig.feed_canvas_size()
	_feed_viewport = SubViewport.new()
	_feed_viewport.name = "FeedViewport"
	_feed_viewport.size = canvas
	_feed_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_feed_viewport.transparent_bg = false
	_feed_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_feed_viewport.own_world_3d = false
	add_child(_feed_viewport)

	_feed_camera = Camera3D.new()
	_feed_camera.name = "FeedCamera"
	_feed_camera.fov = SimConfig.feed_canvas_fov_deg()
	_feed_camera.near = 0.05
	_feed_camera.far = 80.0
	_feed_camera.cull_mask = 1
	_feed_camera.current = true
	_feed_viewport.add_child(_feed_camera)


## The published 1280x1024 feed as a cropped texture for the HUD/fullscreen
## preview.  Phase 2 crops the raw image the same way before publishing.
func get_feed_texture() -> Texture2D:
	var atlas := AtlasTexture.new()
	atlas.atlas = _feed_viewport.get_texture()
	atlas.region = Rect2(SimConfig.feed_crop_rect())
	atlas.filter_clip = true
	return atlas


## The published 1280x1024 feed image, cropped out of the render canvas.
func get_feed_image() -> Image:
	if DisplayServer.get_name() == "headless":
		return null
	var image := _feed_viewport.get_texture().get_image()
	if image == null:
		return null
	return image.get_region(SimConfig.feed_crop_rect())


func _build_debug_camera() -> void:
	_debug_camera = Camera3D.new()
	_debug_camera.name = "DebugCamera"
	_debug_camera.fov = 62.0
	_debug_camera.near = 0.05
	_debug_camera.far = 200.0
	_debug_camera.cull_mask = 3
	_debug_camera.current = true
	add_child(_debug_camera)


## Operator first-person camera: wide FOV, mounted on the gimbal. Culls the
## ego layer so the driving view is not blocked by the robot's own meshes.
func _build_fpv_camera() -> void:
	_fpv_camera = Camera3D.new()
	_fpv_camera.name = "FpvCamera"
	_fpv_camera.fov = SimConfig.FPV_FOV_DEG
	_fpv_camera.near = 0.02
	_fpv_camera.far = 200.0
	_fpv_camera.cull_mask = 1
	add_child(_fpv_camera)


func _build_free_camera() -> void:
	_free_camera = Camera3D.new()
	_free_camera.name = "FreeCamera"
	_free_camera.fov = 62.0
	_free_camera.near = 0.05
	_free_camera.far = 200.0
	_free_camera.cull_mask = 3
	add_child(_free_camera)


func _build_hud() -> void:
	_hud = HUD_SCENE.instantiate() as HUD
	_hud.name = "HUD"
	add_child(_hud)
	_hud.setup(get_feed_texture(), _ego, _targets.size())


## Start the rclgd backend if the extension is loaded and apply the scenario's
## ROS section. The simulator stays fully usable without ROS (host runs).
func _build_ros() -> void:
	_ros = RosBackend.new()
	_ros.name = "RosBackend"
	add_child(_ros)
	if _ros.start(_ego, _controller, Callable(self, "get_feed_image"), _targets):
		print("Main: ROS backend up (rclgd)")
	else:
		print("Main: ROS backend off (%s)" % _ros.failure)
	_ros.apply_scenario(_scenario.get("ros", {}))
