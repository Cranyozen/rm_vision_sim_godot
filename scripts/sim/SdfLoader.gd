class_name SdfLoader
extends RefCounted

## SDF (`.sdf`) loader.
##
## Like `UrdfLoader`, this is a boundary layer: it understands the SDF body
## frame (X forward, Y left, Z up) and the SDF pose semantics, and it stores
## every transform / axis it produces in the Godot frame (Y up, -Z forward)
## through SimConfig's body<->Godot helpers. `RobotDescription` / `RobotRig`
## never see REP-103.
##
## Supported:
## - `<sdf><model name>` (also a bare `<model>` root and a `<world>` wrapper);
## - `<link>` with `<pose>` (default relative to the model, `relative_to`
##   accepts the model frame or another link name) and any number of
##   `<visual>` entries (box / cylinder / sphere / mesh, optional `<scale>`);
## - `<material>` with `<diffuse>` / `<ambient>` / `<emissive>` and
##   `<pbr><metal><metallic>/<roughness>`;
## - `<joint>` types fixed / revolute / continuous / prismatic / floating /
##   planar, `<parent>` / `<child>`, `<pose>`, `<axis><xyz>` and
##   `<limit>` (inside `<axis>` or directly under the joint).
##
## SDF pose semantics implemented here (SDF 1.7):
## - a link pose is relative to the model unless `relative_to` names a link;
## - a joint pose is relative to its **child link** unless `relative_to` says
##   otherwise. The rig needs the child frame relative to the parent, which is
##   derived as `parent^-1 * child`; the axis is expressed in the child frame
##   as `child^-1 * joint`.
## Rotations default to radians; `<pose degrees="true">` is supported, as is
## the 7-value quaternion form (`x y z qx qy qz qw`).
##
## Mesh convention: mesh files referenced by SDF are authored in the Godot
## frame; `tools/prepare_robot_model.py` converts ROS-frame meshes. The loader
## only resolves the URI, it never rotates mesh geometry. `model://` URIs are
## not resolvable without a package index (warning, mesh skipped).
##
## Not supported (warned and skipped): `<include>`, `<sensor>`, `<collision>`,
## `<inertial>`, nested models, `<plugin>`.

const JOINT_TYPES := RobotDescription.JOINT_TYPES
const MODEL_FRAMES := ["model", "__model__", "world", "__world__"]

var _warnings: Array[String] = []
## Source path used to resolve relative mesh URIs while parsing.
var _source_path := ""


## Load and normalize an `.sdf` file. Returns a description whose `errors`
## array is non-empty when the file cannot be used.
static func load_file(path: String) -> RobotDescription:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		var failed := _new_description(path)
		failed.errors.append("cannot read robot file: " + path)
		return failed
	return load_text(text, path)


## Load and normalize SDF text. `source_path` is used for relative mesh
## resolution and is stored on the description.
static func load_text(text: String, source_path := "") -> RobotDescription:
	return SdfLoader.new()._load_text(text, source_path)


static func _new_description(source_path: String) -> RobotDescription:
	var desc := RobotDescription.new()
	desc.format = "sdf"
	desc.source_path = source_path
	return desc


func _load_text(text: String, source_path: String) -> RobotDescription:
	_source_path = source_path
	var desc := _new_description(source_path)
	var parsed := RobotDescription.parse_xml(text)
	if not bool(parsed["ok"]):
		desc.errors.append("%s (line %d)"
			% [String(parsed["error"]), int(parsed["line"])])
		return desc

	var root: Dictionary = parsed["root"]
	var model := _find_model(root)
	if model.is_empty():
		desc.errors.append("no <model> element found in %s"
			% (source_path if not source_path.is_empty() else "SDF document"))
		return desc
	desc.name = RobotDescription.xml_attr(model, "name", "model")

	if not RobotDescription.xml_children(root, "include").is_empty() \
			or not RobotDescription.xml_children(model, "include").is_empty():
		_warnings.append("<include> is not supported; included models skipped")
	if not RobotDescription.xml_children(model, "model").is_empty():
		_warnings.append("nested <model> elements are not supported")

	var link_poses := _collect_link_poses(model)

	for link_element in RobotDescription.xml_children(model, "link"):
		var link_name := RobotDescription.xml_attr(link_element, "name")
		if link_name.is_empty():
			_warnings.append("<link> without a name ignored")
			continue
		if desc.links.has(link_name):
			_warnings.append("duplicate link '%s' ignored" % link_name)
			continue
		var link_pose := (link_poses[link_name] as Transform3D) \
			if link_poses.has(link_name) else Transform3D.IDENTITY
		var visuals: Array = []
		for visual_element in RobotDescription.xml_children(link_element, "visual"):
			visuals.append(_parse_visual(link_element, visual_element,
				link_name, link_pose))
		desc.links[link_name] = {"name": link_name, "visuals": visuals}

	for joint_element in RobotDescription.xml_children(model, "joint"):
		_parse_joint(desc, joint_element, link_poses)

	desc.warnings.append_array(_warnings)
	_finalize(desc)
	return desc


