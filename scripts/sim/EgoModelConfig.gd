class_name EgoModelConfig
extends RefCounted

## Ego robot model profile library.
##
## Every ego robot (full vehicle, light infantry chassis, debug boxes, ...) is
## described by one YAML file under `config/ego/`. `EgoRig` consumes the
## normalized profile dictionary, so adding a robot means adding a file, not
## writing a new builder branch.
##
## File schema (all keys optional unless noted):
##
##   schema_version: 1                # required, must be 1
##   id: vehicle                      # required, unique; scenario `ego.model`
##   display_name: Vehicle            # UI / diagnostics label
##   scene_path: res://...glb         # required, Godot-imported scene
##   unit_scale: 1.0                  # 0.001 for millimetre assets
##   floor_offset_m: 0.2101           # lift so the chassis bottom sits on y = 0
##   gimbal_node: GIMBAL              # pitch pivot node inside the scene; "" = none
##   gimbal_yaw_node: ""              # optional separate yaw pivot (two-axis gimbal)
##   gimbal_rest_pitch_deg: -25.0     # install pitch baked into the visual head
##   gimbal_visual_offset_m: [0,0,0]  # translation of the compensated pivot
##   marker_nodes: [CAM_DIRECTION, SHOT_DIRECTION]  # never compensated
##   camera_marker_node: CAM_DIRECTION  # eye-position empty ("" = none)
##   camera_mount_fallback_m: [0,0,0]   # eye position when the marker is absent
##   hide_node_prefixes: [...]        # imported nodes hidden at load time
##   synthetic_gimbal:                # optional, for chassis-only assets
##     yaw_joint_m: [0, 0.152, 0]
##     pitch_joint_m: [0, 0.045, 0]
##     camera_mount_m: [0, 0.035, -0.11]
##     parts:
##       - name: PITCH_BODY
##         attach: pitch              # model | yaw | pitch
##         shape: box                 # box | cylinder
##         size: [0.16, 0.075, 0.13]  # box
##         radius: 0.055              # cylinder
##         height: 0.035              # cylinder
##         position: [0, 0.02, -0.02]
##         rotation_deg: [0, 0, 0]
##         color: [0.06, 0.07, 0.08, 1.0]
##
## Phase 5 adds two optional blocks. A profile may be backed by a URDF/SDF
## robot description instead of an imported GLB scene (`scene_path` is then
## optional); the rig loads the description, drives the named joints and takes
## the camera mount from the optical frame:
##
##   robot_description:
##     format: urdf                 # urdf | sdf
##     path: res://assets/robots/phase5_gimbal/robot.urdf
##     mesh_root: ""                # optional mesh remap root (default: path dir)
##     yaw_joint: gimbal_yaw_joint  # revolute joint driven by EgoRig yaw
##     pitch_joint: gimbal_pitch_joint  # revolute joint driven by EgoRig pitch
##     camera_link: camera_link     # optional ROS camera_link frame
##     camera_optical_frame: camera_optical_frame  # optional REP-103 optical frame
##
## The standard model contract: metres, Y up, forward = -Z at yaw 0, origin at
## the chassis centre on the ground, a gimbal pivot node (`GIMBAL`) and a
## `CAM_DIRECTION` empty under it. Assets that do not follow it (chassis-only
## GLBs) can declare `synthetic_gimbal` instead; the rig then builds the pivot
## chain and the camera mount from the profile.

const MODEL_DIR := SimConfig.EGO_PROFILE_DIR
const SCHEMA_VERSION := 1

const DEFAULTS := {
	"schema_version": SCHEMA_VERSION,
	"id": "",
	"display_name": "",
	"scene_path": "",
	"unit_scale": 1.0,
	"floor_offset_m": 0.0,
	"gimbal_node": "GIMBAL",
	"gimbal_yaw_node": "",
	"gimbal_rest_pitch_deg": 0.0,
	"gimbal_visual_offset_m": [0.0, 0.0, 0.0],
	"marker_nodes": ["CAM_DIRECTION", "SHOT_DIRECTION"],
	"camera_marker_node": SimConfig.CAM_DIRECTION_NODE,
	"camera_mount_fallback_m": [0.0, 0.0, 0.0],
	"hide_node_prefixes": [],
	"synthetic_gimbal": {},
	"robot_description": {},
}

const ROBOT_DESCRIPTION_DEFAULTS := {
	"format": "",
	"path": "",
	"mesh_root": "",
	"yaw_joint": "",
	"pitch_joint": "",
	"camera_link": "",
	"camera_optical_frame": "",
}

