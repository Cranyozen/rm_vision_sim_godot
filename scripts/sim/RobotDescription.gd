class_name RobotDescription
extends RefCounted

## Format-independent robot description shared by the URDF and SDF loaders.
##
## This is the single in-memory model the Phase 5 loaders produce and
## `RobotRig` consumes. Everything stored here is already expressed in the
## **Godot frame** (Y up, forward = -Z at yaw 0, metres) because the loaders
## are the only code that understands the URDF/SDF body frame (X forward,
## Y left, Z up) and they convert through SimConfig's body<->Godot helpers.
## Keeping the conversion in the loaders means `RobotRig` never has to know
## about REP-103, and the axis permutation still lives in exactly one place
## (`SimConfig`).
##
## Mesh files referenced by URDF/SDF are authored in the Godot frame (the
## URDF/SDF body frame is converted by `tools/prepare_robot_model.py`), so
## neither the loaders nor the rig rotate mesh geometry.
##
## Data layout:
##   links:  { name: { "name": String, "visuals": Array[Dictionary] } }
##   joints: { name: { "name": String, "type": String,
##                     "parent": String, "child": String,
##                     "origin": Transform3D,   # child frame relative to parent
##                     "axis": Vector3,         # unit, child/joint frame
##                     "limit": Dictionary } }
##
## Visual dictionaries:
##   { "name": String, "type": "box"|"cylinder"|"sphere"|"mesh",
##     "origin": Transform3D, "material": Dictionary,
##     "size": Vector3, "radius": float, "length": float,   # primitives
##     "mesh_path": String, "scale": Vector3 }              # mesh
##
## Material dictionaries:
##   { "name": String, "color": Color, "metallic": float,
##     "roughness": float, "emissive": Color }

## Joint types the rig can build / drive. "fixed", "floating" and "planar" are
## static in the rig; "revolute"/"continuous" rotate and "prismatic" slides.
const JOINT_TYPES := [
	"fixed", "revolute", "continuous", "prismatic", "floating", "planar",
]
const MOVING_JOINT_TYPES := ["revolute", "continuous", "prismatic"]

## Robot name from the source document (`<robot name>` / `<model name>`).
var name := ""
## Source format: "urdf" (also used for .xacro) or "sdf".
var format := ""
## Path the description was loaded from (may be empty for load_text).
var source_path := ""
## Root link name; filled in by the loaders from validate().
var root_link := ""
## Link dictionary keyed by link name (insertion order follows the document).
var links: Dictionary = {}
## Joint dictionary keyed by joint name (insertion order follows the document).
var joints: Dictionary = {}
## Global material definitions keyed by name (URDF <material>, SDF not used).
var materials: Dictionary = {}
## Non-fatal diagnostics (unsupported features, missing meshes, ...).
var warnings: Array[String] = []
## Fatal diagnostics; a description with errors must not be built.
var errors: Array[String] = []


func link(link_name: String) -> Dictionary:
	return links.get(link_name, {})


func joint(joint_name: String) -> Dictionary:
	return joints.get(joint_name, {})


func has_link(link_name: String) -> bool:
	return links.has(link_name)


func has_joint(joint_name: String) -> bool:
	return joints.has(joint_name)


func link_names() -> Array[String]:
	var out: Array[String] = []
	for key in links.keys():
		out.append(String(key))
	return out


func joint_names() -> Array[String]:
	var out: Array[String] = []
	for key in joints.keys():
		out.append(String(key))
	return out


## Root link: the link that is never a joint child. Returns the cached
## `root_link` when a loader / validate() already resolved it.
func root_link_name() -> String:
	if not root_link.is_empty():
		return root_link
	var child_links: Dictionary = {}
	for joint_name in joints:
		var child := String(joints[joint_name].get("child", ""))
		if not child.is_empty():
			child_links[child] = true
	for link_name in links:
		if not child_links.has(link_name):
			return String(link_name)
	return ""


