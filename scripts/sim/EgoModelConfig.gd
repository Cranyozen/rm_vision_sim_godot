class_name EgoModelConfig
extends RefCounted

## Ego robot model profile library (schema version 2).
##
## Every ego robot (full vehicle, light infantry chassis, debug boxes, ...) is
## described by one YAML file under `config/ego/`. `EgoRig` consumes the
## normalized profile dictionary, so adding a robot means adding a file, not
## writing a new builder branch.
##
## File schema (schema_version 2):
##
##   schema_version: 2                # required, must be 2
##   id: vehicle                      # required, unique; scenario `ego.model`
##   display_name: Vehicle            # UI / diagnostics label
##   asset:                           # required: the one model source
##     path: res://...glb             # required; the extension picks the loader
##     unit_scale: 1.0                # 0.001 for millimetre assets
##     floor_offset_m: 0.2101         # lift so the chassis bottom sits on y = 0
##     hide_node_prefixes: [...]      # imported nodes hidden at load time
##     mesh_root: ""                  # urdf/sdf only: mesh remap root
##   gimbal:                          # scene assets (.glb/.gltf/.scn/.tscn)
##     pitch_node: GIMBAL             # pitch pivot node inside the scene
##     yaw_node: ""                   # optional separate yaw pivot node
##     install_pitch_deg: 0.0         # install pitch baked into the visual head
##     visual_offset_m: [0, 0, 0]     # translation of the compensated pivot
##     synthetic:                     # chassis-only assets with no pivot node
##       yaw_pivot_m: [0, 0.152, 0]
##       pitch_pivot_m: [0, 0.045, 0]
##       parts:
##         - name: PITCH_BODY
##           attach: pitch            # model | yaw | pitch
##           shape: box               # box | cylinder
##           size: [0.16, 0.075, 0.13]   # box
##           radius: 0.055            # cylinder
##           height: 0.035            # cylinder
##           position: [0, 0.02, -0.02]
##           rotation_deg: [0, 0, 0]
##           color: [0.06, 0.07, 0.08, 1.0]
##   gimbal:                          # description assets (.urdf/.xacro/.sdf)
##     yaw_joint: gimbal_yaw_joint    # revolute joint driven by EgoRig yaw
##     pitch_joint: gimbal_pitch_joint  # revolute joint driven by EgoRig pitch
##   camera:
##     marker_node: CAM_DIRECTION     # scene: eye-position empty node
##     mount_m: [0, 0, 0]             # eye position when the marker/frames are absent
##     link: camera_link              # description: ROS camera_link frame
##     optical_frame: camera_optical_frame  # description: REP-103 optical frame
##
## The asset kind is inferred from `asset.path` (see `_infer_source`), so the
## `gimbal`/`camera` blocks only accept the keys that apply to that kind; a key
## for the other kind is an error, an unknown key is a warning. The normalized
## dictionary additionally carries `source` ("scene" | "description") and only
## the blocks/keys that apply to that source.
##
## The standard model contract: metres, Y up, forward = -Z at yaw 0, origin at
## the chassis centre on the ground, a gimbal pivot node (`GIMBAL`) and a
## `CAM_DIRECTION` empty under it. Chassis-only GLBs declare
## `gimbal.synthetic` instead; description-backed profiles take the joints and
## camera frames from the URDF/SDF (docs/EGO_MODEL_CONTRACT.md, and the Chinese
## mirror docs/EGO_MODEL_CONTRACT.zh_CN.md).
##
## The nodes named by `camera.marker_node` and `SimConfig.SHOT_DIRECTION_NODE`
## are never rotated by the install-pitch compensation; that list is derived
## here and in `EgoRig`, it is not a profile key.

const MODEL_DIR := SimConfig.EGO_PROFILE_DIR
const SCHEMA_VERSION := 2

const TOP_LEVEL_KEYS := ["schema_version", "id", "display_name", "asset",
	"gimbal", "camera"]
const ASSET_KEYS := ["path", "unit_scale", "floor_offset_m",
	"hide_node_prefixes", "mesh_root"]
const GIMBAL_KEYS := ["pitch_node", "yaw_node", "install_pitch_deg",
	"visual_offset_m", "synthetic", "yaw_joint", "pitch_joint"]
const CAMERA_KEYS := ["marker_node", "mount_m", "link", "optical_frame"]
const SYNTHETIC_KEYS := ["yaw_pivot_m", "pitch_pivot_m", "parts"]
const PART_KEYS := ["name", "attach", "shape", "size", "radius", "height",
	"position", "rotation_deg", "color"]

const SCENE_EXTENSIONS := ["glb", "gltf", "scn", "tscn"]
const DESCRIPTION_EXTENSIONS := ["urdf", "xacro", "sdf"]

const ASSET_DEFAULTS := {
	"path": "",
	"unit_scale": 1.0,
	"floor_offset_m": 0.0,
	"hide_node_prefixes": [],
}

const SCENE_GIMBAL_DEFAULTS := {
	"pitch_node": SimConfig.GIMBAL_NODE,
	"yaw_node": "",
	"install_pitch_deg": 0.0,
	"visual_offset_m": [0.0, 0.0, 0.0],
	"synthetic": {},
}