const ROBOT_DESCRIPTION_FORMATS := ["urdf", "sdf"]

const SYNTHETIC_DEFAULTS := {
	"yaw_joint_m": [0.0, 0.0, 0.0],
	"pitch_joint_m": [0.0, 0.0, 0.0],
	"camera_mount_m": [0.0, 0.0, 0.0],
	"parts": [],
}

const PART_DEFAULTS := {
	"name": "PART",
	"attach": "pitch",
	"shape": "box",
	"size": [0.1, 0.1, 0.1],
	"radius": 0.05,
	"height": 0.1,
	"position": [0.0, 0.0, 0.0],
	"rotation_deg": [0.0, 0.0, 0.0],
	"color": [0.08, 0.09, 0.10, 1.0],
}

static var _library: Dictionary = {}


## Load (and cache) every profile under `config/ego/`.
## Returns {"ok": bool, "errors": PackedStringArray, "warnings":
## PackedStringArray, "profiles": {id: profile}}.
static func load_library(force_reload: bool = false) -> Dictionary:
	if not force_reload and not _library.is_empty():
		return _library
	var result := {
		"ok": true,
		"errors": PackedStringArray(),
		"warnings": PackedStringArray(),
		"profiles": {},
	}
	var errors: PackedStringArray = result["errors"]
	var warnings: PackedStringArray = result["warnings"]
	var profiles: Dictionary = result["profiles"]

	var dir := DirAccess.open(MODEL_DIR)
	if dir == null:
		errors.append("ego model dir not found: %s" % MODEL_DIR)
		result["ok"] = false
		_library = result
		return result

	var names: Array[String] = []
	for file_name in dir.get_files():
		if file_name.ends_with(".yaml") or file_name.ends_with(".yml"):
			names.append(file_name)
	names.sort()
	if names.is_empty():
		errors.append("no ego model profiles under %s" % MODEL_DIR)
		result["ok"] = false

	for file_name in names:
		var path := MODEL_DIR.path_join(file_name)
		var parsed := _read_yaml(path, errors)
		if parsed.is_empty():
			continue
		var normalized := normalize(parsed, path, errors, warnings)
		var id := String(normalized["id"])
		if id.is_empty():
			continue
		if profiles.has(id):
			errors.append("duplicate ego model id '%s' (%s)" % [id, path])
			continue
		profiles[id] = normalized

	if profiles.is_empty():
		result["ok"] = false
	_library = result
	return result


## Drop the cache; the next `load_library()` re-reads the YAML files.
static func reload() -> Dictionary:
	_library = {}
	return load_library()