static func _find_model(root: Dictionary) -> Dictionary:
	var root_tag := String(root.get("tag", ""))
	if root_tag == "model":
		return root
	var nested := RobotDescription.xml_child(root, "model")
	return nested


func _finalize(desc: RobotDescription) -> void:
	var report := desc.validate()
	desc.errors.append_array(report["errors"])
	desc.warnings.append_array(report["warnings"])
	desc.root_link = String(report["root_link"])


## Resolve every link pose to the model frame (body frame, SDF axes).
## A link pose may reference another link through `relative_to`; the loop
## resolves dependencies in document order until nothing changes.
func _collect_link_poses(model: Dictionary) -> Dictionary:
	var entries: Array = []
	for link_element in RobotDescription.xml_children(model, "link"):
		var link_name := RobotDescription.xml_attr(link_element, "name")
		if link_name.is_empty():
			continue
		var pose := _pose_data(RobotDescription.xml_child(link_element, "pose"),
			"model")
		entries.append({"name": link_name, "pose": pose})
	var resolved: Dictionary = {}
	var pending := entries
	var guard := 0
	while not pending.is_empty() and guard <= entries.size() + 1:
		guard += 1
		var next: Array = []
		for entry in pending:
			var pose: Dictionary = entry["pose"]
			var relative_to := String(pose["relative_to"])
			var link_name := String(entry["name"])
			if relative_to.is_empty() or MODEL_FRAMES.has(relative_to):
				resolved[link_name] = pose["transform"]
			elif resolved.has(relative_to):
				resolved[link_name] = (resolved[relative_to] as Transform3D) \
					* (pose["transform"] as Transform3D)
			else:
				next.append(entry)
		if next.size() == pending.size():
			for entry in next:
				_warnings.append(
					"link '%s': pose relative to unknown frame '%s'; using model frame"
					% [String(entry["name"]), String(entry["pose"]["relative_to"])])
				resolved[String(entry["name"])] = entry["pose"]["transform"]
			break
		pending = next
	return resolved


func _parse_visual(link_element: Dictionary, element: Dictionary,
		link_name: String, link_pose: Transform3D) -> Dictionary:
	var visual := {
		"name": RobotDescription.xml_attr(element, "name",
			link_name + "_visual"),
		"type": "",
		"origin": _visual_origin(element, link_name, link_pose),
		"material": {},
	}
	var geometry := RobotDescription.xml_child(element, "geometry")
	if geometry.is_empty():
		_warnings.append("link '%s': visual without <geometry> skipped" % link_name)
		return visual
	var shape := _first_element(geometry)
	if shape.is_empty():
		_warnings.append("link '%s': empty <geometry> skipped" % link_name)
		return visual
	var shape_tag := String(shape.get("tag", ""))
	match shape_tag:
		"box":
			visual["type"] = "box"
			visual["size"] = RobotDescription.body_size_to_godot(
				RobotDescription.parse_vec3(
					RobotDescription.xml_text(
						RobotDescription.xml_child(shape, "size")),
					Vector3(0.1, 0.1, 0.1)))
		"cylinder":
			visual["type"] = "cylinder"
			visual["radius"] = RobotDescription.xml_text(
				RobotDescription.xml_child(shape, "radius")).to_float()
			visual["length"] = RobotDescription.xml_text(
				RobotDescription.xml_child(shape, "length")).to_float()
		"sphere":
			visual["type"] = "sphere"
			visual["radius"] = RobotDescription.xml_text(
				RobotDescription.xml_child(shape, "radius")).to_float()
		"mesh":
			visual["type"] = "mesh"
			var uri := RobotDescription.xml_text(
				RobotDescription.xml_child(shape, "uri"))
			var resolved := RobotDescription.resolve_mesh_path(uri,
				_source_path)
			visual["mesh_path"] = String(resolved["path"])
			if not String(resolved["warning"]).is_empty():
				_warnings.append("link '%s': %s"
					% [link_name, String(resolved["warning"])])
			var scale := RobotDescription.parse_vec3(
				RobotDescription.xml_text(
					RobotDescription.xml_child(shape, "scale")),
				Vector3.ONE)
			visual["scale"] = RobotDescription.body_size_to_godot(scale)
		_:
			_warnings.append("link '%s': unsupported geometry <%s> skipped"
				% [link_name, shape_tag])
			return visual

	visual["material"] = _parse_material(
		RobotDescription.xml_child(element, "material"))
	if (visual["material"] as Dictionary).is_empty() and visual["type"] != "mesh":
		visual["material"] = RobotDescription.default_material()
	return visual


