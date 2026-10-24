extends Node3D

## Phase 1 entry point.
## - 1v1 field (visual GLB + simplified collision)
## - static armour-plate targets
## - ego rig (vehicle.glb chassis + gimbal) with a 1280x1024 feed viewport
##   (rendered on a slightly larger canvas and cropped so the QYG optical-axis
##   off-centre principal point is preserved; see SimConfig.feed_crop_rect)
## - operator mode: first-person wide FPV driving + gimbal aim, third-person
##   debug camera, free camera, and the operator HUD
## No ROS yet: Phase 2 wires the rclgd backend.

const EGO_SCENE := preload("res://scenes/ego/EgoRig.tscn")
const HUD_SCENE := preload("res://scenes/ui/HUD.tscn")
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
var _targets: Array[TargetRig] = []
var _ros: RosBackend

var _self_fpv := false
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
	_build_fpv_camera()
	_build_hud()
	_sync_cameras()
	_build_ros()


func _process(delta: float) -> void:
	if _free_camera_mode:
		_update_free_camera(delta)
	else:
		_update_operator(delta)
		if _ros != null:
			_ros.apply_commands(delta)
		_controller.step(delta)

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
## always drives unless the free camera owns the keyboard.
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


func _reset_pose() -> void:
	_set_free_camera(false)
	_fpv_mode = false
	if _fpv_camera != null:
		_fpv_camera.current = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_controller.reset(EGO_START)
	_self_fpv = false
	_debug_camera.current = true
	_feed_camera.cull_mask = 1
	_sync_cameras()
	_update_stats()


func _sync_cameras() -> void:
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
		return "FREE CAMERA"
	if _fpv_mode:
		return "OPERATOR FPV"
	return "THIRD-PERSON"


func _update_stats() -> void:
	if _controller == null:
		return
	_hud.set_stats(_fps, _smoothed_frame_ms,
		_controller.gimbal_yaw_deg, _controller.gimbal_pitch_deg,
		_self_fpv, _free_camera_mode, _free_speed,
		_controller.chassis_position, _controller.chassis_speed_mps,
		_controller.follow_gimbal, _view_name(), _ros_status())


func _ros_status() -> String:
	if _ros == null:
		return "ROS: not started"
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
	_ego.camera_mount_preset = SimConfig.CAMERA_MOUNT_PRESET
	_ego.position = EGO_START
	add_child(_ego)
	# Owns the world pose; _init() pushes it into the rig.
	_controller = EgoController.new(_ego, EGO_START)


func _spawn_targets() -> void:
	_add_target("red", "small", "3", Vector3(0.0, 0.0, -1.4), 180.0)
	_add_target("blue", "small", "2", Vector3(-1.5, 0.0, -0.2), 135.0)
	_add_target("red", "large", "1", Vector3(1.5, 0.0, -0.2), -135.0)
	_add_target("blue", "small", "5", Vector3(1.9, 0.0, 1.2), -90.0)


## Every target uses the four-armour layout (two opposed pairs on the body
## X/Y axes, lower-edge rules S120/S121/S124/S125). Per-target layout is
## adjustable on the rig before it enters the tree, e.g.
##   target.center_height_m = 0.25
##   target.group_height_offset_m = 0.05
##   target.x_group_span_m = 0.48
##   target.y_group_span_m = 0.48
func _add_target(team: String, size_name: String, number: String, pos: Vector3, yaw_deg: float) -> void:
	var target := TargetRig.new()
	target.name = "Target_%s_%s" % [team, number]
	target.team = team
	target.armor_size = size_name
	target.number = number
	target.yaw_deg = yaw_deg
	target.position = pos
	add_child(target)
	_targets.append(target)


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
## preview.  Phase 2 will crop the raw image the same way before publishing.
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
	_debug_camera.far = 100.0
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
	_fpv_camera.far = 100.0
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


## Phase 2: start the rclgd backend if the extension is loaded. The simulator
## stays fully usable without ROS (Phase 1 host runs / editor).
func _build_ros() -> void:
	_ros = RosBackend.new()
	_ros.name = "RosBackend"
	add_child(_ros)
	if _ros.start(_ego, _controller, Callable(self, "get_feed_image"), _targets):
		print("Main: ROS backend up (rclgd)")
	else:
		print("Main: ROS backend off (%s)" % _ros.failure)
