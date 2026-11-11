class_name RobotRig
extends Node3D

## Builds a scene-tree rig from a normalized `RobotDescription` (URDF or SDF).
##
## Node layout (one node pair per link/joint, names kept readable):
##
##   RobotRig (Node3D, root of the description)
##     └─ Link_base_link
##          ├─ MeshInstance3D (visuals of the link)
##          └─ Joint_gimbal_yaw_joint      ← joint origin transform
##               └─ Link_gimbal_yaw_link
##                    └─ Joint_gimbal_pitch_joint
##                         └─ Link_gimbal_pitch_link
##
## All transforms come from the description and are already in the Godot
## frame (Y up, -Z forward). Mesh files referenced by URDF/SDF are authored in
## the same frame (`tools/prepare_robot_model.py` converts ROS meshes), so the
## rig never rotates mesh geometry.
##
## Joints: revolute / continuous joints rotate the joint node about the joint
## axis expressed in the child frame at rest; prismatic joints translate along
## it; fixed / floating / planar joints are static in this visual rig. The
## joint node always keeps its rest transform multiplied by the joint motion,
## so `set_joint_value(name, 0)` returns to the authored pose.
##
## Options for build():
##   "unit_scale": float = 1.0  — uniform scale applied to the rig root (for
##                                models authored in mm); link transforms stay
##                                in description units.
##   "layers": int = 1          — render layers set on every MeshInstance3D.
##   "visuals": bool = true     — build visual meshes (false = skeleton only).
##   "mesh_root": String = ""   — path prefix used for relative mesh paths that
##                                the loader could not resolve to res://.
##
## Mesh loading: a mesh file that cannot be loaded is a **warning** on the
## description and that visual is skipped; a description with `errors` should
## be rejected by the caller before building.

const MESH_NODE_PREFIX := "J_"

var description: RobotDescription
## Joint name -> joint Node3D (the node that carries the motion).
var joint_nodes: Dictionary = {}
## Link name -> link Node3D (the frame of the link).
var link_nodes: Dictionary = {}
## Render layers applied to the built meshes (VisualInstance3D.layers).
var layers := 1

var _mesh_instances: Array[MeshInstance3D] = []
var _joint_rest: Dictionary = {}
var _joint_values: Dictionary = {}
var _joint_types: Dictionary = {}
var _build_visuals := true
var _mesh_root := ""


## Build (but do not add to the tree) a rig for `desc`. The caller owns the
## returned node: `add_child(rig)` when it is ready.
static func build(desc: RobotDescription, options: Dictionary = {}) -> RobotRig:
	var rig := RobotRig.new()
	rig._build(desc, options)
	return rig


func _build(desc: RobotDescription, options: Dictionary) -> void:
	description = desc
	_build_visuals = bool(options.get("visuals", true))
	_mesh_root = String(options.get("mesh_root", ""))
	layers = int(options.get("layers", 1))
	var unit_scale := float(options.get("unit_scale", 1.0))
	if not is_equal_approx(unit_scale, 1.0):
		scale = Vector3.ONE * unit_scale
	if desc == null:
		push_error("RobotRig.build: description is null")
		return
	name = _node_name(desc.name if not desc.name.is_empty() else "RobotRig")
	var root_link := desc.root_link_name()
	if root_link.is_empty():
		push_error("RobotRig.build: description has no root link")
		return
	_build_link(root_link, self)


func _build_link(link_name: String, parent: Node3D) -> void:
	var link_node := Node3D.new()
	link_node.name = _node_name("Link_" + link_name)
	parent.add_child(link_node)
	link_nodes[link_name] = link_node
	var link := description.link(link_name)
	if _build_visuals:
		var visuals: Array = link.get("visuals", [])
		for index in visuals.size():
			_add_visual(link_node, visuals[index], index)
	for joint in description.child_joints(link_name):
		_build_joint(joint, link_node)


