extends Node3D

## Phase 1 entry point.
## - 1v1 field (visual GLB + simplified collision)
## - static armour-plate targets
## - ego rig (vehicle.glb chassis + gimbal) with a 1280x1024 feed viewport
## - third-person debug camera and operator HUD
## No ROS yet: Phase 2 wires the rclgd backend.

const EGO_SCENE := preload("res://scenes/ego/EgoRig.tscn")
const HUD_SCENE := preload("res://scenes/ui/HUD.tscn")
const EGO_START := Vector3(0.0, 0.0, 2.2)

var _ego: EgoRig
var _feed_viewport: SubViewport
var _feed_camera: Camera3D
var _debug_camera: Camera3D
var _free_camera: Camera3D
var _free_camera_mode := false
var _free_cam_yaw := 0.0
var _free_cam_pitch := 0.0
var _free_speed := 4.0
var _hud: HUD
var _targets: Array[TargetRig] = []

var _yaw := 0.0
var _pitch := 0.0
var _self_fpv := false
var _debug_fpv := false
var _stat_timer := 0.0
var _smoothed_frame_ms := 0.0
var _fps := 0.0
var _fps_accum := 0.0
var _fps_frames := 0


func _ready() -> void:
	_build_environment()
	_build_field()
	_spawn_ego()
	_spawn_targets()
	_build_feed()
	_build_debug_camera()
	_build_hud()
	_apply_pose()
	_sync_cameras()


func _process(delta: float) -> void:
	if _free_camera_mode:
		_update_free_camera(delta)
	else:
		var yaw_dir := 0.0
		if Input.is_key_pressed(KEY_Q):
			yaw_dir -= 1.0
		if Input.is_key_pressed(KEY_E):
			yaw_dir += 1.0
		var pitch_dir := 0.0
		if Input.is_key_pressed(KEY_R):
			pitch_dir += 1.0
		if Input.is_key_pressed(KEY_F):
			pitch_dir -= 1.0

		if yaw_dir != 0.0 or pitch_dir != 0.0:
			_yaw += yaw_dir * 90.0 * delta
			_pitch = clampf(_pitch + pitch_dir * 60.0 * delta, -20.0, 20.0)
			_apply_pose()

	_sync_cameras()
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
	if _free_camera_mode:
		if event is InputEventMouseMotion:
			var motion := event as InputEventMouseMotion
			_free_cam_yaw -= motion.relative.x * 0.0025
			_free_cam_pitch = clampf(_free_cam_pitch - motion.relative.y * 0.0025, -1.55, 1.55)
			return
		if event is InputEventMouseButton and event.pressed:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_free_speed = clampf(_free_speed * 1.15, 0.5, 30.0)
				return
			if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_free_speed = clampf(_free_speed / 1.15, 0.5, 30.0)
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
				_debug_fpv = not _debug_fpv
		KEY_F4:
			_set_free_camera(not _free_camera_mode)
		KEY_F5:
			_reset_pose()
		KEY_ESCAPE:
			if _free_camera_mode:
				_set_free_camera(false)
			elif _hud.is_feed_fullscreen():
				_hud.close_feed_fullscreen()
			else:
				get_tree().quit()


func _apply_pose() -> void:
	_ego.set_gimbal(_yaw, _pitch)


func _reset_pose() -> void:
	_set_free_camera(false)
	_yaw = 0.0
	_pitch = 0.0
	_self_fpv = false
	_debug_fpv = false
	_ego.position = EGO_START
	_ego.set_chassis_yaw(0.0)
	_ego.set_gimbal(_yaw, _pitch)
	_feed_camera.cull_mask = 1
	_sync_cameras()


func _sync_cameras() -> void:
	var mount := _ego.get_camera_mount()
	if mount == null:
		return
	_feed_camera.global_transform = mount.global_transform
	if _free_camera_mode:
		return
	if _debug_fpv:
		_debug_camera.global_transform = mount.global_transform
	else:
		var target := _ego.global_position + Vector3(0.0, 0.30, 0.0)
		_debug_camera.global_position = target + Vector3(0.0, 1.55, 2.65)
		_debug_camera.look_at(target, Vector3.UP)


func _update_stats() -> void:
	var fps := _fps
	_hud.set_stats(fps, _smoothed_frame_ms, _yaw, _pitch, _self_fpv, _free_camera_mode, _free_speed)