## Joints whose parent is `link_name`, in document order.
func child_joints(link_name: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for joint_name in joints:
		if String(joints[joint_name].get("parent", "")) == link_name:
			out.append(joints[joint_name])
	return out


## Find the joint that lists `link_name` as its child ("" for the root link).
func parent_joint_name(link_name: String) -> String:
	for joint_name in joints:
		if String(joints[joint_name].get("child", "")) == link_name:
			return String(joint_name)
	return ""


## Rest transform of `link_name` relative to the root link, in the Godot frame.
## This is the forward-kinematics chain built from the joint origins and is
## what `RobotRig.get_link_transform()` reproduces on the node tree.
func link_transform(link_name: String) -> Transform3D:
	if not links.has(link_name):
		return Transform3D.IDENTITY
	var joint_name := parent_joint_name(link_name)
	if joint_name.is_empty():
		return Transform3D.IDENTITY
	var parent := String(joints[joint_name].get("parent", ""))
	return link_transform(parent) * (joints[joint_name]["origin"] as Transform3D)


## Structural validation. Pure: it never mutates the description, it returns
## a report the loaders merge into `errors` / `warnings`.
## Returns { "ok": bool, "errors": Array[String], "warnings": Array[String],
##           "root_link": String }.
func validate() -> Dictionary:
	var report_errors: Array[String] = []
	var report_warnings: Array[String] = []
	var child_links: Dictionary = {}
	var parent_links: Dictionary = {}

	if links.is_empty():
		report_errors.append("robot has no links")
	for link_name in links:
		var entry: Dictionary = links[link_name]
		if String(entry.get("name", link_name)) != String(link_name):
			report_errors.append("link '%s': name field mismatch" % link_name)

	for joint_name in joints:
		var entry: Dictionary = joints[joint_name]
		var joint_type := String(entry.get("type", ""))
		var parent := String(entry.get("parent", ""))
		var child := String(entry.get("child", ""))
		if not JOINT_TYPES.has(joint_type):
			report_errors.append("joint '%s': unsupported type '%s'"
				% [joint_name, joint_type])
		if parent.is_empty() or not links.has(parent):
			report_errors.append("joint '%s': unknown parent link '%s'"
				% [joint_name, parent])
		if child.is_empty() or not links.has(child):
			report_errors.append("joint '%s': unknown child link '%s'"
				% [joint_name, child])
		if not child.is_empty():
			if child_links.has(child):
				report_errors.append(
					"link '%s': attached to more than one joint" % child)
			child_links[child] = true
		if not parent.is_empty():
			parent_links[parent] = true
		if MOVING_JOINT_TYPES.has(joint_type):
			var axis: Vector3 = entry.get("axis", Vector3.ZERO)
			if axis.length_squared() < 1e-12:
				report_warnings.append(
					"joint '%s': zero axis, treated as fixed" % joint_name)

	var roots: Array[String] = []
	for link_name in links:
		if not child_links.has(link_name):
			roots.append(String(link_name))
	if roots.is_empty() and not links.is_empty():
		report_errors.append("no root link (joint graph contains a cycle)")
	elif roots.size() > 1:
		report_warnings.append("multiple root links: %s" % ", ".join(roots))
	var detected := ""
	if not roots.is_empty():
		detected = roots[0]
		if not root_link.is_empty() and root_link != detected:
			report_warnings.append("stored root_link '%s' != detected '%s'"
				% [root_link, detected])
		# Walk the graph from the root to catch cycles / disconnected links.
		var visited: Dictionary = {}
		var stack: Array[String] = [detected]
		while not stack.is_empty():
			var current: String = stack.pop_back()
			if visited.has(current):
				report_errors.append("link '%s' is reached twice (cycle)" % current)
				break
			visited[current] = true
			for joint_entry in child_joints(current):
				var child := String(joint_entry.get("child", ""))
				if not child.is_empty():
					stack.append(child)
		for link_name in links:
			if not visited.has(link_name):
				report_warnings.append("link '%s' is disconnected from root '%s'"
					% [link_name, detected])

	return {
		"ok": report_errors.is_empty(),
		"errors": report_errors,
		"warnings": report_warnings,
		"root_link": detected,
	}


# --- Static conversion helpers ----------------------------------------------

## Godot-frame transform from a body-frame pose (metres, URDF RPY = Rz*Ry*Rx).
static func body_pose_to_godot(xyz: Vector3, rpy: Vector3) -> Transform3D:
	return Transform3D(
		SimConfig.body_basis_to_godot(SimConfig.body_rpy_basis(rpy)),
		SimConfig.body_to_godot(xyz))


## Godot-frame transform from an arbitrary body-frame Transform3D (translation
## and rotation; a uniform/axis scale is carried through linearly).
static func body_transform_to_godot(transform: Transform3D) -> Transform3D:
	return Transform3D(
		SimConfig.body_basis_to_godot(transform.basis),
		SimConfig.body_to_godot(transform.origin))


## Body-frame vector (e.g. a joint axis) -> Godot frame, normalised.
static func body_axis_to_godot(axis: Vector3) -> Vector3:
	return SimConfig.body_to_godot(axis).normalized()


## Body-frame size vector -> Godot frame with positive components.
static func body_size_to_godot(size: Vector3) -> Vector3:
	return SimConfig.body_to_godot(size).abs()


## Resolve a mesh filename referenced by a URDF/SDF document.
## Returns { "path": String, "warning": String }:
## - res:// and user:// paths pass through unchanged;
## - relative paths resolve against the document's directory (and are
##   converted back to res:// when they land inside the project);
## - package:// and model:// URIs are not resolvable without a package index;
##   they produce a warning and an empty path;
## - file:// URIs have the scheme stripped.
static func resolve_mesh_path(filename: String, source_path: String) -> Dictionary:
	var raw := filename.strip_edges()
	var warning := ""
	var path := raw
	if raw.begins_with("res://") or raw.begins_with("user://"):
		path = raw
	elif raw.begins_with("package://"):
		warning = "mesh '%s': package:// URIs are not supported (mesh skipped)" % raw
		path = ""
	elif raw.begins_with("model://"):
		warning = "mesh '%s': model:// URIs are not supported (mesh skipped)" % raw
		path = ""
	elif raw.begins_with("file://"):
		path = raw.substr("file://".length())
	else:
		var base_dir := source_path.get_base_dir()
		if base_dir.is_empty():
			path = raw
		else:
			path = base_dir.path_join(raw)
	path = _project_relative(path)
	return {"path": path, "warning": warning}


## Convert an absolute path inside the project into a res:// path so the
## resource loaders can open it. Other paths are returned unchanged.
static func _project_relative(path: String) -> String:
	if path.is_empty() or path.begins_with("res://") or path.begins_with("user://"):
		return path
	if not path.is_absolute_path():
		return path
	var project_root := ProjectSettings.globalize_path("res://")
	if path.begins_with(project_root):
		return "res://" + path.substr(project_root.length())
	return path


## Parse `x y z` (or a single value broadcast) into a Vector3.
static func parse_vec3(text: String, fallback := Vector3.ZERO) -> Vector3:
	var parts := text.strip_edges().split(" ", false)
	if parts.size() == 1:
		var value := parts[0].to_float()
		return Vector3(value, value, value)
	if parts.size() < 3:
		return fallback
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())