func _build_joint(joint: Dictionary, link_node: Node3D) -> void:
	var joint_name := String(joint.get("name", ""))
	if joint_name.is_empty():
		return
	var joint_node := Node3D.new()
	joint_node.name = _node_name(MESH_NODE_PREFIX + joint_name)
	var rest: Transform3D = joint.get("origin", Transform3D.IDENTITY)
	joint_node.transform = rest
	link_node.add_child(joint_node)
	joint_nodes[joint_name] = joint_node
	_joint_rest[joint_name] = rest
	_joint_types[joint_name] = String(joint.get("type", "fixed"))
	_joint_values[joint_name] = 0.0
	var child := String(joint.get("child", ""))
	if child.is_empty() or not description.has_link(child):
		return
	_build_link(child, joint_node)


func _add_visual(link_node: Node3D, visual: Dictionary, index: int) -> void:
	var shape := String(visual.get("type", ""))
	var visual_name := String(visual.get("name", ""))
	if visual_name.is_empty():
		visual_name = "Visual_%d" % index
	var origin: Transform3D = visual.get("origin", Transform3D.IDENTITY)
	var material: Dictionary = visual.get("material", {})
	if shape == "mesh":
		var resource := _load_mesh_resource(visual)
		if resource == null:
			return
		if resource is PackedScene:
			# A converted .glb imports as a scene. Instance the whole scene so
			# the exporter's node transforms (e.g. ROS -> Godot frame rotation)
			# are preserved, then register its MeshInstance3D children.
			_add_mesh_scene(link_node, resource as PackedScene, visual,
				visual_name, origin, material)
			return
		var mesh_scale: Vector3 = visual.get("scale", Vector3.ONE)
		_add_mesh_instance(link_node, resource as Mesh, visual_name,
			origin * Transform3D(Basis.from_scale(mesh_scale), Vector3.ZERO),
			material)
		return
	var primitive := _primitive_mesh(visual)
	if primitive == null:
		return
	_add_mesh_instance(link_node, primitive, visual_name, origin, material)


func _add_mesh_instance(link_node: Node3D, mesh: Mesh, visual_name: String,
		transform: Transform3D, material: Dictionary) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = _node_name(visual_name)
	instance.mesh = mesh
	instance.transform = transform
	if not material.is_empty():
		instance.material_override = _make_material(material)
	instance.layers = layers
	link_node.add_child(instance)
	_mesh_instances.append(instance)
	return instance


func _add_mesh_scene(link_node: Node3D, packed: PackedScene,
		visual: Dictionary, visual_name: String, origin: Transform3D,
		material: Dictionary) -> void:
	var scene := packed.instantiate()
	var root_node := scene as Node3D
	if root_node == null:
		description.warnings.append(
			"mesh scene has no Node3D root, visual skipped: "
			+ String(visual.get("mesh_path", "")))
		scene.free()
		return
	root_node.name = _node_name(visual_name)
	var mesh_scale: Vector3 = visual.get("scale", Vector3.ONE)
	root_node.transform = origin * Transform3D(
		Basis.from_scale(mesh_scale), Vector3.ZERO)
	link_node.add_child(root_node)
	for child in root_node.find_children("*", "MeshInstance3D", true, false):
		var instance := child as MeshInstance3D
		if not material.is_empty():
			instance.material_override = _make_material(material)
		instance.layers = layers
		_mesh_instances.append(instance)


func _primitive_mesh(visual: Dictionary) -> Mesh:
	match String(visual.get("type", "")):
		"box":
			var size: Vector3 = visual.get("size", Vector3.ONE * 0.1)
			if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
				description.warnings.append("box visual with invalid size skipped")
				return null
			var box := BoxMesh.new()
			box.size = size
			return box
		"cylinder":
			var radius := float(visual.get("radius", 0.0))
			var length := float(visual.get("length", 0.0))
			if radius <= 0.0 or length <= 0.0:
				description.warnings.append(
					"cylinder visual with invalid radius/length skipped")
				return null
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = radius
			cylinder.bottom_radius = radius
			cylinder.height = length
			return cylinder
		"sphere":
			var sphere_radius := float(visual.get("radius", 0.0))
			if sphere_radius <= 0.0:
				description.warnings.append("sphere visual with invalid radius skipped")
				return null
			var sphere := SphereMesh.new()
			sphere.radius = sphere_radius
			sphere.height = sphere_radius * 2.0
			return sphere
	return null