func _set_free_camera(enabled: bool) -> void:
	if enabled == _free_camera_mode:
		return
	_free_camera_mode = enabled
	if enabled:
		if _free_camera == null:
			_build_free_camera()
		_free_camera.global_transform = _debug_camera.global_transform
		_free_cam_yaw = _free_camera.rotation.y
		_free_cam_pitch = clampf(_free_camera.rotation.x, -1.55, 1.55)
		_free_camera.current = true
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


func _build_field() -> void:
	var packed := load(SimConfig.FIELD_1V1_PATH) as PackedScene
	if packed != null:
		var field := packed.instantiate()
		if field is Node3D:
			var f3d := field as Node3D
			f3d.name = "Field1v1"
			add_child(f3d)
		else:
			field.free()
	else:
		push_warning("Main: %s missing, using fallback floor" % SimConfig.FIELD_1V1_PATH)
		_add_fallback_floor()
	_build_field_collision()


func _add_fallback_floor() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "FallbackFloor"
	var plane := PlaneMesh.new()
	plane.size = Vector2(5.0, 5.0)
	mi.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.22, 0.24)
	mat.roughness = 0.9
	mi.material_override = mat
	add_child(mi)


func _build_field_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "FieldCollision"
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)

	_add_box_collision(body, Vector3(0.0, -0.05, 0.0), Vector3(5.0, 0.10, 5.0))
	_add_box_collision(body, Vector3(0.0, 0.21, -2.65), Vector3(5.6, 0.42, 0.30))
	_add_box_collision(body, Vector3(0.0, 0.21, 2.65), Vector3(5.6, 0.42, 0.30))
	_add_box_collision(body, Vector3(-2.65, 0.21, 0.0), Vector3(0.30, 0.42, 5.6))
	_add_box_collision(body, Vector3(2.65, 0.21, 0.0), Vector3(0.30, 0.42, 5.6))


func _add_box_collision(parent: StaticBody3D, centre: Vector3, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	cs.position = centre
	parent.add_child(cs)


func _spawn_ego() -> void:
	_ego = EGO_SCENE.instantiate() as EgoRig
	_ego.name = "Ego"
	_ego.preset = "vehicle"
	_ego.camera_mount_preset = "qyg"
	_ego.position = EGO_START
	add_child(_ego)


func _spawn_targets() -> void:
	_add_target("red", "small", "3", 4, Vector3(0.0, 0.0, -1.4), 180.0)
	_add_target("blue", "small", "2", 4, Vector3(-1.5, 0.0, -0.2), 135.0)
	_add_target("red", "large", "1", 2, Vector3(1.5, 0.0, -0.2), -135.0)
	_add_target("blue", "small", "5", 1, Vector3(1.9, 0.0, 1.2), -90.0)


func _add_target(team: String, size_name: String, number: String, armors: int, pos: Vector3, yaw_deg: float) -> void:
	var target := TargetRig.new()
	target.name = "Target_%s_%s" % [team, number]
	target.team = team
	target.armor_size = size_name
	target.number = number
	target.armors = armors
	target.yaw_deg = yaw_deg
	target.position = pos
	add_child(target)
	_targets.append(target)


func _build_feed() -> void:
	_feed_viewport = SubViewport.new()
	_feed_viewport.name = "FeedViewport"
	_feed_viewport.size = Vector2i(SimConfig.FEED_WIDTH, SimConfig.FEED_HEIGHT)
	_feed_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_feed_viewport.transparent_bg = false
	_feed_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_feed_viewport.own_world_3d = false
	add_child(_feed_viewport)

	_feed_camera = Camera3D.new()
	_feed_camera.name = "FeedCamera"
	_feed_camera.fov = SimConfig.vertical_fov_deg()
	_feed_camera.near = 0.05
	_feed_camera.far = 80.0
	_feed_camera.cull_mask = 1
	_feed_camera.current = true
	_feed_viewport.add_child(_feed_camera)


func _build_debug_camera() -> void:
	_debug_camera = Camera3D.new()
	_debug_camera.name = "DebugCamera"
	_debug_camera.fov = 62.0
	_debug_camera.near = 0.05
	_debug_camera.far = 100.0
	_debug_camera.cull_mask = 3
	_debug_camera.current = true
	add_child(_debug_camera)


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
	_hud.setup(_feed_viewport, _ego, _targets.size())
