extends SceneTree

## Dev-only: close-up of an in-scene armour target, used for the docs image.
## Usage: godot --path . --script res://tests/capture_armor_close.gd

var _frames := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3:
		var hud := _main.get_node_or_null("HUD")
		if hud:
			hud.visible = false
		_main._set_free_camera(true)
		# Red small "3" target sits at (0, 0, -1.4) with yaw 180; its plate
		# facing the ego ends up at z = -1.16, so stand 0.30 m in front of it.
		_main._free_camera.global_position = Vector3(0.0, 0.255, -0.86)
		_main._free_cam_yaw = 0.0
		_main._free_cam_pitch = -0.02
	if _frames == 25:
		var img := root.get_texture().get_image()
		var err := img.save_png("res://tests/armor_closeup.png")
		print("armor closeup: ", img.get_width(), "x", img.get_height(), " err=", err)
		quit(0 if err == OK else 1)
		return true
	return false
