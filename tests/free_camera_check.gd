extends SceneTree

## Dev-only: exercise F4 free camera + WASD/E/F movement without a keyboard.
## Usage: godot --path . --script res://tests/free_camera_check.gd

var _frames := 0
var _main: Node
var _p0 := Vector3.ZERO
var _p1 := Vector3.ZERO
var _p2 := Vector3.ZERO
var _yaw0 := 0.0


func _initialize() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 5:
		_main._set_free_camera(true)
		_p0 = _main._free_camera.global_position
		print("free camera on: current=", _main._free_camera.current, " pos=", _p0)
		_yaw0 = _main._free_cam_yaw
		var mm := InputEventMouseMotion.new()
		mm.relative = Vector2(200.0, 100.0)
		Input.parse_input_event(mm)
		_key(KEY_W, true)
	elif _frames == 20:
		_key(KEY_W, false)
		_p1 = _main._free_camera.global_position
		print("after W: delta=", _p1 - _p0, " yaw delta=", _main._free_cam_yaw - _yaw0)
		_key(KEY_E, true)
	elif _frames == 35:
		_key(KEY_E, false)
		_p2 = _main._free_camera.global_position
		print("after E: dy=", _p2.y - _p1.y)
		_key(KEY_F, true)
	elif _frames == 50:
		_key(KEY_F, false)
		var dy: float = _main._free_camera.global_position.y - _p2.y
		print("after F: dy=", dy)
		_main._set_free_camera(false)
		print("free camera off: debug current=", _main._debug_camera.current, " mouse=", Input.mouse_mode)
		var ok: bool = (_p1 - _p0).length() > 0.05 and (_p2.y - _p1.y) > 0.05 and dy < -0.05 and absf(_main._free_cam_yaw - _yaw0) > 0.1
		print("FREE_CAMERA_CHECK: ", "PASS" if ok else "FAIL")
		quit(0 if ok else 1)
		return true
	return false
