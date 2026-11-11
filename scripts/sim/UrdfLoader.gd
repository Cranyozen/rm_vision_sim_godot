class_name UrdfLoader
extends RefCounted

## URDF (and a documented .xacro subset) loader.
##
## The loader is the only code that understands the URDF body frame
## (X forward, Y left, Z up, fixed-axis RPY = Rz*Ry*Rx). Every transform and
## axis it stores in the returned `RobotDescription` is already in the Godot
## frame (Y up, -Z forward) via SimConfig's body<->Godot helpers, so `RobotRig`
## and the rest of the simulator never see REP-103.
##
## Supported:
## - `<robot name>`, `<link>` with any number of `<visual>` entries;
## - visual geometry: box, cylinder, sphere, mesh (+ `scale`);
## - `<material>` (global definitions and per-visual `name` / inline `color`);
## - `<joint>` types fixed / revolute / continuous / prismatic / floating /
##   planar, with `<origin xyz rpy>`, `<axis xyz>` and `<limit ...>`;
## - `<collision>` / `<inertial>` are ignored (the rig is visual only).
##
## Documented xacro subset (detected by the `.xacro` extension or a `xacro:`
## tag in the text):
## - `<xacro:arg name default>` and `$(arg name)` (defaults only; callers may
##   pass overrides through `load_file(path, xacro_args)`);
## - `<xacro:property name value>` and `${expr}` / `${property}`;
## - `${...}` arithmetic with `pi`, `radians()`, `degrees()` and the usual
##   trig / sqrt / min / max functions;
## - `<xacro:include filename>` recursively, relative to the including file;
## - `<xacro:macro>`, `<xacro:if>` / `<xacro:unless>` are **not** implemented:
##   they are removed with a warning (`xacro:macro` output would be silently
##   wrong otherwise).
## - `$(find <pkg>)` is not implemented (no ROS package index): warning, empty.
##
## Mesh convention: mesh files referenced by URDF are authored in the Godot
## frame; `tools/prepare_robot_model.py` converts ROS-frame meshes. The loader
## therefore only resolves the filename, it never rotates mesh geometry.

const XACRO_MAX_INCLUDE_DEPTH := 16

var _warnings: Array[String] = []


## Load and normalize a `.urdf` / `.urdf.xacro` file. Returns a description
## whose `errors` array is non-empty when the file cannot be used.
static func load_file(path: String, xacro_args: Dictionary = {}) -> RobotDescription:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		var failed := _new_description(path)
		failed.errors.append("cannot read robot file: " + path)
		return failed
	return load_text(text, path, xacro_args)


## Load and normalize URDF text. `source_path` is used for relative mesh and
## xacro include resolution and is stored on the description.
static func load_text(text: String, source_path := "",
		xacro_args: Dictionary = {}) -> RobotDescription:
	return UrdfLoader.new()._load_text(text, source_path, xacro_args)


static func _new_description(source_path: String) -> RobotDescription:
	var desc := RobotDescription.new()
	desc.format = "urdf"
	desc.source_path = source_path
	return desc


func _load_text(text: String, source_path: String,
		xacro_args: Dictionary) -> RobotDescription:
	var desc := _new_description(source_path)
	var processed := text
	if _looks_like_xacro(source_path, text):
		var xacro := _XacroProcessor.new(xacro_args, source_path.get_base_dir())
		processed = xacro.process(text, source_path)
		_warnings.append_array(xacro.warnings)
		desc.errors.append_array(xacro.errors)
	if not desc.errors.is_empty():
		return desc

	var parsed := RobotDescription.parse_xml(processed)
	if not bool(parsed["ok"]):
		desc.errors.append("%s (line %d)"
			% [String(parsed["error"]), int(parsed["line"])])
		return desc

	var root: Dictionary = parsed["root"]
	if String(root.get("tag", "")) != "robot":
		# Tolerate a wrapper document that contains the <robot> element.
		var nested := RobotDescription.xml_child(root, "robot")
		if nested.is_empty():
			desc.errors.append("root element is <%s>, expected <robot>"
				% String(root.get("tag", "")))
			return desc
		root = nested

	desc.name = RobotDescription.xml_attr(root, "name", "robot")
	for material_element in RobotDescription.xml_children(root, "material"):
		_parse_global_material(desc, material_element)
	for link_element in RobotDescription.xml_children(root, "link"):
		_parse_link(desc, link_element)
	for joint_element in RobotDescription.xml_children(root, "joint"):
		_parse_joint(desc, joint_element)

	desc.warnings.append_array(_warnings)
	_finalize(desc)
	return desc


