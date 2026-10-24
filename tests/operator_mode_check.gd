extends SceneTree

## Dev-only: exercise the Phase 1 operator mode without a human.
## - F3 enters / Esc leaves the wide first-person FPV camera (mouse aim)
## - mouse look drives gimbal yaw / pitch, pitch is clamped
## - Q / E / R / F keyboard gimbal backup still works
## - W / S / A / D drive the chassis, Shift boosts, perimeter clamp holds
## - C toggles chassis follow-gimbal
## - F5 resets the pose, F4 still owns the keyboard for the free camera
## Usage: godot --path . --script res://tests/operator_mode_check.gd
## Expects: OPERATOR_MODE: PASS

var _frames := 0
var _main
var _failures: Array[String] = []
var _headless := DisplayServer.get_name() == "headless"

var _yaw0 := 0.0
var _pitch0 := 0.0
var _pos0 := Vector3.ZERO
var _pos1 := Vector3.ZERO
var _yaw_key0 := 0.0
var _yaw_follow0 := 0.0


func _initialize() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)


func _check(name: String, ok: bool, detail := "") -> void:
	print(("  ok   " if ok else "  FAIL ") + name + ("  " + detail if detail != "" else ""))
	if not ok:
		_failures.append(name)


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _mouse(relative: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.relative = relative
	Input.parse_input_event(mm)
	Input.flush_buffered_events()


func _process(_delta: float) -> bool:
	_frames += 1
	var c = _main._controller
	match _frames:
		5:
			_key(KEY_F3, true)
		7:
			_check("F3 enters operator FPV", _main._fpv_mode)
			_check("FPV camera is current", _main._fpv_camera.current)
			_check("FPV FOV is wide (70°)", is_equal_approx(_main._fpv_camera.fov, 70.0),
				"fov=%.1f" % _main._fpv_camera.fov)
			_check("FPV culls own robot (mask 1)", _main._fpv_camera.cull_mask == 1)
			var reticle: Control = null
			for n in _main._hud.find_children("*", "Crosshair", true, false):
				if (n as Control).is_visible_in_tree():
					reticle = n
			var vp_size := Vector2(root.size)
			_check("aim reticle is drawn", reticle != null)
			if reticle != null and not _headless:
				# Headless reports a 64x64 root window and ignores mouse capture;
				# these are display-server behaviours, not camera bugs.
				_check("reticle covers the viewport", reticle.size.is_equal_approx(vp_size),
					"reticle %.0fx%.0f vs view %.0fx%.0f" % [reticle.size.x, reticle.size.y, vp_size.x, vp_size.y])
				_check("reticle centre matches view centre",
					reticle.get_global_rect().get_center().is_equal_approx(vp_size * 0.5),
					"centre %s" % reticle.get_global_rect().get_center())
			if not _headless:
				_check("mouse captured for aim", Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
			_yaw0 = c.gimbal_yaw_deg
			_pitch0 = c.gimbal_pitch_deg
			_mouse(Vector2(240.0, 120.0))
		9:
			_check("mouse right turns gimbal right", c.gimbal_yaw_deg < _yaw0 - 20.0,
				"yaw %.1f -> %.1f" % [_yaw0, c.gimbal_yaw_deg])
			_check("mouse down pitches gimbal down", c.gimbal_pitch_deg < _pitch0 - 5.0,
				"pitch %.1f -> %.1f" % [_pitch0, c.gimbal_pitch_deg])
			var cam_yaw := rad_to_deg(_main._fpv_camera.global_rotation.y)
			_check("FPV camera follows the gimbal yaw",
				absf(angle_difference(deg_to_rad(cam_yaw), deg_to_rad(c.gimbal_yaw_deg))) < deg_to_rad(5.0),
				"cam yaw %.1f vs gimbal %.1f" % [cam_yaw, c.gimbal_yaw_deg])
			c.add_gimbal_pitch(100.0)
			_check("pitch clamped at +20°", is_equal_approx(c.gimbal_pitch_deg, 20.0),
				"pitch=%.1f" % c.gimbal_pitch_deg)
			c.add_gimbal_pitch(-100.0)
			_check("pitch clamped at -20°", is_equal_approx(c.gimbal_pitch_deg, -20.0),
				"pitch=%.1f" % c.gimbal_pitch_deg)
			_key(KEY_ESCAPE, true)
		11:
			_check("Esc leaves operator FPV", not _main._fpv_mode)
			_check("Esc releases the mouse", Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
			_check("third-person camera restored", _main._debug_camera.current)
			_key(KEY_F5, true)
		13:
			_key(KEY_W, true)
			_pos0 = c.chassis_position
		23:
			_key(KEY_W, false)
			_pos1 = c.chassis_position
			_check("W drives chassis forward (-Z)", _pos1.z < _pos0.z - 0.1,
				"dz=%.2f" % (_pos1.z - _pos0.z))
			_key(KEY_D, true)
			_pos0 = _pos1
		33:
			_key(KEY_D, false)
			_pos1 = c.chassis_position
			_check("D strafes chassis right (+X)", _pos1.x > _pos0.x + 0.1,
				"dx=%.2f" % (_pos1.x - _pos0.x))
			_yaw_key0 = c.gimbal_yaw_deg
			_key(KEY_E, true)
		41:
			_key(KEY_E, false)
			_check("E still turns the gimbal", c.gimbal_yaw_deg > _yaw_key0 + 3.0,
				"yaw %.1f -> %.1f" % [_yaw_key0, c.gimbal_yaw_deg])
			# Deterministic kinematics: chassis-relative move, boost, clamp.
			c.gimbal_yaw_deg = 0.0
			c.chassis_yaw_deg = 0.0
			c.chassis_position = Vector3.ZERO
			c.move_chassis(1.0, 0.0, false, 0.5)
			_check("chassis speed is 2.0 m/s", is_equal_approx(c.chassis_position.z, -1.0),
				"z=%.2f" % c.chassis_position.z)
			c.chassis_position = Vector3.ZERO
			c.move_chassis(1.0, 0.0, true, 0.5)
			_check("Shift boost is 1.8x", is_equal_approx(c.chassis_position.z, -1.8),
				"z=%.2f" % c.chassis_position.z)
			c.chassis_position = Vector3(0.0, 0.0, 2.15)
			c.move_chassis(-1.0, 0.0, false, 10.0)
			_check("perimeter clamp holds at +2.2 m", c.chassis_position.z <= 2.2001,
				"z=%.2f" % c.chassis_position.z)
			# Follow mode: chassis yaw chases the gimbal, then holds when off.
			c.reset(Vector3(0.0, 0.0, 2.2))
			_check("follow gimbal default on", c.follow_gimbal)
			c.set_gimbal(90.0, 0.0)
			_yaw_follow0 = c.chassis_yaw_deg
			for i in 60:
				c.step(1.0 / 60.0)
			_check("follow mode turns chassis toward gimbal",
				c.chassis_yaw_deg > _yaw_follow0 + 60.0,
				"chassis yaw %.1f" % c.chassis_yaw_deg)
			c.follow_gimbal = false
			var held: float = c.chassis_yaw_deg
			c.set_gimbal(-90.0, 0.0)
			for i in 30:
				c.step(1.0 / 60.0)
			_check("follow off keeps chassis yaw", absf(c.chassis_yaw_deg - held) < 0.01,
				"chassis yaw %.1f -> %.1f" % [held, c.chassis_yaw_deg])
			# F5 resets the pose and mode.
			_key(KEY_F5, true)
		43:
			_check("F5 resets chassis position", c.chassis_position.distance_to(Vector3(0.0, 0.0, 2.2)) < 0.001,
				"pos=" + str(c.chassis_position))
			_check("F5 resets gimbal", absf(c.gimbal_yaw_deg) < 0.001 and absf(c.gimbal_pitch_deg) < 0.001)
			_check("F5 restores follow mode", c.follow_gimbal)
			# Free camera still takes over the keyboard after operator mode.
			_key(KEY_F4, true)
		45:
			_check("F4 still enters free camera", _main._free_camera_mode and _main._free_camera.current)
			_key(KEY_F4, true)
		47:
			_check("F4 returns to the debug camera",
				not _main._free_camera_mode and _main._debug_camera.current)
			var ok := _failures.is_empty()
			if ok:
				print("OPERATOR_MODE: PASS")
			else:
				printerr("OPERATOR_MODE: FAIL (", ", ".join(_failures), ")")
			quit(0 if ok else 1)
			return true
	return false