## Load the mesh file referenced by the description. Returns a Mesh, a
## PackedScene (for .glb/.gltf imports) or null (with a warning on the
## description) when the file is missing or not importable.
func _load_mesh_resource(visual: Dictionary) -> Resource:
	var mesh_path := String(visual.get("mesh_path", ""))
	if mesh_path.is_empty():
		return null
	var load_path := mesh_path
	if not (load_path.begins_with("res://") or load_path.begins_with("user://")):
		if not _mesh_root.is_empty():
			load_path = _mesh_root.path_join(load_path)
	if not ResourceLoader.exists(load_path):
		description.warnings.append("mesh not found, visual skipped: " + load_path)
		return null
	var resource := load(load_path)
	if resource is Mesh or resource is PackedScene:
		return resource
	description.warnings.append("mesh not loadable, visual skipped: " + load_path)
	return null


func _make_material(data: Dictionary) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	var color: Color = data.get("color", Color(0.72, 0.72, 0.75))
	material.albedo_color = color
	material.metallic = clampf(float(data.get("metallic", 0.0)), 0.0, 1.0)
	material.roughness = clampf(float(data.get("roughness", 0.6)), 0.0, 1.0)
	var emissive: Color = data.get("emissive", Color(0.0, 0.0, 0.0, 0.0))
	if emissive.r + emissive.g + emissive.b > 0.0:
		material.emission_enabled = true
		material.emission = emissive
	return material


# --- Public query / control API ---------------------------------------------

## Drive a joint. `value` is radians for revolute/continuous joints and metres
## for prismatic joints; it is ignored (but stored) for static joint types.
func set_joint_value(joint_name: String, value: float) -> void:
	if not joint_nodes.has(joint_name):
		return
	var joint_node: Node3D = joint_nodes[joint_name]
	var rest: Transform3D = _joint_rest[joint_name]
	var joint_type := String(_joint_types.get(joint_name, "fixed"))
	var axis: Vector3 = description.joint(joint_name).get("axis", Vector3.ZERO)
	var motion := Transform3D.IDENTITY
	if axis.length_squared() > 1e-12:
		var unit_axis := axis.normalized()
		match joint_type:
			"revolute", "continuous":
				motion = Transform3D(Basis(unit_axis, value), Vector3.ZERO)
			"prismatic":
				motion = Transform3D(Basis(), unit_axis * value)
	joint_node.transform = rest * motion
	_joint_values[joint_name] = value


func get_joint_value(joint_name: String) -> float:
	return float(_joint_values.get(joint_name, 0.0))


func get_link_node(link_name: String) -> Node3D:
	return link_nodes.get(link_name, null) as Node3D


func get_joint_node(joint_name: String) -> Node3D:
	return joint_nodes.get(joint_name, null) as Node3D


## Transform of `link_name` relative to the rig root (description units,
## excluding the rig's own `unit_scale`).
func get_link_transform(link_name: String) -> Transform3D:
	var node := get_link_node(link_name)
	if node == null:
		return Transform3D.IDENTITY
	var transform := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != self:
		if current is Node3D:
			transform = (current as Node3D).transform * transform
		current = current.get_parent()
	return transform


func get_root_link_node() -> Node3D:
	if description == null:
		return null
	return get_link_node(description.root_link_name())


## Mesh instances built for the description's visuals, in build order.
func mesh_instances() -> Array[MeshInstance3D]:
	return _mesh_instances.duplicate()


## Set the render layers of every built mesh instance.
func set_layers(value: int) -> void:
	layers = value
	for instance in _mesh_instances:
		instance.layers = value


static func _node_name(raw: String) -> String:
	var cleaned := raw.replace(":", "_").replace("/", "_").replace("@", "_") \
		.replace("%", "_").replace("\"", "_")
	return cleaned if not cleaned.is_empty() else "Node"