static func _looks_like_xacro(source_path: String, text: String) -> bool:
	return source_path.get_extension().to_lower() == "xacro" \
		or text.contains("xacro:")


func _finalize(desc: RobotDescription) -> void:
	var report := desc.validate()
	desc.errors.append_array(report["errors"])
	desc.warnings.append_array(report["warnings"])
	desc.root_link = String(report["root_link"])


func _parse_global_material(desc: RobotDescription, element: Dictionary) -> void:
	var material_name := RobotDescription.xml_attr(element, "name")
	if material_name.is_empty():
		_warnings.append("global <material> without a name ignored")
		return
	var color_element := RobotDescription.xml_child(element, "color")
	if color_element.is_empty():
		# Textures are not supported: keep the material name so visual
		# references resolve, but use the default colour.
		_warnings.append("material '%s': only <color rgba> is supported"
			% material_name)
		return
	var material := RobotDescription.default_material()
	material["name"] = material_name
	material["color"] = RobotDescription.parse_color(
		RobotDescription.xml_attr(color_element, "rgba", "0.72 0.72 0.75 1"))
	desc.materials[material_name] = material


func _parse_link(desc: RobotDescription, element: Dictionary) -> void:
	var link_name := RobotDescription.xml_attr(element, "name")
	if link_name.is_empty():
		_warnings.append("<link> without a name ignored")
		return
	if desc.links.has(link_name):
		_warnings.append("duplicate link '%s' ignored" % link_name)
		return
	var visuals: Array = []
	for visual_element in RobotDescription.xml_children(element, "visual"):
		visuals.append(_parse_visual(desc, visual_element, link_name))
	desc.links[link_name] = {"name": link_name, "visuals": visuals}


func _parse_visual(desc: RobotDescription, element: Dictionary,
		link_name: String) -> Dictionary:
	var visual := {
		"name": RobotDescription.xml_attr(element, "name", link_name + "_visual"),
		"type": "",
		"origin": _parse_origin(element),
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
					RobotDescription.xml_attr(shape, "size", "0.1 0.1 0.1")))
		"cylinder":
			visual["type"] = "cylinder"
			visual["radius"] = RobotDescription.xml_attr(shape, "radius").to_float()
			visual["length"] = RobotDescription.xml_attr(shape, "length").to_float()
		"sphere":
			visual["type"] = "sphere"
			visual["radius"] = RobotDescription.xml_attr(shape, "radius").to_float()
		"mesh":
			visual["type"] = "mesh"
			var mesh_name := RobotDescription.xml_attr(shape, "filename")
			var resolved := RobotDescription.resolve_mesh_path(mesh_name,
				desc.source_path)
			visual["mesh_path"] = String(resolved["path"])
			if not String(resolved["warning"]).is_empty():
				_warnings.append("link '%s': %s"
					% [link_name, String(resolved["warning"])])
			var mesh_scale := RobotDescription.parse_vec3(
				RobotDescription.xml_attr(shape, "scale", "1 1 1"), Vector3.ONE)
			visual["scale"] = RobotDescription.body_size_to_godot(mesh_scale)
		_:
			_warnings.append("link '%s': unsupported geometry <%s> skipped"
				% [link_name, shape_tag])
			return visual

	visual["material"] = _parse_visual_material(desc, element, link_name)
	if (visual["material"] as Dictionary).is_empty() and visual["type"] != "mesh":
		visual["material"] = RobotDescription.default_material()
	return visual


