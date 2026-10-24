extends SceneTree

## Dev-only: save the published 1280x1024 feed (canvas crop).
## Usage: godot --path . --script res://tests/capture_feed.gd

var _frames := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 40:
		var img: Image = _main.get_feed_image()
		if img == null:
			printerr("feed capture: no image")
			quit(1)
			return true
		var err: int = img.save_png("res://tests/feed_raw.png")
		print("feed capture: ", img.get_width(), "x", img.get_height(), " err=", err)
		quit(0 if err == OK else 1)
		return true
	return false
