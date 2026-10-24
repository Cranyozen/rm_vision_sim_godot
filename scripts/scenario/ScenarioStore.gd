class_name ScenarioStore
extends RefCounted

## Phase 3 scenario file I/O: startup selection, YAML loading + validation,
## scenario listing and deterministic writing.
##
## Startup order:
##   1. `--scenario=<path>` after `--` on the Godot command line
##      (e.g. `godot --path . -- --scenario=res://scenarios/1v1_line.yaml`)
##   2. `scenario:` from res://config/app.yaml
##   3. res://scenarios/1v1_static.yaml
##
## Scenarios are looked up under res://scenarios and user://scenarios (the UI
## "Save YAML" writes into the latter). ScenarioSchema validates and normalizes
## the parsed dictionary; YamlWriter writes it back.

const DEFAULT_SCENARIO_PATH := "res://scenarios/1v1_static.yaml"
const APP_CONFIG_PATH := "res://config/app.yaml"
const SCENARIO_DIR := "res://scenarios"
const USER_SCENARIO_DIR := "user://scenarios"


## Scenario path for this run (CLI -> config/app.yaml -> default).
static func startup_scenario_path() -> String:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var arg := args[i]
		if arg.begins_with("--scenario="):
			return _resolve_path(arg.trim_prefix("--scenario="))
		if arg == "--scenario" and i + 1 < args.size():
			return _resolve_path(args[i + 1])
	var app := _read_yaml_file(APP_CONFIG_PATH)
	if app.get("ok", false):
		var data: Variant = app.get("data", {})
		if data is Dictionary and (data as Dictionary).has("scenario"):
			return _resolve_path(String((data as Dictionary)["scenario"]))
	return DEFAULT_SCENARIO_PATH


## Load + validate + normalize one scenario file.
## Returns {ok, errors, warnings, data, path}; data is always normalized.
static func load_scenario(path: String) -> Dictionary:
	var read := _read_yaml_file(path)
	if not read.get("ok", false):
		return {
			"ok": false,
			"errors": PackedStringArray(read.get("errors", [])),
			"warnings": PackedStringArray(),
			"data": ScenarioSchema.defaults(),
			"path": path,
		}
	var result := ScenarioSchema.validate(read["data"])
	result["path"] = path
	return result


## All scenario files, res:// first then user://, sorted by display name.
## Display names are the file basename without `.yaml`.
static func list_scenarios() -> Array[String]:
	var out: Array[String] = []
	for dir_path_value in [SCENARIO_DIR, USER_SCENARIO_DIR]:
		var dir_path: String = dir_path_value
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		var names: Array[String] = []
		for file_value in dir.get_files():
			var file_name: String = file_value
			if file_name.ends_with(".yaml") or file_name.ends_with(".yml"):
				names.append(file_name)
		names.sort()
		for file_name in names:
			var full: String = dir_path.path_join(file_name)
			if not out.has(full):
				out.append(full)
	return out


## Display name for a scenario path ("1v1_line").
static func display_name(path: String) -> String:
	var file: String = path.get_file()
	for suffix_value in [".yaml", ".yml"]:
		var suffix: String = suffix_value
		if file.ends_with(suffix):
			return file.trim_suffix(suffix)
	return file


## Save normalized scenario data. `path` may be res:// or user://; the parent
## directory is created for user:// paths. Returns {ok, error, path}.
static func save_scenario(path: String, data: Dictionary) -> Dictionary:
	var validated := ScenarioSchema.validate(data)
	if not validated.get("ok", false):
		return {"ok": false, "error": "; ".join(validated.get("errors", [])), "path": path}
	var dir_path := path.get_base_dir()
	if dir_path.begins_with("user://"):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var err := YamlWriter.save(path, validated["data"])
	return {
		"ok": err == OK,
		"error": error_string(err) if err != OK else "",
		"path": path,
	}


## Resolve a scenario reference from config / CLI. Bare names are looked up in
## res://scenarios; paths with a scheme are used as-is.
static func _resolve_path(reference: String) -> String:
	if reference.begins_with("res://") or reference.begins_with("user://"):
		return reference
	for dir_path_value in [SCENARIO_DIR, USER_SCENARIO_DIR]:
		var dir_path: String = dir_path_value
		var candidate: String = dir_path.path_join(reference)
		if FileAccess.file_exists(candidate):
			return candidate
		if not reference.ends_with(".yaml"):
			var with_ext: String = candidate + ".yaml"
			if FileAccess.file_exists(with_ext):
				return with_ext
	return SCENARIO_DIR.path_join(reference if reference.ends_with(".yaml") else reference + ".yaml")


static func _read_yaml_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "errors": PackedStringArray(["scenario file not found: %s" % path])}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "errors": PackedStringArray([
			"cannot open %s: %s" % [path, error_string(FileAccess.get_open_error())]])}
	var text := file.get_as_text()
	file.close()
	var parser := YAMLParser.new()
	var parsed: Variant = parser.parse(text)
	if parsed == null:
		return {"ok": false, "errors": PackedStringArray(["YAML parse failed: %s" % path])}
	return {"ok": true, "errors": PackedStringArray(), "data": parsed}
