extends SceneTree

## Dev-only: capture the operator-mode first-person view to docs/.
## Drives the robot forward a little, aims the gimbal at the targets and saves
## one window screenshot while the wide FPV camera is active.
## Usage: godot --path . --script res://tests/capture_operator.gd

var _frames := 0
var _scene: Node


func _initialize() -> void:
	_scene = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 20:
		var c = _scene._controller
		c.chassis_position = Vector3(0.0, 0.0, 1.1)
		c.chassis_yaw_deg = 0.0
		c.set_gimbal(-8.0, 1.5)
		c.apply_to_rig()
		_scene._set_fpv_mode(true)
		# No real mouse here; a captured pointer emits stray motion events that
		# would drift the gimbal between this frame and the screenshot.
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif _frames == 60:
		# get_texture().get_image() returns a stale (often first) frame unless a
		# draw is forced in a scripted run.
		RenderingServer.force_draw(false)
		var img := root.get_texture().get_image()
		if img == null:
			printerr("capture: no viewport image")
			quit(1)
			return true
		var err := img.save_png("res://docs/phase1_operator.png")
		print("capture: saved ", img.get_width(), "x", img.get_height(), " err=", err)
		quit(0 if err == OK else 1)
		return true
	return false