## Parse `r g b a` into a Color (alpha defaults to 1).
static func parse_color(text: String, fallback := Color(0.72, 0.72, 0.75)) -> Color:
	var parts := text.strip_edges().split(" ", false)
	if parts.size() < 3:
		return fallback
	var alpha := 1.0
	if parts.size() >= 4:
		alpha = parts[3].to_float()
	return Color(
		clampf(parts[0].to_float(), 0.0, 1.0),
		clampf(parts[1].to_float(), 0.0, 1.0),
		clampf(parts[2].to_float(), 0.0, 1.0),
		clampf(alpha, 0.0, 1.0))


## Default material used for primitives without an explicit material.
static func default_material() -> Dictionary:
	return {
		"name": "",
		"color": Color(0.72, 0.72, 0.75),
		"metallic": 0.0,
		"roughness": 0.6,
	}


# --- Minimal XML DOM --------------------------------------------------------

## Parse XML text into a tiny read-only tree used by both loaders.
## Returns { "ok": bool, "error": String, "line": int, "root": Dictionary }
## where a tree node is { "tag": String, "attribs": Dictionary,
##                        "children": Array, "text": String }.
static func parse_xml(text: String) -> Dictionary:
	var parser := XMLParser.new()
	var open_error := parser.open_buffer(text.to_utf8_buffer())
	if open_error != OK:
		return {
			"ok": false,
			"error": "cannot open XML: " + error_string(open_error),
			"line": 0,
			"root": {},
		}
	var document := {"tag": "", "attribs": {}, "children": [], "text": ""}
	var stack: Array = [document]
	var failure := ""
	while true:
		var read_error := parser.read()
		if read_error != OK:
			if read_error != ERR_FILE_EOF:
				failure = error_string(read_error)
			break
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var element := {
					"tag": parser.get_node_name(),
					"attribs": {},
					"children": [],
					"text": "",
				}
				for i in parser.get_attribute_count():
					element["attribs"][parser.get_attribute_name(i)] = \
						parser.get_attribute_value(i)
				stack[-1]["children"].append(element)
				if not parser.is_empty():
					stack.append(element)
			XMLParser.NODE_ELEMENT_END:
				if stack.size() > 1:
					stack.pop_back()
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				stack[-1]["text"] += parser.get_node_data()
	if not failure.is_empty():
		return {
			"ok": false,
			"error": "XML parse error: " + failure,
			"line": parser.get_current_line(),
			"root": {},
		}
	# XMLParser is lenient about a truncated document: catch unclosed elements.
	if stack.size() > 1:
		return {
			"ok": false,
			"error": "unexpected end of XML document; unclosed <%s>"
				% String(stack[-1].get("tag", "")),
			"line": parser.get_current_line(),
			"root": {},
		}
	if document["children"].is_empty():
		return {
			"ok": false,
			"error": "XML document has no root element",
			"line": parser.get_current_line(),
			"root": {},
		}
	return {
		"ok": true,
		"error": "",
		"line": 0,
		"root": document["children"][0],
	}


## First child element of `node` with `tag` (empty Dictionary when absent).
static func xml_child(node: Dictionary, tag: String) -> Dictionary:
	for child in node.get("children", []):
		if String(child.get("tag", "")) == tag:
			return child
	return {}


## All child elements of `node` with `tag`, in document order.
static func xml_children(node: Dictionary, tag: String) -> Array:
	var out: Array = []
	for child in node.get("children", []):
		if String(child.get("tag", "")) == tag:
			out.append(child)
	return out


## Accumulated text content of a tree node, trimmed.
static func xml_text(node: Dictionary) -> String:
	return String(node.get("text", "")).strip_edges()


## Attribute value as String, or `fallback`.
static func xml_attr(node: Dictionary, key: String, fallback := "") -> String:
	return String(node.get("attribs", {}).get(key, fallback))
