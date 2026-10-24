extends SceneTree

## Dev-only: load Main.tscn, render a few frames, save a window screenshot.
## Usage: godot --path . --script res://tests/capture_phase1.gd

var _frames := 0
var _scene: Node


func _initialize() -> void:
	_scene = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 90:
		# get_texture().get_image() returns a stale (often first) frame unless a
		# draw is forced in a scripted run.
		RenderingServer.force_draw(false)
		var img := root.get_texture().get_image()
		if img == null:
			printerr("capture: no viewport image")
			quit(1)
			return true
		var err := img.save_png("res://tests/phase1_capture.png")
		print("capture: saved ", img.get_width(), "x", img.get_height(), " err=", err)
		quit(0 if err == OK else 1)
		return true
	return false