func _parse_visual_material(desc: RobotDescription, element: Dictionary,
		link_name: String) -> Dictionary:
	var material_element := RobotDescription.xml_child(element, "material")
	if material_element.is_empty():
		return {}
	var material: Dictionary = {}
	var reference := RobotDescription.xml_attr(material_element, "name")
	var color_element := RobotDescription.xml_child(material_element, "color")
	if not color_element.is_empty():
		material = RobotDescription.default_material()
		material["name"] = reference
		material["color"] = RobotDescription.parse_color(
			RobotDescription.xml_attr(color_element, "rgba", "0.72 0.72 0.75 1"))
	elif not reference.is_empty():
		if desc.materials.has(reference):
			material = (desc.materials[reference] as Dictionary).duplicate()
		else:
			_warnings.append("link '%s': unknown material '%s'"
				% [link_name, reference])
			material = RobotDescription.default_material()
			material["name"] = reference
	return material


func _parse_joint(desc: RobotDescription, element: Dictionary) -> void:
	var joint_name := RobotDescription.xml_attr(element, "name")
	if joint_name.is_empty():
		_warnings.append("<joint> without a name ignored")
		return
	if desc.joints.has(joint_name):
		_warnings.append("duplicate joint '%s' ignored" % joint_name)
		return
	var joint_type := RobotDescription.xml_attr(element, "type", "fixed")
	var parent := _link_reference(
		RobotDescription.xml_child(element, "parent"))
	var child := _link_reference(
		RobotDescription.xml_child(element, "child"))
	var joint := {
		"name": joint_name,
		"type": joint_type,
		"parent": parent,
		"child": child,
		"origin": _parse_origin(element),
		"axis": Vector3.ZERO,
		"limit": {},
	}
	var axis_element := RobotDescription.xml_child(element, "axis")
	var axis_body := Vector3(1.0, 0.0, 0.0)  # URDF default joint axis
	if not axis_element.is_empty():
		axis_body = RobotDescription.parse_vec3(
			RobotDescription.xml_attr(axis_element, "xyz", "1 0 0"), axis_body)
	joint["axis"] = RobotDescription.body_axis_to_godot(axis_body)
	joint["limit"] = _parse_limit(RobotDescription.xml_child(element, "limit"))
	var mimic_element := RobotDescription.xml_child(element, "mimic")
	if not mimic_element.is_empty():
		joint["mimic"] = {
			"joint": RobotDescription.xml_attr(mimic_element, "joint"),
			"multiplier": RobotDescription.xml_attr(mimic_element, "multiplier",
				"1").to_float(),
			"offset": RobotDescription.xml_attr(mimic_element, "offset",
				"0").to_float(),
		}
	desc.joints[joint_name] = joint


## URDF joint <parent link="name"/> / <child link="name"/>: the link name is
## normally an attribute (older documents put it in the element text).
func _link_reference(element: Dictionary) -> String:
	if element.is_empty():
		return ""
	var reference := RobotDescription.xml_attr(element, "link")
	if not reference.is_empty():
		return reference
	return RobotDescription.xml_text(element)


func _parse_limit(element: Dictionary) -> Dictionary:
	var limit: Dictionary = {}
	if element.is_empty():
		return limit
	for key in ["lower", "upper", "effort", "velocity"]:
		var value := RobotDescription.xml_attr(element, key)
		if not value.is_empty():
			limit[key] = value.to_float()
	return limit


func _parse_origin(element: Dictionary) -> Transform3D:
	var origin := RobotDescription.xml_child(element, "origin")
	if origin.is_empty():
		return Transform3D.IDENTITY
	var xyz := RobotDescription.parse_vec3(
		RobotDescription.xml_attr(origin, "xyz", "0 0 0"))
	var rpy := RobotDescription.parse_vec3(
		RobotDescription.xml_attr(origin, "rpy", "0 0 0"))
	return RobotDescription.body_pose_to_godot(xyz, rpy)


func _first_element(node: Dictionary) -> Dictionary:
	var children: Array = node.get("children", [])
	if children.is_empty():
		return {}
	return children[0]


# --- Documented xacro subset ------------------------------------------------

