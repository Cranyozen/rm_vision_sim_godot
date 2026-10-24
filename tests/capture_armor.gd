extends SceneTree

## Dev-only: render the extracted armour-module GLBs head-on and at 3/4 so the
## number / team-light selection can be checked without loading the full game.
## Usage: godot --path . --script res://tests/capture_armor.gd

const SMALL := "res://assets/models/armor/armor_small.glb"
const LARGE := "res://assets/models/armor/armor_large.glb"

var _frames := 0
var _cam: Camera3D


func _initialize() -> void:
	var world := Node3D.new()
	world.name = "World"
	root.add_child(world)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.09, 0.10)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.62)
	env.ambient_light_energy = 0.9
	we.environment = env
	world.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30.0, -25.0, 0.0)
	sun.light_energy = 2.2
	world.add_child(sun)

	_show(SMALL, Vector3(-0.18, 0.0, 0.0), "red", "2")
	_show(LARGE, Vector3(0.12, 0.0, 0.0), "blue", "1")

	_cam = Camera3D.new()
	_cam.name = "CaptureCamera"
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 0.30
	_cam.near = 0.01
	_cam.far = 20.0
	_cam.position = Vector3(0.0, 0.0, 1.5)
	_cam.rotation_degrees = Vector3.ZERO
	_cam.current = true
	world.add_child(_cam)


func _show(path: String, pos: Vector3, team: String, number: String) -> void:
	var inst: Node3D = (load(path) as PackedScene).instantiate()
	inst.position = pos
	root.add_child(inst)
	_set_selection(inst, team, number)
	var names: Array[String] = []
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		names.append("%s:%s" % [n.name, "on" if (n as MeshInstance3D).visible else "off"])
	print("capture_armor: ", path, " parts=", names)


func _set_selection(node: Node, team: String, number: String) -> void:
	var light_team := "RED" if team == "red" else "BLUE"
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var nm := String(mi.name)
		if nm.begins_with("STICKER_"):
			mi.visible = nm == "STICKER_" + number
		elif nm.begins_with("LIGHT_"):
			mi.visible = nm.ends_with("_" + light_team)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 40:
		_save("res://tests/armor_front.png")
		# 3/4 view to inspect depth, strips and the panel recess.
		_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		_cam.fov = 35.0
		_cam.position = Vector3(0.42, 0.18, 0.52)
		_cam.look_at(Vector3(-0.03, 0.0, 0.0), Vector3.UP)
	elif _frames == 80:
		_save("res://tests/armor_three_quarter.png")
		quit(0)
		return true
	return false


func _save(path: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		printerr("capture_armor: no viewport image")
		quit(1)
		return
	var err := img.save_png(path)
	print("capture_armor: saved ", path, " ", img.get_width(), "x", img.get_height(), " err=", err)
