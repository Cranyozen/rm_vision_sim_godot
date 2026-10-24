class_name ScenarioSchema
extends RefCounted

## Phase 3 scenario schema: defaults, validation and normalization.
##
## `validate()` always returns a fully normalized dictionary in `data`, even
## when `ok` is false, so consumers can use the data defensively and surface
## `errors` / `warnings` to the user. Normalization rules:
## - every schema key is present with the documented type;
## - missing optional keys get their documented default (no warning);
## - a required key that is missing or has the wrong type/value is an error;
## - numeric values outside their documented range are clamped (warning);
## - unknown keys are dropped (warning) so `YamlWriter` output is stable;
## - `number` is always a String (`3` is coerced to "3", `"3"` is kept);
## - `motion.waypoints` is dropped for `type: spin` (warning).
##
## Motion semantics (the contract implemented by the Phase 3 motion layer):
## - static:   no movement; the target keeps `position` / `yaw_deg`.
## - line:     straight segment between the first two waypoints (later ones are
##             ignored). `once` stops at the end, `loop` runs the closing
##             segment back to the first waypoint, `pingpong` reverses at both
##             ends. A line with a single waypoint is a validation error; a
##             tolerant consumer may treat it as `position -> waypoint`.
## - polyline: the waypoints in order; `loop` adds the closing segment back to
##             the first waypoint, `pingpong` reverses at both ends, `once`
##             stops at the last waypoint.
## - spin:     yaw rotates at `spin_deg_s` (negative = the other direction),
##             position stays fixed and waypoints are ignored. `once` turns one
##             full 360 deg and stops, `loop` spins continuously, `pingpong`
##             sweeps between `yaw0 - 180` and `yaw0 + 180`.
##
## `position` / `waypoints` are Godot world metres (Y is up); `y` is ignored at
## runtime but kept exactly as authored. All angles are degrees.


const SCHEMA_VERSION := 1

const DEFAULT_NAME := "untitled"

const FIELD_IDS := ["rmul2027_1v1", "rmul2027_3v3", "flat"]
const ROS_BACKENDS := ["rclgd"]
const RAW_ENCODINGS := ["rgb8", "bayer_rggb8"]
const CAMERA_PRESETS := ["qyg", "cad", "qyg_trim"]
const EGO_MODELS := ["vehicle", "infantry_light"]
const TEAMS := ["red", "blue"]
const ARMOR_SIZES := ["small", "large"]
const LOWER_GROUPS := ["x", "y"]
const MOTION_TYPES := ["static", "line", "polyline", "spin"]
const MOTION_MODES := ["once", "loop", "pingpong"]

const RAW_HZ_RANGE := Vector2(1.0, 120.0)
const COMPRESSED_HZ_RANGE := Vector2(1.0, 240.0)
const JPEG_QUALITY_RANGE := Vector2(1.0, 100.0)
const FPV_FOV_RANGE := Vector2(30.0, 120.0)
const GROUP_HEIGHT_OFFSET_RANGE := Vector2(0.0, 0.1)

## Minimum speed used when a scenario asks for zero / negative motion speed.
const MIN_SPEED := 0.01

const TOP_KEYS := [
	"schema_version", "name", "field", "ros", "camera", "ego", "targets",
]
const ROS_KEYS := [
	"backend", "raw_encoding", "raw_hz", "compressed_hz", "jpeg_quality",
	"enabled",
]
const CAMERA_KEYS := ["preset", "yaw_offset_deg", "fpv_fov_deg"]
const EGO_KEYS := ["model", "position", "yaw_deg"]
const TARGET_KEYS := [
	"id", "team", "armor", "number", "position", "yaw_deg", "armor_layout",
	"motion",
]
const ARMOR_LAYOUT_KEYS := [
	"center_height_m", "group_height_offset_m", "x_group_span_m",
	"y_group_span_m", "lower_group",
]
const MOTION_KEYS := ["type", "waypoints", "speed", "mode", "spin_deg_s"]


