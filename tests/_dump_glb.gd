extends SceneTree
func _initialize() -> void:
	var packed := load("res://assets/models/ego/vehicle.glb") as PackedScene
	var root3d := packed.instantiate() as Node3D
	_dump(root3d, 0, true)
	quit(0)

func _dump(n: Node, depth: int, all_nodes: bool) -> void:
	var pad := "  ".repeat(depth)
	if n is Node3D:
		var t := (n as Node3D).transform
		print("%s%s pos=%s rot_deg=%s scale=%s" % [pad, n.name, t.origin, t.basis.get_euler() * 180.0 / PI, t.basis.get_scale()])
	else:
		print("%s%s" % [pad, n.name])
	if depth > 4:
		return
	for c in n.get_children():
		var nm := String(c.name)
		if all_nodes or nm.contains("CAM") or nm.contains("GIMBAL") or depth < 2:
			_dump(c, depth + 1, all_nodes and depth < 2)