## Visual pose: relative to the link by default. A `relative_to` that names
## the model frame is converted into link space; other frames are unsupported.
func _visual_origin(element: Dictionary, link_name: String,
		link_pose: Transform3D) -> Transform3D:
	var pose := _pose_data(RobotDescription.xml_child(element, "pose"),
		"link")
	var relative_to := String(pose["relative_to"])
	var transform: Transform3D = pose["transform"]
	if relative_to.is_empty() or relative_to == "link" \
			or relative_to == link_name:
		return RobotDescription.body_transform_to_godot(transform)
	if MODEL_FRAMES.has(relative_to):
		var local := link_pose.affine_inverse() * transform
		return RobotDescription.body_transform_to_godot(local)
	_warnings.append(
		"link '%s': visual pose relative to '%s' is not supported; using link frame"
		% [link_name, relative_to])
	return RobotDescription.body_transform_to_godot(transform)


func _parse_material(element: Dictionary) -> Dictionary:
	if element.is_empty():
		return {}
	var material := RobotDescription.default_material()
	var diffuse := RobotDescription.xml_child(element, "diffuse")
	var ambient := RobotDescription.xml_child(element, "ambient")
	if not diffuse.is_empty():
		material["color"] = RobotDescription.parse_color(
			RobotDescription.xml_text(diffuse))
	elif not ambient.is_empty():
		material["color"] = RobotDescription.parse_color(
			RobotDescription.xml_text(ambient))
	var emissive := RobotDescription.xml_child(element, "emissive")
	if not emissive.is_empty():
		material["emissive"] = RobotDescription.parse_color(
			RobotDescription.xml_text(emissive))
	var pbr := RobotDescription.xml_child(element, "pbr")
	if not pbr.is_empty():
		var metal := RobotDescription.xml_child(pbr, "metal")
		if not metal.is_empty():
			var metallic := RobotDescription.xml_text(
				RobotDescription.xml_child(metal, "metallic"))
			var roughness := RobotDescription.xml_text(
				RobotDescription.xml_child(metal, "roughness"))
			if not metallic.is_empty():
				material["metallic"] = clampf(metallic.to_float(), 0.0, 1.0)
			if not roughness.is_empty():
				material["roughness"] = clampf(roughness.to_float(), 0.0, 1.0)
	return material