## Complete default scenario: a static 1v1 with no targets.
static func defaults() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"name": DEFAULT_NAME,
		"field": "rmul2027_1v1",
		"ros": {
			"backend": "rclgd",
			"raw_encoding": "rgb8",
			"raw_hz": 30.0,
			"compressed_hz": 60.0,
			"jpeg_quality": 90,
			"enabled": true,
		},
		"camera": {
			"preset": "qyg",
			"yaw_offset_deg": 0.0,
			"fpv_fov_deg": 70.0,
		},
		"ego": {
			"model": "vehicle",
			"position": [0.0, 0.0, 2.2],
			"yaw_deg": 0.0,
		},
		"targets": [],
	}


## Defaults for one target; `index` is the 1-based target index used by the
## generated `t<N>` id.
static func target_defaults(index: int = 1) -> Dictionary:
	return {
		"id": "t%d" % index,
		"team": "",
		"armor": "",
		"number": "",
		"position": [0.0, 0.0, -1.4],
		"yaw_deg": 0.0,
		"armor_layout": {
			"center_height_m": 0.25,
			"group_height_offset_m": 0.05,
			"x_group_span_m": 0.0,
			"y_group_span_m": 0.0,
			"lower_group": "x",
		},
		"motion": {
			"type": "static",
			"waypoints": [],
			"speed": 1.0,
			"mode": "once",
			"spin_deg_s": 90.0,
		},
	}


## Validate and normalize a parsed scenario.
##
## Returns {"ok": bool, "errors": PackedStringArray, "warnings":
## PackedStringArray, "data": Dictionary}. `data` is always a complete,
## normalized scenario dictionary.
static func validate(data: Variant) -> Dictionary:
	var errors := PackedStringArray()
	var warnings := PackedStringArray()
	var out := defaults()

	if typeof(data) != TYPE_DICTIONARY:
		errors.append("scenario: expected a mapping, got %s" % _type_name(data))
		return _result(errors, warnings, out)
	var src: Dictionary = data

	_unknown_keys(src, TOP_KEYS, "", warnings)

	# --- version / identity ------------------------------------------------
	var version := _int_field(src, "schema_version", "", SCHEMA_VERSION, 0, 0,
		errors, warnings, false)
	out["schema_version"] = version
	if version != SCHEMA_VERSION:
		errors.append("schema_version: unsupported version %d (expected %d)"
			% [version, SCHEMA_VERSION])

	out["name"] = _string_field(src, "name", "", DEFAULT_NAME, errors)
	out["field"] = _enum_field(src, "field", FIELD_IDS, "", "rmul2027_1v1",
		errors)

	# --- ros ---------------------------------------------------------------
	var ros_src := _section(src, "ros", "", errors)
	if _is_mapping(src, "ros"):
		_unknown_keys(ros_src, ROS_KEYS, "ros", warnings)
	var ros: Dictionary = out["ros"]
	ros["backend"] = _enum_field(ros_src, "backend", ROS_BACKENDS, "ros",
		"rclgd", errors)
	ros["raw_encoding"] = _enum_field(ros_src, "raw_encoding", RAW_ENCODINGS,
		"ros", "rgb8", errors)
	ros["raw_hz"] = _clamped_float(ros_src, "raw_hz", "ros", 30.0,
		RAW_HZ_RANGE, errors, warnings)
	ros["compressed_hz"] = _clamped_float(ros_src, "compressed_hz", "ros",
		60.0, COMPRESSED_HZ_RANGE, errors, warnings)
	ros["jpeg_quality"] = _clamped_int(ros_src, "jpeg_quality", "ros", 90,
		JPEG_QUALITY_RANGE, errors, warnings)
	ros["enabled"] = _bool_field(ros_src, "enabled", "ros", true, errors)

	# --- camera ------------------------------------------------------------
	var camera_src := _section(src, "camera", "", errors)
	if _is_mapping(src, "camera"):
		_unknown_keys(camera_src, CAMERA_KEYS, "camera", warnings)
	var camera: Dictionary = out["camera"]
	camera["preset"] = _enum_field(camera_src, "preset", CAMERA_PRESETS,
		"camera", "qyg", errors)
	camera["yaw_offset_deg"] = _float_field(camera_src, "yaw_offset_deg",
		"camera", 0.0, 0.0, 0.0, errors, warnings, false)
	camera["fpv_fov_deg"] = _clamped_float(camera_src, "fpv_fov_deg",
		"camera", 70.0, FPV_FOV_RANGE, errors, warnings)

	# --- ego ---------------------------------------------------------------
	var ego_src := _section(src, "ego", "", errors)
	if _is_mapping(src, "ego"):
		_unknown_keys(ego_src, EGO_KEYS, "ego", warnings)
	var ego: Dictionary = out["ego"]
	ego["model"] = _enum_field(ego_src, "model", EGO_MODELS, "ego", "vehicle",
		errors)
	ego["position"] = _vector3_field(ego_src, "position", "ego",
		[0.0, 0.0, 2.2], errors)
	ego["yaw_deg"] = _float_field(ego_src, "yaw_deg", "ego", 0.0, 0.0, 0.0,
		errors, warnings, false)

	# --- targets -----------------------------------------------------------
	out["targets"] = _targets_field(src, errors, warnings)

	return _result(errors, warnings, out)