## One normalized profile, or {} when unknown.
static func profile(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	var library := load_library()
	var profiles: Dictionary = library.get("profiles", {})
	return profiles.get(id, {})


## Sorted profile ids (for scenario validation / UI lists).
static func model_ids() -> Array[String]:
	var library := load_library()
	var profiles: Dictionary = library.get("profiles", {})
	var out: Array[String] = []
	for id in profiles.keys():
		out.append(String(id))
	out.sort()
	return out


## Fallback id when nothing is configured: "vehicle", else the first profile.
static func default_model_id() -> String:
	var ids := model_ids()
	if ids.has(SimConfig.EGO_DEFAULT_MODEL):
		return SimConfig.EGO_DEFAULT_MODEL
	return ids[0] if not ids.is_empty() else SimConfig.EGO_DEFAULT_MODEL


## Normalize a parsed profile dictionary to the documented schema.
static func normalize(data: Variant, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	var out := DEFAULTS.duplicate(true)
	if typeof(data) != TYPE_DICTIONARY:
		errors.append("%s: profile root must be a mapping" % path)
		return out
	var src: Dictionary = data

	var version := int(_float(src.get("schema_version"), SCHEMA_VERSION))
	out["schema_version"] = version
	if version != SCHEMA_VERSION:
		errors.append("%s: unsupported schema_version %d (expected %d)"
			% [path, version, SCHEMA_VERSION])

	out["id"] = _string(src.get("id"), "")
	if out["id"].is_empty():
		errors.append("%s: missing required key 'id'" % path)
	out["display_name"] = _string(src.get("display_name"), String(out["id"]))
	out["scene_path"] = _string(src.get("scene_path"), "")
	out["robot_description"] = _normalize_robot_description(
		src.get("robot_description"), path, errors, warnings)
	var description_path := String(out["robot_description"]["path"])
	if out["scene_path"].is_empty() and description_path.is_empty():
		errors.append("%s: missing required key 'scene_path' (or robot_description.path)"
			% path)
	elif not out["scene_path"].is_empty() and not FileAccess.file_exists(out["scene_path"]):
		errors.append("%s: scene_path not found: %s" % [path, out["scene_path"]])

	out["unit_scale"] = _float(src.get("unit_scale"), 1.0)
	if out["unit_scale"] <= 0.0:
		errors.append("%s: unit_scale must be > 0" % path)
		out["unit_scale"] = 1.0
	out["floor_offset_m"] = _float(src.get("floor_offset_m"), 0.0)
	out["gimbal_node"] = _string(src.get("gimbal_node"), "GIMBAL")
	out["gimbal_yaw_node"] = _string(src.get("gimbal_yaw_node"), "")
	out["gimbal_rest_pitch_deg"] = _float(src.get("gimbal_rest_pitch_deg"), 0.0)
	out["gimbal_visual_offset_m"] = _vec3(src.get("gimbal_visual_offset_m"), [0.0, 0.0, 0.0])
	out["marker_nodes"] = _string_array(src.get("marker_nodes"),
		["CAM_DIRECTION", "SHOT_DIRECTION"])
	out["camera_marker_node"] = _string(src.get("camera_marker_node"),
		SimConfig.CAM_DIRECTION_NODE)
	out["camera_mount_fallback_m"] = _vec3(src.get("camera_mount_fallback_m"),
		[0.0, 0.0, 0.0])
	out["hide_node_prefixes"] = _string_array(src.get("hide_node_prefixes"), [])
	out["synthetic_gimbal"] = _normalize_synthetic(src.get("synthetic_gimbal"), path,
		errors, warnings)

	_unknown_keys(src, DEFAULTS.keys(), path, warnings)
	return out


static func _normalize_synthetic(value: Variant, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	if value == null:
		return {}
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s: synthetic_gimbal must be a mapping" % path)
		return {}
	var src: Dictionary = value
	var out := SYNTHETIC_DEFAULTS.duplicate(true)
	out["yaw_joint_m"] = _vec3(src.get("yaw_joint_m"), [0.0, 0.0, 0.0])
	out["pitch_joint_m"] = _vec3(src.get("pitch_joint_m"), [0.0, 0.0, 0.0])
	out["camera_mount_m"] = _vec3(src.get("camera_mount_m"), [0.0, 0.0, 0.0])
	var parts: Array = []
	var raw_parts: Variant = src.get("parts", [])
	if typeof(raw_parts) != TYPE_ARRAY:
		errors.append("%s: synthetic_gimbal.parts must be a list" % path)
	else:
		for i in (raw_parts as Array).size():
			var raw: Variant = (raw_parts as Array)[i]
			if typeof(raw) != TYPE_DICTIONARY:
				errors.append("%s: synthetic_gimbal.parts[%d] must be a mapping"
					% [path, i])
				continue
			parts.append(_normalize_part(raw as Dictionary, "%s: parts[%d]"
				% [path, i], errors, warnings))
	out["parts"] = parts
	if out["parts"].is_empty():
		warnings.append("%s: synthetic_gimbal has no parts" % path)
	_unknown_keys(src, SYNTHETIC_DEFAULTS.keys(), path, warnings)
	return out


static func _normalize_part(src: Dictionary, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	var out := PART_DEFAULTS.duplicate(true)
	out["name"] = _string(src.get("name"), "PART")
	out["attach"] = _string(src.get("attach"), "pitch")
	if not out["attach"] in ["model", "yaw", "pitch"]:
		errors.append("%s: attach must be model | yaw | pitch" % path)
		out["attach"] = "pitch"
	out["shape"] = _string(src.get("shape"), "box")
	if not out["shape"] in ["box", "cylinder"]:
		errors.append("%s: shape must be box | cylinder" % path)
		out["shape"] = "box"
	out["size"] = _vec3(src.get("size"), [0.1, 0.1, 0.1])
	out["radius"] = _float(src.get("radius"), 0.05)
	out["height"] = _float(src.get("height"), 0.1)
	out["position"] = _vec3(src.get("position"), [0.0, 0.0, 0.0])
	out["rotation_deg"] = _vec3(src.get("rotation_deg"), [0.0, 0.0, 0.0])
	out["color"] = _vec4(src.get("color"), [0.08, 0.09, 0.10, 1.0])
	_unknown_keys(src, PART_DEFAULTS.keys(), path, warnings)
	return out


static func _normalize_robot_description(value: Variant, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	var out := ROBOT_DESCRIPTION_DEFAULTS.duplicate(true)
	if value == null:
		return out
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s: robot_description must be a mapping" % path)
		return out
	var src: Dictionary = value
	out["format"] = _string(src.get("format"), "").to_lower()
	out["path"] = _string(src.get("path"), "")
	out["mesh_root"] = _string(src.get("mesh_root"), "")
	out["yaw_joint"] = _string(src.get("yaw_joint"), "")
	out["pitch_joint"] = _string(src.get("pitch_joint"), "")
	out["camera_link"] = _string(src.get("camera_link"), "")
	out["camera_optical_frame"] = _string(src.get("camera_optical_frame"), "")
	if out["path"].is_empty():
		errors.append("%s: robot_description.path is required when the block is present"
			% path)
	else:
		if out["format"].is_empty():
			out["format"] = _infer_description_format(out["path"])
		if not out["format"] in ROBOT_DESCRIPTION_FORMATS:
			errors.append("%s: robot_description.format must be urdf | sdf (got '%s')"
				% [path, out["format"]])
			out["format"] = ""
		if not FileAccess.file_exists(out["path"]):
			errors.append("%s: robot_description.path not found: %s"
				% [path, out["path"]])
		if not out["mesh_root"].is_empty() and not DirAccess.dir_exists_absolute(
				out["mesh_root"]):
			errors.append("%s: robot_description.mesh_root not found: %s"
				% [path, out["mesh_root"]])
		if out["yaw_joint"].is_empty():
			errors.append("%s: robot_description.yaw_joint is required" % path)
		if out["pitch_joint"].is_empty():
			errors.append("%s: robot_description.pitch_joint is required" % path)
	_unknown_keys(src, ROBOT_DESCRIPTION_DEFAULTS.keys(), path, warnings)
	return out


## Description format when the profile omits it: use the file extension.
static func _infer_description_format(description_path: String) -> String:
	var extension := description_path.get_extension().to_lower()
	if extension == "xacro":
		return "urdf"
	if extension in ROBOT_DESCRIPTION_FORMATS:
		return extension
	return ""


# --- parsing helpers --------------------------------------------------------

static func _read_yaml(path: String, errors: PackedStringArray) -> Dictionary:
	if not FileAccess.file_exists(path):
		errors.append("profile not found: %s" % path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("cannot open %s" % path)
		return {}
	var text := file.get_as_text()
	file.close()
	var parser := YAMLParser.new()
	var parsed: Variant = parser.parse(text)
	if parsed == null:
		errors.append("YAML parse failed: %s" % path)
		return {}
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("%s: profile root must be a mapping" % path)
		return {}
	return parsed


static func _string(value: Variant, fallback: String) -> String:
	if value == null:
		return fallback
	return str(value)


static func _float(value: Variant, fallback: float) -> float:
	if value is int or value is float:
		return float(value)
	return fallback


static func _vec3(value: Variant, fallback: Array) -> Array:
	return _vec(value, 3, fallback)


static func _vec4(value: Variant, fallback: Array) -> Array:
	# Colours may be authored as RGB; keep the fallback alpha then.
	var out: Array = fallback.duplicate()
	if typeof(value) != TYPE_ARRAY:
		return out
	var items: Array = value
	for i in mini(4, items.size()):
		var component: Variant = items[i]
		if component is int or component is float:
			out[i] = float(component)
	return out


static func _vec(value: Variant, count: int, fallback: Array) -> Array:
	var out: Array = fallback.duplicate()
	if typeof(value) != TYPE_ARRAY or (value as Array).size() < count:
		return out
	for i in count:
		var component: Variant = (value as Array)[i]
		if component is int or component is float:
			out[i] = float(component)
	return out


static func _string_array(value: Variant, fallback: Array) -> Array:
	if typeof(value) != TYPE_ARRAY:
		return fallback.duplicate()
	var out: Array = []
	for item in value as Array:
		var text := str(item)
		if not text.is_empty() and not out.has(text):
			out.append(text)
	return out


static func _unknown_keys(src: Dictionary, known: Array, path: String,
		warnings: PackedStringArray) -> void:
	for key in src.keys():
		if not known.has(String(key)):
			warnings.append("%s: unknown key '%s' ignored" % [path, str(key)])