const DESCRIPTION_GIMBAL_DEFAULTS := {
	"yaw_joint": "",
	"pitch_joint": "",
}

const SCENE_CAMERA_DEFAULTS := {
	"marker_node": SimConfig.CAM_DIRECTION_NODE,
	"mount_m": [0.0, 0.0, 0.0],
}

const DESCRIPTION_CAMERA_DEFAULTS := {
	"link": "",
	"optical_frame": "",
	"mount_m": [0.0, 0.0, 0.0],
}

const SYNTHETIC_DEFAULTS := {
	"yaw_pivot_m": [0.0, 0.0, 0.0],
	"pitch_pivot_m": [0.0, 0.0, 0.0],
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
	var out := {
		"schema_version": SCHEMA_VERSION,
		"id": "",
		"display_name": "",
		"source": "",
		"asset": ASSET_DEFAULTS.duplicate(true),
		"gimbal": {},
		"camera": {},
	}
	if typeof(data) != TYPE_DICTIONARY:
		errors.append("%s: profile root must be a mapping" % path)
		return out
	var src: Dictionary = data

	var version := int(_float(src.get("schema_version"), 0))
	out["schema_version"] = version
	if version != SCHEMA_VERSION:
		errors.append("%s: unsupported schema_version %d (expected %d)"
			% [path, version, SCHEMA_VERSION])

	out["id"] = _string(src.get("id"), "")
	if String(out["id"]).is_empty():
		errors.append("%s: missing required key 'id'" % path)
	out["display_name"] = _string(src.get("display_name"), String(out["id"]))

	var asset := _normalize_asset(src.get("asset"), path, errors, warnings)
	out["asset"] = asset
	var source := String(asset.get("source", ""))
	out["source"] = source
	if not source.is_empty():
		out["gimbal"] = _normalize_gimbal(src.get("gimbal"), source, path,
			errors, warnings)
		out["camera"] = _normalize_camera(src.get("camera"), source, path,
			errors, warnings)

	_unknown_keys(src, TOP_LEVEL_KEYS, path, warnings)
	return out


## Asset kind from the path extension: "scene" for Godot-imported scenes,
## "description" for URDF/xacro/SDF, "" when the extension is not supported.
static func _infer_source(asset_path: String) -> String:
	var extension := asset_path.get_extension().to_lower()
	if extension in SCENE_EXTENSIONS:
		return "scene"
	if extension in DESCRIPTION_EXTENSIONS:
		return "description"
	return ""


static func _description_format(asset_path: String) -> String:
	var extension := asset_path.get_extension().to_lower()
	return "urdf" if extension == "xacro" else extension


static func _normalize_asset(value: Variant, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	var out := ASSET_DEFAULTS.duplicate(true)
	if value == null:
		errors.append("%s: missing required block 'asset'" % path)
		return out
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s: asset must be a mapping" % path)
		return out
	var src: Dictionary = value
	var asset_path := _string(src.get("path"), "")
	if asset_path.is_empty():
		errors.append("%s: asset.path is required" % path)
		_unknown_keys(src, ASSET_KEYS, path, warnings)
		return out
	var source := _infer_source(asset_path)
	if source.is_empty():
		errors.append("%s: cannot infer the asset kind from '%s' (expected %s or %s)"
			% [path, asset_path, ", ".join(SCENE_EXTENSIONS),
			", ".join(DESCRIPTION_EXTENSIONS)])
		_unknown_keys(src, ASSET_KEYS, path, warnings)
		return out
	out["source"] = source
	out["path"] = asset_path
	if not FileAccess.file_exists(asset_path):
		errors.append("%s: asset.path not found: %s" % [path, asset_path])
	out["unit_scale"] = _float(src.get("unit_scale"), 1.0)
	if float(out["unit_scale"]) <= 0.0:
		errors.append("%s: asset.unit_scale must be > 0" % path)
		out["unit_scale"] = 1.0
	out["floor_offset_m"] = _float(src.get("floor_offset_m"), 0.0)
	out["hide_node_prefixes"] = _string_array(src.get("hide_node_prefixes"), [])
	if source == "description":
		out["format"] = _description_format(asset_path)
		out["mesh_root"] = _string(src.get("mesh_root"), "")
		if not String(out["mesh_root"]).is_empty() \
				and not DirAccess.dir_exists_absolute(String(out["mesh_root"])):
			errors.append("%s: asset.mesh_root not found: %s"
				% [path, out["mesh_root"]])
	elif src.has("mesh_root"):
		errors.append("%s: asset.mesh_root is only valid for urdf/sdf assets"
			% path)
	_unknown_keys(src, ASSET_KEYS, path, warnings)
	return out


static func _normalize_gimbal(value: Variant, source: String, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	var src: Dictionary = {}
	if value != null:
		if typeof(value) != TYPE_DICTIONARY:
			errors.append("%s: gimbal must be a mapping" % path)
		else:
			src = value

	if source == "description":
		var out := DESCRIPTION_GIMBAL_DEFAULTS.duplicate(true)
		out["yaw_joint"] = _string(src.get("yaw_joint"), "")
		out["pitch_joint"] = _string(src.get("pitch_joint"), "")
		if String(out["yaw_joint"]).is_empty():
			errors.append("%s: gimbal.yaw_joint is required for urdf/sdf assets"
				% path)
		if String(out["pitch_joint"]).is_empty():
			errors.append("%s: gimbal.pitch_joint is required for urdf/sdf assets"
				% path)
		_reject_keys(src, SCENE_GIMBAL_DEFAULTS.keys(), "gimbal", path, errors,
			"urdf/sdf")
		_unknown_keys(src, GIMBAL_KEYS, path, warnings)
		return out

	var scene_out := SCENE_GIMBAL_DEFAULTS.duplicate(true)
	scene_out["pitch_node"] = _string(src.get("pitch_node"), SimConfig.GIMBAL_NODE)
	scene_out["yaw_node"] = _string(src.get("yaw_node"), "")
	scene_out["install_pitch_deg"] = _float(src.get("install_pitch_deg"), 0.0)
	scene_out["visual_offset_m"] = _vec3(src.get("visual_offset_m"),
		[0.0, 0.0, 0.0])
	scene_out["synthetic"] = _normalize_synthetic(src.get("synthetic"), path,
		errors, warnings)
	_reject_keys(src, DESCRIPTION_GIMBAL_DEFAULTS.keys(), "gimbal", path, errors,
		"scene")
	_unknown_keys(src, GIMBAL_KEYS, path, warnings)
	if String(scene_out["pitch_node"]).is_empty() \
			and (scene_out["synthetic"] as Dictionary).is_empty():
		errors.append("%s: scene profiles need gimbal.pitch_node or gimbal.synthetic"
			% path)
	return scene_out


static func _normalize_camera(value: Variant, source: String, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	var src: Dictionary = {}
	if value != null:
		if typeof(value) != TYPE_DICTIONARY:
			errors.append("%s: camera must be a mapping" % path)
		else:
			src = value

	if source == "description":
		var out := DESCRIPTION_CAMERA_DEFAULTS.duplicate(true)
		out["link"] = _string(src.get("link"), "")
		out["optical_frame"] = _string(src.get("optical_frame"), "")
		out["mount_m"] = _vec3(src.get("mount_m"), [0.0, 0.0, 0.0])
		_reject_keys(src, ["marker_node"], "camera", path, errors, "urdf/sdf")
		_unknown_keys(src, CAMERA_KEYS, path, warnings)
		return out

	var scene_out := SCENE_CAMERA_DEFAULTS.duplicate(true)
	scene_out["marker_node"] = _string(src.get("marker_node"),
		SimConfig.CAM_DIRECTION_NODE)
	scene_out["mount_m"] = _vec3(src.get("mount_m"), [0.0, 0.0, 0.0])
	_reject_keys(src, ["link", "optical_frame"], "camera", path, errors, "scene")
	_unknown_keys(src, CAMERA_KEYS, path, warnings)
	return scene_out


static func _normalize_synthetic(value: Variant, path: String,
		errors: PackedStringArray, warnings: PackedStringArray) -> Dictionary:
	if value == null:
		return {}
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s: gimbal.synthetic must be a mapping" % path)
		return {}
	var src: Dictionary = value
	var out := SYNTHETIC_DEFAULTS.duplicate(true)
	out["yaw_pivot_m"] = _vec3(src.get("yaw_pivot_m"), [0.0, 0.0, 0.0])
	out["pitch_pivot_m"] = _vec3(src.get("pitch_pivot_m"), [0.0, 0.0, 0.0])
	var parts: Array = []
	var raw_parts: Variant = src.get("parts", [])
	if typeof(raw_parts) != TYPE_ARRAY:
		errors.append("%s: gimbal.synthetic.parts must be a list" % path)
	else:
		for i in (raw_parts as Array).size():
			var raw: Variant = (raw_parts as Array)[i]
			if typeof(raw) != TYPE_DICTIONARY:
				errors.append("%s: gimbal.synthetic.parts[%d] must be a mapping"
					% [path, i])
				continue
			parts.append(_normalize_part(raw as Dictionary, "%s: parts[%d]"
				% [path, i], errors, warnings))
	out["parts"] = parts
	if out["parts"].is_empty():
		warnings.append("%s: gimbal.synthetic has no parts" % path)
	_unknown_keys(src, SYNTHETIC_KEYS, path, warnings)
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
	_unknown_keys(src, PART_KEYS, path, warnings)
	return out


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


static func _reject_keys(src: Dictionary, keys: Array, block: String, path: String,
		errors: PackedStringArray, expected: String) -> void:
	for key in keys:
		if src.has(key):
			errors.append("%s: %s.%s is not valid for %s assets"
				% [path, block, str(key), expected])


static func _unknown_keys(src: Dictionary, known: Array, path: String,
		warnings: PackedStringArray) -> void:
	for key in src.keys():
		if not known.has(String(key)):
			warnings.append("%s: unknown key '%s' ignored" % [path, str(key)])
