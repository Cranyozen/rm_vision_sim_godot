extends SceneTree

## Dev-only: settle FPS with the free camera looking at the whole field.
## Usage: godot --path . --script res://tests/freecam_perf.gd

var _frames := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 5:
		_main._set_free_camera(true)
		_main._free_camera.global_position = Vector3(3.2, 2.6, 5.2)
		_main._free_camera.look_at(Vector3(0.0, 0.0, -1.0), Vector3.UP)
		_main._free_cam_yaw = _main._free_camera.rotation.y
		_main._free_cam_pitch = _main._free_camera.rotation.x
	elif _frames == 300:
		print("freecam perf: fps=", _main._fps, " frame_ms=", _main._smoothed_frame_ms)
		quit(0)
		return true
	return false