## Textual xacro expander for the subset documented on `UrdfLoader`.
## Include expansion, arg/property collection and substitution are done as
## simple text passes; the result is then parsed as ordinary URDF XML.
class _XacroProcessor:
	extends RefCounted

	const RE_COMMENT := "(?s)<!--.*?-->"
	const RE_XML_DECL := "(?s)<\\?xml.*?\\?>"
	const RE_MACRO_BLOCK := "(?s)<xacro:macro\\b[^>]*>.*?</xacro:macro>"
	const RE_MACRO_EMPTY := "<xacro:macro\\b[^>]*/>"
	const RE_CONDITIONAL := \
		"(?s)<xacro:(if|unless)\\b[^>]*>.*?</xacro:(?:if|unless)>"
	const RE_ARG := "<xacro:arg\\b[^>]*>"
	const RE_PROPERTY_BLOCK := \
		"(?s)<xacro:property\\b([^>]*)>(.*?)</xacro:property>"
	const RE_PROPERTY_EMPTY := "<xacro:property\\b([^>]*)/>"
	const RE_INCLUDE := "<xacro:include\\b[^>]*/>"
	const RE_ARG_REF := "\\$\\(arg\\s+([^\\)\\s]+)\\s*\\)"
	const RE_FIND_REF := "\\$\\(find\\s+([^\\)]+)\\)"
	const RE_ENV_REF := "\\$\\(env\\s+([^\\)\\s]+)\\s*\\)"
	const RE_OPTENV_REF := "\\$\\(optenv\\s+([^\\)\\s]+)(?:\\s+([^\\)]*))?\\)"
	const RE_EVAL_REF := "\\$\\(eval\\s+([^\\)]*)\\)"
	const RE_GENERIC_REF := "\\$\\(([^\\)]*)\\)"
	const RE_EXPR := "\\$\\{([^}]*)\\}"

	var args: Dictionary = {}
	var properties: Dictionary = {}
	var warnings: Array[String] = []
	var errors: Array[String] = []

	var _base_dir := ""
	var _include_stack: Array[String] = []

	func _init(initial_args: Dictionary = {}, base_dir := "") -> void:
		_base_dir = base_dir
		for key in initial_args:
			args[String(key)] = String(initial_args[key])

	func process(text: String, source_path: String) -> String:
		var expanded := _expand(text, source_path, 0)
		return _substitute(expanded)

	func _expand(text: String, source_path: String, depth: int) -> String:
		if depth > UrdfLoader.XACRO_MAX_INCLUDE_DEPTH:
			errors.append("xacro:include nesting too deep: " + source_path)
			return text
		var source_dir := source_path.get_base_dir()
		if source_dir.is_empty():
			source_dir = _base_dir

		text = _regex_replace(RE_COMMENT, text,
			func(_match: RegExMatch) -> String: return "")
		text = _regex_replace(RE_XML_DECL, text,
			func(_match: RegExMatch) -> String: return "")
		text = _regex_replace(RE_MACRO_BLOCK, text,
			func(_match: RegExMatch) -> String:
				warnings.append(
					"xacro:macro is not supported; macro definition removed")
				return "")
		text = _regex_replace(RE_MACRO_EMPTY, text,
			func(_match: RegExMatch) -> String:
				warnings.append(
					"xacro:macro is not supported; macro definition removed")
				return "")
		text = _regex_replace(RE_CONDITIONAL, text,
			func(_match: RegExMatch) -> String:
				warnings.append(
					"xacro:if / xacro:unless are not supported; block removed")
				return "")

		# Collect <xacro:arg> defaults (caller overrides win).
		text = _regex_replace(RE_ARG, text,
			func(match: RegExMatch) -> String:
				var tag := match.get_string(0)
				var arg_name := _attribute(tag, "name")
				if arg_name.is_empty():
					warnings.append("xacro:arg without a name ignored")
					return ""
				if not args.has(arg_name):
					args[arg_name] = _substitute(_attribute(tag, "default"))
				return "")

		# Collect <xacro:property> definitions (block form first, then empty).
		text = _regex_replace(RE_PROPERTY_BLOCK, text,
			func(match: RegExMatch) -> String:
				var attrs := match.get_string(1)
				var property_name := _attribute(attrs, "name")
				var value := _attribute(attrs, "value")
				if value.is_empty():
					value = match.get_string(2).strip_edges()
				_store_property(property_name, value)
				return "")
		text = _regex_replace(RE_PROPERTY_EMPTY, text,
			func(match: RegExMatch) -> String:
				var attrs := match.get_string(1)
				_store_property(_attribute(attrs, "name"),
					_attribute(attrs, "value"))
				return "")

		# Expand includes (recursively; relative to the including document).
		text = _regex_replace(RE_INCLUDE, text,
			func(match: RegExMatch) -> String:
				var tag := match.get_string(0)
				var filename := _substitute(_attribute(tag, "filename"))
				if filename.is_empty():
					warnings.append("xacro:include without a filename ignored")
					return ""
				var include_path := filename
				if not (filename.begins_with("res://")
						or filename.begins_with("user://")
						or filename.is_absolute_path()):
					include_path = source_dir.path_join(filename)
				if _include_stack.has(include_path):
					errors.append("recursive xacro:include: " + include_path)
					return ""
				var include_text := FileAccess.get_file_as_string(include_path)
				if include_text.is_empty():
					errors.append("xacro:include not found: " + include_path)
					return ""
				_include_stack.push_back(include_path)
				var expanded := _expand(include_text, include_path, depth + 1)
				_include_stack.pop_back()
				return expanded)
		return text

	func _store_property(property_name: String, value: String) -> void:
		if property_name.is_empty():
			warnings.append("xacro:property without a name ignored")
			return
		var substituted := _substitute(value)
		var evaluated = _evaluate(substituted)
		if evaluated == null:
			properties[property_name] = substituted
		else:
			properties[property_name] = evaluated

	func _substitute(text: String) -> String:
		var out := text
		out = _regex_replace(RE_ARG_REF, out,
			func(match: RegExMatch) -> String:
				var arg_name := match.get_string(1)
				if not args.has(arg_name):
					warnings.append("missing xacro arg '%s'" % arg_name)
					return ""
				return String(args[arg_name]))
		out = _regex_replace(RE_FIND_REF, out,
			func(match: RegExMatch) -> String:
				warnings.append(
					"$(find %s): ROS package lookup is not supported"
					% match.get_string(1))
				return "")
		out = _regex_replace(RE_ENV_REF, out,
			func(match: RegExMatch) -> String:
				return OS.get_environment(match.get_string(1)))
		out = _regex_replace(RE_OPTENV_REF, out,
			func(match: RegExMatch) -> String:
				var value := OS.get_environment(match.get_string(1))
				if value.is_empty():
					return match.get_string(2)
				return value)
		out = _regex_replace(RE_EVAL_REF, out,
			func(match: RegExMatch) -> String:
				return _stringify(_evaluate(match.get_string(1)),
					match.get_string(1)))
		out = _regex_replace(RE_GENERIC_REF, out,
			func(match: RegExMatch) -> String:
				warnings.append("unsupported substitution $(%s)"
					% match.get_string(1))
				return "")
		out = _regex_replace(RE_EXPR, out,
			func(match: RegExMatch) -> String:
				var expression := match.get_string(1)
				return _stringify(_evaluate(expression), expression))
		return out

	func _stringify(value, expression: String) -> String:
		if value == null:
			errors.append("xacro expression could not be evaluated: ${%s}"
				% expression)
			return ""
		if value is float or value is int:
			return _format_number(float(value))
		return String(value)

	func _is_identifier(text: String) -> bool:
		if text.is_empty():
			return false
		for index in text.length():
			var character := text[index]
			var is_letter := (character >= "a" and character <= "z") \
				or (character >= "A" and character <= "Z") \
				or character == "_"
			if not is_letter and not (character >= "0" and character <= "9"):
				return false
		return true

	func _format_number(value: float) -> String:
		if is_equal_approx(value, round(value)) and absf(value) < 1e15:
			return str(int(round(value)))
		return String.num(value, 9)

	func _evaluate(expression: String) -> Variant:
		# A bare ${property} / ${arg} may hold a non-numeric string (a mesh
		# directory, an RPY triple, ...), which the arithmetic parser cannot
		# represent; return it verbatim.
		var trimmed := expression.strip_edges()
		if _is_identifier(trimmed):
			if properties.has(trimmed):
				return properties[trimmed]
			if args.has(trimmed):
				var arg_text := String(args[trimmed])
				if not arg_text.is_valid_float():
					return arg_text
		var parser := _ExprParser.new(expression, self)
		var result = parser.parse()
		if parser.failed:
			return null
		return result

	# --- expression evaluator hooks -------------------------------------

	func _lookup_variable(identifier: String) -> Variant:
		match identifier:
			"pi":
				return PI
			"e":
				return 2.718281828459045
			"true":
				return 1.0
			"false":
				return 0.0
		if args.has(identifier):
			var arg_value := String(args[identifier])
			if arg_value.is_valid_float():
				return arg_value.to_float()
			return null
		if properties.has(identifier):
			var value = properties[identifier]
			if value is float or value is int:
				return float(value)
			if value is String and (value as String).is_valid_float():
				return (value as String).to_float()
		return null

	func _call_function(function_name: String, values: Array) -> Variant:
		var numbers: Array[float] = []
		for value in values:
			if value is float or value is int:
				numbers.append(float(value))
			else:
				return null
		var count := numbers.size()
		match function_name:
			"radians":
				return deg_to_rad(numbers[0]) if count == 1 else null
			"degrees":
				return rad_to_deg(numbers[0]) if count == 1 else null
			"sin":
				return sin(numbers[0]) if count == 1 else null
			"cos":
				return cos(numbers[0]) if count == 1 else null
			"tan":
				return tan(numbers[0]) if count == 1 else null
			"asin":
				return asin(numbers[0]) if count == 1 else null
			"acos":
				return acos(numbers[0]) if count == 1 else null
			"atan":
				return atan(numbers[0]) if count == 1 else null
			"atan2":
				return atan2(numbers[0], numbers[1]) if count == 2 else null
			"sqrt":
				return sqrt(numbers[0]) if count == 1 else null
			"abs":
				return absf(numbers[0]) if count == 1 else null
			"floor":
				return floorf(numbers[0]) if count == 1 else null
			"ceil":
				return ceilf(numbers[0]) if count == 1 else null
			"round":
				return roundf(numbers[0]) if count == 1 else null
			"min":
				return minf(numbers[0], numbers[1]) if count == 2 else null
			"max":
				return maxf(numbers[0], numbers[1]) if count == 2 else null
			"pow":
				return pow(numbers[0], numbers[1]) if count == 2 else null
			"exp":
				return exp(numbers[0]) if count == 1 else null
			"log":
				return log(numbers[0]) if count == 1 else null
		return null

	# --- helpers ---------------------------------------------------------

	func _regex_replace(pattern: String, text: String, handler: Callable) -> String:
		var regex := RegEx.new()
		var compile_error := regex.compile(pattern)
		if compile_error != OK:
			errors.append("internal xacro regex error: " + pattern)
			return text
		var out := ""
		var offset := 0
		var guard := 0
		while guard < 4096:
			guard += 1
			var match := regex.search(text, offset)
			if match == null:
				break
			out += text.substr(offset, match.get_start() - offset)
			out += String(handler.call(match))
			offset = match.get_end()
		return out + text.substr(offset)

	func _attribute(attributes: String, key: String, fallback := "") -> String:
		var regex := RegEx.new()
		var compile_error := regex.compile(
			"(?:^|\\s)%s\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')" % key)
		if compile_error != OK:
			return fallback
		var match := regex.search(attributes)
		if match == null:
			return fallback
		var double_quoted := match.get_string(1)
		if not double_quoted.is_empty() or match.get_string(2).is_empty():
			return double_quoted
		return match.get_string(2)