func _parse_joint(desc: RobotDescription, element: Dictionary,
		link_poses: Dictionary) -> void:
	var joint_name := RobotDescription.xml_attr(element, "name")
	if joint_name.is_empty():
		_warnings.append("<joint> without a name ignored")
		return
	if desc.joints.has(joint_name):
		_warnings.append("duplicate joint '%s' ignored" % joint_name)
		return
	var joint_type := RobotDescription.xml_attr(element, "type", "fixed")
	var parent := RobotDescription.xml_text(
		RobotDescription.xml_child(element, "parent"))
	var child := RobotDescription.xml_text(
		RobotDescription.xml_child(element, "child"))
	var parent_pose: Transform3D = Transform3D.IDENTITY
	var child_pose: Transform3D = Transform3D.IDENTITY
	if link_poses.has(parent):
		parent_pose = link_poses[parent]
	elif not parent.is_empty():
		_warnings.append("joint '%s': unknown parent link '%s'"
			% [joint_name, parent])
	if link_poses.has(child):
		child_pose = link_poses[child]
	elif not child.is_empty():
		_warnings.append("joint '%s': unknown child link '%s'"
			% [joint_name, child])

	var joint := {
		"name": joint_name,
		"type": joint_type,
		"parent": parent,
		"child": child,
		# Rig needs the child frame relative to the parent.
		"origin": RobotDescription.body_transform_to_godot(
			parent_pose.affine_inverse() * child_pose),
		"axis": Vector3.ZERO,
		"limit": {},
	}

	var axis_element := RobotDescription.xml_child(element, "axis")
	var axis_body := Vector3(0.0, 0.0, 1.0)  # SDF default joint axis
	if not axis_element.is_empty():
		var xyz := RobotDescription.xml_text(
			RobotDescription.xml_child(axis_element, "xyz"))
		if not xyz.is_empty():
			axis_body = RobotDescription.parse_vec3(xyz, axis_body)
	joint["limit"] = _parse_limit(axis_element, element)

	# Axis frame: joint pose is relative to the child link by default, so the
	# axis in child coordinates is child^-1 * joint applied to the local axis.
	var joint_pose := _pose_data(
		RobotDescription.xml_child(element, "pose"), child)
	var relative_to := String(joint_pose["relative_to"])
	var joint_in_model: Transform3D = joint_pose["transform"]
	if not (relative_to.is_empty() or MODEL_FRAMES.has(relative_to)
			or relative_to == child):
		if link_poses.has(relative_to):
			joint_in_model = (link_poses[relative_to] as Transform3D) \
				* joint_in_model
		else:
			_warnings.append(
				"joint '%s': pose relative to unknown frame '%s'; using child frame"
				% [joint_name, relative_to])
	var child_from_joint := child_pose.affine_inverse() * joint_in_model
	joint["axis"] = RobotDescription.body_axis_to_godot(
		child_from_joint.basis * axis_body)
	desc.joints[joint_name] = joint


func _parse_limit(axis_element: Dictionary, joint_element: Dictionary) -> Dictionary:
	var limit_element := RobotDescription.xml_child(axis_element, "limit")
	if limit_element.is_empty():
		limit_element = RobotDescription.xml_child(joint_element, "limit")
	var limit: Dictionary = {}
	if limit_element.is_empty():
		return limit
	for key in ["lower", "upper", "effort", "velocity"]:
		var value := RobotDescription.xml_text(
			RobotDescription.xml_child(limit_element, key))
		if not value.is_empty():
			limit[key] = value.to_float()
	return limit


## Parse a `<pose>` element into { "transform": Transform3D, "relative_to": String }.
## The transform is in the SDF body frame (callers convert it to Godot when
## they store it). Supports the 6-value xyz+rpy form and the 7-value quaternion
## form, with `degrees="true"` scaling the rotation values.
func _pose_data(pose_element: Dictionary, default_relative_to: String) -> Dictionary:
	if pose_element.is_empty():
		return {"transform": Transform3D.IDENTITY,
			"relative_to": default_relative_to}
	var values := RobotDescription.xml_text(pose_element).split(" ", false)
	var relative_to := RobotDescription.xml_attr(pose_element, "relative_to",
		default_relative_to)
	var degrees := _parse_bool(
		RobotDescription.xml_attr(pose_element, "degrees", "false"))
	if values.size() >= 7:
		var origin := Vector3(values[0].to_float(), values[1].to_float(),
			values[2].to_float())
		var quaternion := Quaternion(values[3].to_float(), values[4].to_float(),
			values[5].to_float(), values[6].to_float())
		return {"transform": Transform3D(Basis(quaternion.normalized()), origin),
			"relative_to": relative_to}
	if values.size() >= 6:
		var origin := Vector3(values[0].to_float(), values[1].to_float(),
			values[2].to_float())
		var rpy := Vector3(values[3].to_float(), values[4].to_float(),
			values[5].to_float())
		if degrees:
			rpy = Vector3(deg_to_rad(rpy.x), deg_to_rad(rpy.y),
				deg_to_rad(rpy.z))
		return {
			"transform": Transform3D(
				SimConfig.body_rpy_basis(rpy), origin),
			"relative_to": relative_to,
		}
	_warnings.append("malformed <pose> ignored: '%s'"
		% RobotDescription.xml_text(pose_element))
	return {"transform": Transform3D.IDENTITY, "relative_to": default_relative_to}


func _parse_bool(text: String) -> bool:
	var lowered := text.strip_edges().to_lower()
	return lowered == "true" or lowered == "1"


func _first_element(node: Dictionary) -> Dictionary:
	var children: Array = node.get("children", [])
	if children.is_empty():
		return {}
	return children[0]
