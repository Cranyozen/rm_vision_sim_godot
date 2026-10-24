class_name YamlWriter
extends RefCounted

## Deterministic YAML output for scenarios.
##
## `dump()` writes the schema keys in a fixed order with 2-space indentation
## and stable number formatting, so the same normalized scenario always
## produces byte-identical text. `dump(parse(dump(data)))` is the same
## normalized dictionary and the same text.
##
## All strings are double-quoted (target numbers such as "3" must stay
## strings); booleans are lower-case; floats always keep a decimal point so
## they re-parse as floats.

const ScenarioSchema := preload("res://scripts/scenario/ScenarioSchema.gd")

const INDENT := "  "

const TOP_SCALAR_ORDER := ["schema_version", "name", "field"]
const ROS_ORDER := [
	"backend", "raw_encoding", "raw_hz", "compressed_hz", "jpeg_quality",
	"enabled",
]
const CAMERA_ORDER := ["preset", "yaw_offset_deg", "fpv_fov_deg"]
const EGO_ORDER := ["model", "position", "yaw_deg"]
const TARGET_SCALAR_ORDER := ["team", "armor", "number", "position", "yaw_deg"]
const ARMOR_LAYOUT_ORDER := [
	"center_height_m", "group_height_offset_m", "x_group_span_m",
	"y_group_span_m", "lower_group",
]
const MOTION_TRAILER_ORDER := ["speed", "mode", "spin_deg_s"]


## Serialize a scenario dictionary (it is normalized first, so partial
## dictionaries are accepted and unknown keys are dropped).
static func dump(data: Dictionary) -> String:
	var scenario: Dictionary = ScenarioSchema.validate(data)["data"]
	var lines := PackedStringArray()

	_add_scalars(lines, "", TOP_SCALAR_ORDER, scenario)

	lines.append("ros:")
	_add_scalars(lines, INDENT, ROS_ORDER, scenario["ros"])
	lines.append("camera:")
	_add_scalars(lines, INDENT, CAMERA_ORDER, scenario["camera"])
	lines.append("ego:")
	_add_scalars(lines, INDENT, EGO_ORDER, scenario["ego"])

	var targets: Array = scenario["targets"]
	if targets.is_empty():
		lines.append("targets: []")
	else:
		lines.append("targets:")
		for target: Dictionary in targets:
			_append_target(lines, target)

	return "\n".join(lines) + "\n"


## Write `data` as a scenario file (UTF-8, `dump()` text). Missing parent
## directories are created. Returns Godot's `Error` (`OK` on success).
static func save(path: String, data: Dictionary) -> Error:
	var directory := path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		var made := DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			return made
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(dump(data))
	file.close()
	return OK


# --- layout ------------------------------------------------------------------

static func _append_target(lines: PackedStringArray, target: Dictionary) -> void:
	var target_indent := INDENT
	lines.append("%s- id: %s" % [target_indent, _scalar(target["id"])])
	var field_indent := target_indent + INDENT
	_add_scalars(lines, field_indent, TARGET_SCALAR_ORDER, target)

	lines.append("%sarmor_layout:" % field_indent)
	_add_scalars(lines, field_indent + INDENT, ARMOR_LAYOUT_ORDER,
		target["armor_layout"])

	var motion: Dictionary = target["motion"]
	lines.append("%smotion:" % field_indent)
	var motion_indent := field_indent + INDENT
	lines.append("%stype: %s" % [motion_indent, _scalar(motion["type"])])
	var waypoints: Array = motion["waypoints"]
	if waypoints.is_empty():
		lines.append("%swaypoints: []" % motion_indent)
	else:
		lines.append("%swaypoints:" % motion_indent)
		var point_indent := motion_indent + INDENT
		for point: Array in waypoints:
			lines.append("%s- %s" % [point_indent, _inline_array(point)])
	for key: String in MOTION_TRAILER_ORDER:
		lines.append("%s%s: %s" % [motion_indent, key, _scalar(motion[key])])


static func _add_scalars(lines: PackedStringArray, indent: String,
		order: Array, source: Dictionary) -> void:
	for key: String in order:
		lines.append("%s%s: %s" % [indent, key, _scalar(source[key])])


# --- scalars -----------------------------------------------------------------

static func _scalar(value: Variant) -> String:
	match typeof(value):
		TYPE_STRING:
			return _quote(String(value))
		TYPE_INT:
			return str(int(value))
		TYPE_FLOAT:
			return _format_float(float(value))
		TYPE_BOOL:
			return "true" if bool(value) else "false"
		TYPE_ARRAY:
			return _inline_array(value)
		_:
			return _quote(str(value))


static func _inline_array(value: Array) -> String:
	var parts := PackedStringArray()
	for item: Variant in value:
		parts.append(_scalar(item))
	return "[" + ", ".join(parts) + "]"


## Stable float text: use the shortest round-tripping representation and make
## sure the value re-parses as a float ("1" -> "1.0").
static func _format_float(value: float) -> String:
	var text := String.num(value)
	if text.to_float() != value:
		for decimals in range(7, 18):
			text = String.num(value, decimals)
			if text.to_float() == value:
				break
	if not text.contains(".") and not text.contains("e") \
			and not text.contains("E"):
		text += ".0"
	return text


static func _quote(text: String) -> String:
	var escaped := text.replace("\\", "\\\\")
	escaped = escaped.replace("\"", "\\\"")
	escaped = escaped.replace("\n", "\\n")
	escaped = escaped.replace("\t", "\\t")
	escaped = escaped.replace("\r", "\\r")
	return "\"" + escaped + "\""