## Tiny recursive-descent arithmetic parser for `${...}` expressions.
## Supports numbers, variables, parentheses, unary +/- and + - * / % ^ with
## the usual left-to-right precedence (^ is right-associative through unary).
class _ExprParser:
	extends RefCounted

	var failed := false

	var _source: String
	var _position := 0
	var _owner

	func _init(source: String, owner) -> void:
		_source = source.strip_edges()
		_owner = owner

	func parse() -> Variant:
		if _source.is_empty():
			_fail("empty expression")
			return null
		var value = _expression()
		_skip_space()
		if not failed and _position < _source.length():
			_fail("unexpected '%s'" % _source.substr(_position))
		if failed:
			return null
		return value

	func _expression() -> Variant:
		var value = _term()
		while not failed:
			_skip_space()
			match _peek():
				"+":
					_position += 1
					value = _number(value) + _number(_term())
				"-":
					_position += 1
					value = _number(value) - _number(_term())
				_:
					break
		return value

	func _term() -> Variant:
		var value = _unary()
		while not failed:
			_skip_space()
			match _peek():
				"*":
					_position += 1
					value = _number(value) * _number(_unary())
				"/":
					_position += 1
					var divisor := _number(_unary())
					if is_zero_approx(divisor):
						_fail("division by zero")
						return null
					value = _number(value) / divisor
				"%":
					_position += 1
					var modulo := _number(_unary())
					if is_zero_approx(modulo):
						_fail("modulo by zero")
						return null
					value = fmod(_number(value), modulo)
				_:
					break
		return value

	func _unary() -> Variant:
		_skip_space()
		match _peek():
			"-":
				_position += 1
				return -_number(_unary())
			"+":
				_position += 1
				return _unary()
		return _power()

	func _power() -> Variant:
		var value = _primary()
		_skip_space()
		if not failed and _peek() == "^":
			_position += 1
			return pow(_number(value), _number(_unary()))
		return value

	func _primary() -> Variant:
		_skip_space()
		var character := _peek()
		if character == "(":
			_position += 1
			var value = _expression()
			_skip_space()
			if _peek() != ")":
				_fail("missing ')'")
				return null
			_position += 1
			return value
		if _is_digit(character) or character == ".":
			return _number_token()
		if _is_identifier_start(character):
			var identifier := _identifier()
			_skip_space()
			if _peek() == "(":
				_position += 1
				var arguments: Array = []
				_skip_space()
				if _peek() != ")":
					while true:
						arguments.append(_expression())
						_skip_space()
						if _peek() == ",":
							_position += 1
							continue
						break
				if _peek() != ")":
					_fail("missing ')' in call to '%s'" % identifier)
					return null
				_position += 1
				return _owner._call_function(identifier, arguments)
			return _owner._lookup_variable(identifier)
		_fail("unexpected token '%s'" % character)
		return null

	func _number_token() -> Variant:
		var start := _position
		var seen_digit := false
		while _position < _source.length():
			var character := _source[_position]
			if _is_digit(character):
				seen_digit = true
				_position += 1
			elif character == ".":
				_position += 1
			elif character == "e" or character == "E":
				_position += 1
				if _position < _source.length() \
						and (_source[_position] == "+" or _source[_position] == "-"):
					_position += 1
			else:
				break
		var token := _source.substr(start, _position - start)
		if not seen_digit or not token.is_valid_float():
			_fail("invalid number '%s'" % token)
			return null
		return token.to_float()

	func _identifier() -> String:
		var start := _position
		while _position < _source.length() \
				and (_is_identifier_start(_source[_position])
					or _is_digit(_source[_position])):
			_position += 1
		return _source.substr(start, _position - start)

	func _num(value) -> float:
		if failed or value == null:
			if not failed:
				_fail("expected a number")
			return 0.0
		if value is float or value is int:
			return float(value)
		_fail("expected a number")
		return 0.0

	func _number(value) -> float:
		return _num(value)

	func _skip_space() -> void:
		while _position < _source.length() and _source[_position] in [" ", "\t"]:
			_position += 1

	func _peek() -> String:
		if _position >= _source.length():
			return ""
		return _source[_position]

	func _fail(message: String) -> void:
		if not failed:
			failed = true

	func _is_digit(character: String) -> bool:
		return character.length() == 1 and character >= "0" and character <= "9"

	func _is_identifier_start(character: String) -> bool:
		return character.length() == 1 \
			and ((character >= "a" and character <= "z")
				or (character >= "A" and character <= "Z")
				or character == "_")

