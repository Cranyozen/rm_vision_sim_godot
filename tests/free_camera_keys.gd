extends SceneTree

## Dev-only: verify F4 / Esc key bindings toggle the free camera.
## Usage: godot --path . --script res://tests/free_camera_keys.gd

var _frames := 0
var _main: Node
var _entered := false
var _exited := false


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
		_key(KEY_F4, true)
	elif _frames == 10:
		_entered = _main._free_camera_mode and _main._free_camera.current
		print("F4 -> free on=", _main._free_camera_mode, " current=", _main._free_camera.current)
		_key(KEY_ESCAPE, true)
	elif _frames == 20:
		_exited = not _main._free_camera_mode and _main._debug_camera.current
		print("Esc -> free on=", _main._free_camera_mode, " debug current=", _main._debug_camera.current)
		var ok: bool = _entered and _exited
		print("FREE_CAMERA_KEYS: ", "PASS" if ok else "FAIL")
		quit(0 if ok else 1)
		return true
	return false