# --- targets -----------------------------------------------------------------

static func _targets_field(src: Dictionary, errors: PackedStringArray,
		warnings: PackedStringArray) -> Array:
	var raw: Variant = []
	if src.has("targets"):
		raw = src["targets"]
	if typeof(raw) != TYPE_ARRAY:
		errors.append("targets: expected a list, got %s" % _type_name(raw))
		return []

	var targets: Array = []
	var seen_ids: Dictionary = {}
	for i in raw.size():
		var entry: Variant = raw[i]
		var item_path := "targets[%d]" % i
		if typeof(entry) != TYPE_DICTIONARY:
			errors.append("%s: expected a mapping, got %s"
				% [item_path, _type_name(entry)])
			continue
		var target := _target_field(entry, i + 1, item_path, errors, warnings)
		var target_id := String(target["id"])
		if seen_ids.has(target_id):
			warnings.append("%s.id: duplicate id '%s'" % [item_path, target_id])
		seen_ids[target_id] = true
		targets.append(target)
	return targets


static func _target_field(src: Dictionary, index: int, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	_unknown_keys(src, TARGET_KEYS, path, warnings)
	var target := target_defaults(index)
	target["id"] = _string_field(src, "id", path, String(target["id"]), errors)
	if String(target["id"]).is_empty():
		errors.append("%s.id: must not be empty" % path)
		target["id"] = "t%d" % index
	target["team"] = _required_enum(src, "team", TEAMS, path, errors)
	target["armor"] = _required_enum(src, "armor", ARMOR_SIZES, path, errors)
	target["number"] = _number_string_field(src, "number", path, errors)
	target["position"] = _vector3_field(src, "position", path,
		[0.0, 0.0, -1.4], errors)
	target["yaw_deg"] = _float_field(src, "yaw_deg", path, 0.0, 0.0, 0.0,
		errors, warnings, false)
	target["armor_layout"] = _armor_layout_field(src, path, errors, warnings)
	target["motion"] = _motion_field(src, path, errors, warnings)
	return target


static func _armor_layout_field(src: Dictionary, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	var section_path := "%s.armor_layout" % path
	var layout_src := _section(src, "armor_layout", path, errors)
	if _is_mapping(src, "armor_layout"):
		_unknown_keys(layout_src, ARMOR_LAYOUT_KEYS, section_path, warnings)
	var layout: Dictionary = target_defaults()["armor_layout"]
	layout["center_height_m"] = _float_field(layout_src, "center_height_m",
		section_path, 0.25, 0.0, 0.0, errors, warnings, false)
	layout["group_height_offset_m"] = _clamped_float(layout_src,
		"group_height_offset_m", section_path, 0.05,
		GROUP_HEIGHT_OFFSET_RANGE, errors, warnings)
	# Group spans: 0 means auto, so only the lower bound is enforced.
	layout["x_group_span_m"] = _min_clamped_float(layout_src, "x_group_span_m",
		section_path, 0.0, 0.0, errors, warnings)
	layout["y_group_span_m"] = _min_clamped_float(layout_src, "y_group_span_m",
		section_path, 0.0, 0.0, errors, warnings)
	layout["lower_group"] = _enum_field(layout_src, "lower_group", LOWER_GROUPS,
		section_path, "x", errors)
	return layout


static func _motion_field(src: Dictionary, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	var motion_path := "%s.motion" % path
	var motion_src := _section(src, "motion", path, errors)
	if _is_mapping(src, "motion"):
		_unknown_keys(motion_src, MOTION_KEYS, motion_path, warnings)
	var motion: Dictionary = target_defaults()["motion"]
	var motion_type := _enum_field(motion_src, "type", MOTION_TYPES, motion_path,
		"static", errors)
	motion["type"] = motion_type
	motion["mode"] = _enum_field(motion_src, "mode", MOTION_MODES, motion_path,
		"once", errors)
	motion["speed"] = _positive_float_field(motion_src, "speed", motion_path,
		1.0, errors, warnings)
	motion["spin_deg_s"] = _float_field(motion_src, "spin_deg_s", motion_path,
		90.0, 0.0, 0.0, errors, warnings, false)
	var waypoints := _waypoints_field(motion_src, "waypoints", motion_path,
		errors)
	if motion_type == "spin":
		if not waypoints.is_empty():
			warnings.append("%s.waypoints: ignored for type 'spin' (dropped)"
				% motion_path)
		waypoints = []
	elif (motion_type == "line" or motion_type == "polyline") \
			and waypoints.size() < 2:
		errors.append("%s.waypoints: type '%s' needs at least 2 waypoints, got %d"
			% [motion_path, motion_type, waypoints.size()])
	motion["waypoints"] = waypoints
	return motion


# --- field helpers -----------------------------------------------------------

static func _result(errors: PackedStringArray, warnings: PackedStringArray,
		data: Dictionary) -> Dictionary:
	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"data": data,
	}


static func _section(src: Dictionary, key: String, path: String,
		errors: PackedStringArray) -> Dictionary:
	if not src.has(key):
		return {}
	var value: Variant = src[key]
	if typeof(value) == TYPE_DICTIONARY:
		return value
	var field_path := _field_path(path, key)
	errors.append("%s: expected a mapping, got %s"
		% [field_path, _type_name(value)])
	return {}


static func _is_mapping(src: Dictionary, key: String) -> bool:
	return src.has(key) and typeof(src[key]) == TYPE_DICTIONARY


static func _string_field(src: Dictionary, key: String, path: String,
		fallback: String, errors: PackedStringArray) -> String:
	if not src.has(key):
		return fallback
	var value: Variant = src[key]
	if typeof(value) == TYPE_STRING:
		return String(value)
	var field_path := _field_path(path, key)
	errors.append("%s: expected a string, got %s"
		% [field_path, _type_name(value)])
	return fallback


## Target number: kept as a String, but a bare YAML number is coerced.
static func _number_string_field(src: Dictionary, key: String, path: String,
		errors: PackedStringArray) -> String:
	if not src.has(key):
		errors.append("%s: missing required value (target number as a string)"
			% _field_path(path, key))
		return ""
	var value: Variant = src[key]
	match typeof(value):
		TYPE_STRING:
			if String(value).is_empty():
				errors.append("%s: must not be empty"
					% _field_path(path, key))
			return String(value)
		TYPE_INT:
			return str(int(value))
		TYPE_FLOAT:
			return _fmt(float(value))
		_:
			errors.append("%s: expected a string, got %s"
				% [_field_path(path, key), _type_name(value)])
			return ""


static func _enum_field(src: Dictionary, key: String, allowed: Array,
		path: String, fallback: String, errors: PackedStringArray) -> String:
	if not src.has(key):
		return fallback
	var value: Variant = src[key]
	var field_path := _field_path(path, key)
	if typeof(value) != TYPE_STRING:
		errors.append("%s: expected a string, got %s"
			% [field_path, _type_name(value)])
		return fallback
	var text := String(value)
	if not allowed.has(text):
		errors.append("%s: unknown value '%s' (expected one of %s)"
			% [field_path, text, _join(allowed)])
		return fallback
	return text


static func _required_enum(src: Dictionary, key: String, allowed: Array,
		path: String, errors: PackedStringArray) -> String:
	if not src.has(key):
		errors.append("%s: missing required value (expected one of %s)"
			% [_field_path(path, key), _join(allowed)])
		return ""
	return _enum_field(src, key, allowed, path, "", errors)


static func _bool_field(src: Dictionary, key: String, path: String,
		fallback: bool, errors: PackedStringArray) -> bool:
	if not src.has(key):
		return fallback
	var value: Variant = src[key]
	if typeof(value) == TYPE_BOOL:
		return bool(value)
	errors.append("%s: expected a boolean, got %s"
		% [_field_path(path, key), _type_name(value)])
	return fallback


static func _int_field(src: Dictionary, key: String, path: String,
		fallback: int, low: float, high: float, errors: PackedStringArray,
		warnings: PackedStringArray, use_range: bool = true) -> int:
	if not src.has(key):
		return fallback
	var value: Variant = src[key]
	var field_path := _field_path(path, key)
	var number := 0
	match typeof(value):
		TYPE_INT:
			number = int(value)
		TYPE_FLOAT:
			var as_float := float(value)
			if not is_equal_approx(as_float, roundf(as_float)):
				errors.append("%s: expected an integer, got %s"
					% [field_path, _fmt(as_float)])
				return fallback
			number = int(roundf(as_float))
		_:
			errors.append("%s: expected an integer, got %s"
				% [field_path, _type_name(value)])
			return fallback
	if use_range:
		var clamped := int(clampf(float(number), low, high))
		if clamped != number:
			warnings.append("%s: %d out of range [%s, %s]; clamped to %d"
				% [field_path, number, _fmt(low), _fmt(high), clamped])
			number = clamped
	return number


static func _float_field(src: Dictionary, key: String, path: String,
		fallback: float, low: float, high: float, errors: PackedStringArray,
		warnings: PackedStringArray, use_range: bool = true) -> float:
	if not src.has(key):
		return fallback
	var value: Variant = src[key]
	var field_path := _field_path(path, key)
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		errors.append("%s: expected a number, got %s"
			% [field_path, _type_name(value)])
		return fallback
	var number := float(value)
	if is_nan(number) or is_inf(number):
		errors.append("%s: expected a finite number" % field_path)
		return fallback
	if not use_range:
		return number
	var clamped := clampf(number, low, high)
	if not is_equal_approx(clamped, number):
		warnings.append("%s: %s out of range [%s, %s]; clamped to %s"
			% [field_path, _fmt(number), _fmt(low), _fmt(high),
				_fmt(clamped)])
	return clamped


static func _clamped_float(src: Dictionary, key: String, path: String,
		fallback: float, range_value: Vector2, errors: PackedStringArray,
		warnings: PackedStringArray) -> float:
	return _float_field(src, key, path, fallback, range_value.x,
		range_value.y, errors, warnings)


static func _clamped_int(src: Dictionary, key: String, path: String,
		fallback: int, range_value: Vector2, errors: PackedStringArray,
		warnings: PackedStringArray) -> int:
	return _int_field(src, key, path, fallback, range_value.x,
		range_value.y, errors, warnings)


## Lower-bound-only clamp (used by the group spans, where 0 means "auto").
static func _min_clamped_float(src: Dictionary, key: String, path: String,
		fallback: float, low: float, errors: PackedStringArray,
		warnings: PackedStringArray) -> float:
	if not src.has(key):
		return fallback
	return _float_field(src, key, path, fallback, low, INF, errors, warnings)


## Motion speed must be strictly positive; zero / negative is clamped.
static func _positive_float_field(src: Dictionary, key: String, path: String,
		fallback: float, errors: PackedStringArray,
		warnings: PackedStringArray) -> float:
	if not src.has(key):
		return fallback
	var field_path := _field_path(path, key)
	var value: Variant = src[key]
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		errors.append("%s: expected a number, got %s"
			% [field_path, _type_name(value)])
		return fallback
	var number := float(value)
	if is_nan(number) or is_inf(number):
		errors.append("%s: expected a finite number" % field_path)
		return fallback
	if number <= 0.0:
		warnings.append("%s: %s must be > 0; clamped to %s"
			% [field_path, _fmt(number), _fmt(MIN_SPEED)])
		return MIN_SPEED
	return number


static func _vector3_field(src: Dictionary, key: String, path: String,
		fallback: Array, errors: PackedStringArray) -> Array:
	if not src.has(key):
		return fallback.duplicate()
	var value: Variant = src[key]
	var field_path := _field_path(path, key)
	if typeof(value) != TYPE_ARRAY or value.size() != 3:
		errors.append("%s: expected [x, y, z], got %s"
			% [field_path, _describe(value)])
		return fallback.duplicate()
	var out: Array = []
	var array: Array = value
	for i in 3:
		var component: Variant = array[i]
		if typeof(component) == TYPE_INT or typeof(component) == TYPE_FLOAT:
			out.append(float(component))
		else:
			errors.append("%s[%d]: expected a number, got %s"
				% [field_path, i, _type_name(component)])
			out.append(float(fallback[i]))
	return out


static func _waypoints_field(src: Dictionary, key: String, path: String,
		errors: PackedStringArray) -> Array:
	if not src.has(key):
		return []
	var value: Variant = src[key]
	var field_path := _field_path(path, key)
	if typeof(value) != TYPE_ARRAY:
		errors.append("%s: expected a list of [x, y, z], got %s"
			% [field_path, _type_name(value)])
		return []
	var out: Array = []
	for i in value.size():
		var entry: Variant = value[i]
		if typeof(entry) != TYPE_ARRAY or entry.size() != 3:
			errors.append("%s[%d]: expected [x, y, z], got %s"
				% [field_path, i, _describe(entry)])
			out.append([0.0, 0.0, 0.0])
			continue
		var point: Array = []
		var array: Array = entry
		for j in 3:
			var component: Variant = array[j]
			if typeof(component) == TYPE_INT \
					or typeof(component) == TYPE_FLOAT:
				point.append(float(component))
			else:
				errors.append("%s[%d][%d]: expected a number, got %s"
					% [field_path, i, j, _type_name(component)])
				point.append(0.0)
		out.append(point)
	return out


static func _unknown_keys(src: Dictionary, allowed: Array, path: String,
		warnings: PackedStringArray) -> void:
	var where := "scenario" if path.is_empty() else path
	for key: Variant in src.keys():
		var key_name := str(key)
		if allowed.has(key_name):
			continue
		warnings.append("%s: unknown key '%s' (dropped)" % [where, key_name])


# --- formatting --------------------------------------------------------------

static func _field_path(path: String, key: String) -> String:
	if path.is_empty():
		return key
	return "%s.%s" % [path, key]


## Human-readable number for messages ("30", "0.05", "2.5").
static func _fmt(value: float) -> String:
	return String.num(value)


static func _join(values: Array) -> String:
	var text := ""
	for i in values.size():
		if i > 0:
			text += ", "
		text += str(values[i])
	return text


static func _describe(value: Variant) -> String:
	if typeof(value) == TYPE_ARRAY:
		return "a list of %d items" % (value as Array).size()
	if typeof(value) == TYPE_NIL:
		return "null"
	return _type_name(value)


static func _type_name(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "a boolean"
		TYPE_INT:
			return "an integer"
		TYPE_FLOAT:
			return "a number"
		TYPE_STRING:
			return "a string"
		TYPE_ARRAY:
			return "a list"
		TYPE_DICTIONARY:
			return "a mapping"
		_:
			return type_string(typeof(value))
