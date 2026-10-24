extends SceneTree

## Headless check for the Phase 3 scenario YAML layer:
## - every starter scenario parses with the vendored YAML parser, validates
##   without errors/warnings and matches its documented target set;
## - the schema defaults, numeric clamping and validation errors behave;
## - target `number` always normalizes to a String;
## - YamlWriter round-trips (normalize -> dump -> parse -> normalize) to the
##   same dictionary with byte-identical text, and `save()` writes it;
## - config/app.yaml selects an existing scenario.
##
## Usage: godot --headless --path . --script res://tests/scenario_yaml_check.gd
## Expects: SCENARIO_YAML_CHECK: PASS

const Parser := preload("res://addons/yaml_gd/yaml.gd")
const Schema := preload("res://scripts/scenario/ScenarioSchema.gd")
const Writer := preload("res://scripts/scenario/YamlWriter.gd")

const SCENARIO_DIR := "res://scenarios/"
const APP_CONFIG := "res://config/app.yaml"
const SAVE_PATH := "res://tests/_scenario_yaml_check_out.yaml"
const MOTION_TYPES := ["static", "line", "polyline", "spin"]
const MOTION_MODES := ["once", "loop", "pingpong"]

var _failures: Array[String] = []


func _initialize() -> void:
	_check_scenario_files()
	_check_schema_defaults()
	_check_clamping()
	_check_errors()
	_check_roundtrip()
	_check_writer_save()
	_check_app_config()

	if _failures.is_empty():
		print("SCENARIO_YAML_CHECK: PASS")
		quit(0)
	else:
		printerr("SCENARIO_YAML_CHECK: FAIL (%d)" % _failures.size())
		for failure: String in _failures:
			printerr("  " + failure)
		quit(1)


# --- starter scenarios -------------------------------------------------------

func _check_scenario_files() -> void:
	var static_data := _load_scenario("1v1_static.yaml")
	var line_data := _load_scenario("1v1_line.yaml")
	var spin_data := _load_scenario("3v3_spin.yaml")
	var flat_data := _load_scenario("flat_range.yaml")
	if static_data.is_empty() or line_data.is_empty() \
			or spin_data.is_empty() or flat_data.is_empty():
		return

	# --- 1v1_static: the Phase 1 target set -------------------------------
	_check("1v1_static: field", String(static_data["field"]) == "rmul2027_1v1")
	_check("1v1_static: ego pose",
		_vector3(static_data["ego"]["position"]) == Vector3(0.0, 0.0, 2.2)
		and is_zero_approx(float(static_data["ego"]["yaw_deg"])),
		str(static_data["ego"]))
	_check("1v1_static: four targets",
		(static_data["targets"] as Array).size() == 4)
	_static_target(static_data, "t1", "3", "red", "small",
		Vector3(0.0, 0.0, -1.4), 180.0)
	_static_target(static_data, "t2", "2", "blue", "small",
		Vector3(-1.5, 0.0, -0.2), 135.0)
	_static_target(static_data, "t3", "1", "red", "large",
		Vector3(1.5, 0.0, -0.2), -135.0)
	_static_target(static_data, "t4", "5", "blue", "small",
		Vector3(1.9, 0.0, 1.2), -90.0)

	# --- 1v1_line ---------------------------------------------------------
	_check("1v1_line: field", String(line_data["field"]) == "rmul2027_1v1")
	_check("1v1_line: three targets",
		(line_data["targets"] as Array).size() == 3)
	_check_motion("1v1_line: t1 static", line_data, "3", "static", "once",
		-1.0, -1.0, 0)
	_check_motion("1v1_line: t2 line pingpong", line_data, "2", "line",
		"pingpong", 1.0, -1.0, 2)
	_check_motion("1v1_line: t3 line loop", line_data, "1", "line", "loop",
		0.7, -1.0, 2)

	# --- 3v3_spin ---------------------------------------------------------
	_check("3v3_spin: field", String(spin_data["field"]) == "rmul2027_3v3")
	var spin_ego := _vector3(spin_data["ego"]["position"])
	# The 3v3 chassis clamp is +/-5.7 / +/-3.7 m; the ego starts at z = 3.5.
	_check("3v3_spin: ego inside chassis clamp",
		absf(spin_ego.x) <= 5.7 and absf(spin_ego.z) <= 3.7
		and is_equal_approx(spin_ego.z, 3.5),
		str(spin_ego))
	_check("3v3_spin: four targets",
		(spin_data["targets"] as Array).size() == 4)
	_check_motion("3v3_spin: t1 spin loop 45", spin_data, "3", "spin", "loop",
		-1.0, 45.0, 0)
	_check_motion("3v3_spin: t2 spin pingpong 60", spin_data, "2", "spin",
		"pingpong", -1.0, 60.0, 0)
	_check_motion("3v3_spin: t3 spin once 90", spin_data, "1", "spin", "once",
		-1.0, 90.0, 0)
	_check_motion("3v3_spin: t4 static", spin_data, "5", "static", "once",
		-1.0, -1.0, 0)
	for target: Dictionary in spin_data["targets"]:
		var point := _vector3(target["position"])
		_check("3v3_spin: target %s inside field" % target["id"],
			absf(point.x) <= 6.0 and absf(point.z) <= 4.0, str(point))

	# --- flat_range -------------------------------------------------------
	_check("flat_range: field", String(flat_data["field"]) == "flat")
	_check("flat_range: ego pose",
		_vector3(flat_data["ego"]["position"]) == Vector3(0.0, 0.0, 5.0),
		str(flat_data["ego"]["position"]))
	_check("flat_range: four targets",
		(flat_data["targets"] as Array).size() == 4)
	_check_motion("flat_range: t1 line pingpong 1.5", flat_data, "3", "line",
		"pingpong", 1.5, -1.0, 2)
	_check_motion("flat_range: t2 polyline loop", flat_data, "2", "polyline",
		"loop", 1.0, -1.0, 4)
	_check_motion("flat_range: t3 spin loop 30", flat_data, "1", "spin", "loop",
		-1.0, 30.0, 0)
	_check_motion("flat_range: t4 static", flat_data, "5", "static", "once",
		-1.0, -1.0, 0)
	_check("flat_range: targets stay on the 20 x 20 m field",
		_targets_inside_flat(flat_data), "")

	# --- number is always a String ---------------------------------------
	for data: Dictionary in [static_data, line_data, spin_data, flat_data]:
		for target: Dictionary in data["targets"]:
			_check("%s: number %s is a String" % [data["name"], target["id"]],
				typeof(target["number"]) == TYPE_STRING,
				type_string(typeof(target["number"])))

	# --- motion configs are in range -------------------------------------
	for data: Dictionary in [static_data, line_data, spin_data, flat_data]:
		_check_motions_valid(String(data["name"]), data)


func _static_target(data: Dictionary, id: String, number: String, team: String,
		armor: String, position: Vector3, yaw_deg: float) -> void:
	var target := _target_by_id(data, id)
	if target.is_empty():
		_check("1v1_static: target %s" % id, false, "missing")
		return
	var ok := String(target["number"]) == number \
		and String(target["team"]) == team \
		and String(target["armor"]) == armor \
		and _vector3(target["position"]).is_equal_approx(position) \
		and is_equal_approx(float(target["yaw_deg"]), yaw_deg)
	_check("1v1_static: %s %s %s" % [id, team, armor], ok,
		"number=%s team=%s armor=%s pos=%s yaw=%s" % [target["number"],
			target["team"], target["armor"], target["position"],
			target["yaw_deg"]])


func _check_motion(label: String, data: Dictionary, number: String,
		expected_type: String, expected_mode: String,
		expected_speed: float, expected_spin: float,
		expected_waypoints: int) -> void:
	var target := _target_by_number(data, number)
	if target.is_empty():
		_check(label, false, "missing target number " + number)
		return
	var motion: Dictionary = target["motion"]
	var ok := String(motion["type"]) == expected_type \
		and String(motion["mode"]) == expected_mode \
		and (motion["waypoints"] as Array).size() == expected_waypoints
	var detail := "type=%s mode=%s waypoints=%d" % [motion["type"],
		motion["mode"], (motion["waypoints"] as Array).size()]
	if expected_speed >= 0.0:
		ok = ok and is_equal_approx(float(motion["speed"]), expected_speed)
		detail += " speed=%s" % motion["speed"]
	if expected_spin >= 0.0:
		ok = ok and is_equal_approx(float(motion["spin_deg_s"]), expected_spin)
		detail += " spin=%s" % motion["spin_deg_s"]
	_check(label, ok, detail)


func _check_motions_valid(label: String, data: Dictionary) -> void:
	var ok := true
	var detail := ""
	for target: Dictionary in data["targets"]:
		var motion: Dictionary = target["motion"]
		var motion_type := String(motion["type"])
		var motion_mode := String(motion["mode"])
		if not MOTION_TYPES.has(motion_type):
			ok = false
			detail += "%s has type '%s'; " % [target["id"], motion_type]
		if not MOTION_MODES.has(motion_mode):
			ok = false
			detail += "%s has mode '%s'; " % [target["id"], motion_mode]
		if float(motion["speed"]) <= 0.0:
			ok = false
			detail += "%s has speed <= 0; " % target["id"]
		if motion_type == "spin" and float(motion["spin_deg_s"]) == 0.0:
			ok = false
			detail += "%s spins at 0 deg/s; " % target["id"]
		var waypoints: Array = motion["waypoints"]
		if motion_type in ["line", "polyline"] and waypoints.size() < 2:
			ok = false
			detail += "%s needs >= 2 waypoints; " % target["id"]
		for waypoint: Array in waypoints:
			if waypoint.size() != 3:
				ok = false
				detail += "%s has a bad waypoint; " % target["id"]
	_check("%s: motion configs valid" % label, ok, detail)


func _targets_inside_flat(data: Dictionary) -> bool:
	var ego := _vector3(data["ego"]["position"])
	for target: Dictionary in data["targets"]:
		var motion: Dictionary = target["motion"]
		var waypoints: Array = motion["waypoints"]
		var anchors: Array = []
		if waypoints.is_empty():
			anchors.append(target["position"])
		else:
			for waypoint: Variant in waypoints:
				anchors.append(waypoint)
		for anchor: Variant in anchors:
			var point := _vector3(anchor)
			if absf(point.x) > 10.0 or absf(point.z) > 10.0:
				return false
			if _flat_distance(ego, point) < 4.0:
				return false
	return true


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# --- schema / writer ---------------------------------------------------------

func _check_schema_defaults() -> void:
	var result: Dictionary = Schema.validate({})
	_check("defaults: empty scenario validates", result["ok"],
		"; ".join(result["errors"]))
	_check("defaults: no warnings",
		(result["warnings"] as PackedStringArray).is_empty(),
		"; ".join(result["warnings"]))
	_check("defaults: validate({}) equals defaults()",
		_deep_equal(result["data"], Schema.defaults()),
		_deep_diff(result["data"], Schema.defaults()))
	_check("defaults: schema version %d" % Schema.SCHEMA_VERSION,
		int(result["data"]["schema_version"]) == 1)
	_check("defaults: no targets", (result["data"]["targets"] as Array).is_empty())

	var bad_root: Dictionary = Schema.validate([1, 2, 3])
	_check("defaults: non-mapping root is an error", not bad_root["ok"])
	_check("defaults: non-mapping root still yields defaults",
		_deep_equal(bad_root["data"], Schema.defaults()))

	# A target number parsed as an int is coerced to a String.
	var number_case: Dictionary = Schema.validate({
		"targets": [{"team": "red", "armor": "small", "number": 3}],
	})
	var number = number_case["data"]["targets"][0]["number"]
	_check("number: bare YAML 3 becomes \"3\"",
		typeof(number) == TYPE_STRING and String(number) == "3",
		type_string(typeof(number)))

	# Missing optional id gets a generated t<N> id.
	var id_case: Dictionary = Schema.validate({
		"targets": [
			{"team": "red", "armor": "small", "number": "3"},
			{"team": "blue", "armor": "large", "number": "1"},
		],
	})
	_check("id: generated t<N>", id_case["ok"]
		and String(id_case["data"]["targets"][0]["id"]) == "t1"
		and String(id_case["data"]["targets"][1]["id"]) == "t2",
		str(id_case["errors"]))


func _check_clamping() -> void:
	var result: Dictionary = Schema.validate({
		"ros": {"raw_hz": 0.0, "compressed_hz": 500.0, "jpeg_quality": 0},
		"camera": {"fpv_fov_deg": 200.0},
		"targets": [{
			"team": "red",
			"armor": "small",
			"number": "3",
			"armor_layout": {
				"group_height_offset_m": 0.5,
				"x_group_span_m": -0.5,
			},
			"motion": {"speed": 0.0},
		}],
	})
	var data: Dictionary = result["data"]
	var target: Dictionary = data["targets"][0]
	var layout: Dictionary = target["armor_layout"]
	var motion: Dictionary = target["motion"]
	_check("clamp: raw_hz", is_equal_approx(float(data["ros"]["raw_hz"]), 1.0),
		str(data["ros"]["raw_hz"]))
	_check("clamp: compressed_hz",
		is_equal_approx(float(data["ros"]["compressed_hz"]), 240.0),
		str(data["ros"]["compressed_hz"]))
	_check("clamp: jpeg_quality", int(data["ros"]["jpeg_quality"]) == 1,
		str(data["ros"]["jpeg_quality"]))
	_check("clamp: fpv_fov_deg",
		is_equal_approx(float(data["camera"]["fpv_fov_deg"]), 120.0),
		str(data["camera"]["fpv_fov_deg"]))
	_check("clamp: group_height_offset_m",
		is_equal_approx(float(layout["group_height_offset_m"]), 0.1),
		str(layout["group_height_offset_m"]))
	_check("clamp: x_group_span_m",
		is_zero_approx(float(layout["x_group_span_m"])),
		str(layout["x_group_span_m"]))
	_check("clamp: speed",
		is_equal_approx(float(motion["speed"]), Schema.MIN_SPEED),
		str(motion["speed"]))
	_check("clamp: still valid", result["ok"], "; ".join(result["errors"]))
	_check("clamp: warnings emitted",
		(result["warnings"] as PackedStringArray).size() >= 7,
		"%d warnings" % (result["warnings"] as PackedStringArray).size())


func _check_errors() -> void:
	_check_error("unknown field",
		{"field": "rmul2027_nope"}, "unknown value")
	_check_error("unknown enum value",
		{"ros": {"raw_encoding": "mono8"}}, "unknown value")
	_check_error("target missing team",
		{"targets": [{"armor": "small", "number": "3"}]}, "team")
	_check_error("target missing armor",
		{"targets": [{"team": "red", "number": "3"}]}, "armor")
	_check_error("target missing number",
		{"targets": [{"team": "red", "armor": "small"}]}, "number")
	_check_error("line with one waypoint",
		{"targets": [{"team": "red", "armor": "small", "number": "3",
			"motion": {"type": "line",
				"waypoints": [[0.0, 0.0, -1.0]]}}]},
		"at least 2 waypoints")
	_check_error("polyline with no waypoints",
		{"targets": [{"team": "red", "armor": "small", "number": "3",
			"motion": {"type": "polyline"}}]},
		"at least 2 waypoints")
	_check_error("unsupported schema version", {"schema_version": 2},
		"unsupported version")
	_check_error("targets not a list", {"targets": 3}, "expected a list")
	_check_error("bad position", {"ego": {"position": [1.0, 2.0]}},
		"expected [x, y, z]")

	# Unknown keys are dropped with a warning, never promoted to errors.
	var unknown: Dictionary = Schema.validate({
		"bogus": 1,
		"ros": {"raw_hz": 30.0, "nope": true},
		"targets": [{"team": "red", "armor": "small", "number": "3",
			"motion": {"type": "static", "extra": 2}}],
	})
	_check("unknown keys: still valid", unknown["ok"], "; ".join(unknown["errors"]))
	_check("unknown keys: dropped from data",
		not unknown["data"].has("bogus")
		and not unknown["data"]["ros"].has("nope")
		and not unknown["data"]["targets"][0]["motion"].has("extra"))
	_check("unknown keys: warned",
		(unknown["warnings"] as PackedStringArray).size() == 3,
		"; ".join(unknown["warnings"]))

	# spin ignores waypoints (dropped with a warning).
	var spin: Dictionary = Schema.validate({
		"targets": [{"team": "red", "armor": "small", "number": "3",
			"motion": {"type": "spin", "spin_deg_s": 30.0,
				"waypoints": [[0.0, 0.0, -1.0], [1.0, 0.0, -1.0]]}}],
	})
	var spin_motion: Dictionary = spin["data"]["targets"][0]["motion"]
	_check("spin: ignores waypoints", spin["ok"]
		and (spin_motion["waypoints"] as Array).is_empty(),
		"; ".join(spin["warnings"]))
	_check("spin: waypoint warning",
		_has_warning(spin, "ignored for type 'spin'"))


func _check_roundtrip() -> void:
	for file: String in ["1v1_static.yaml", "1v1_line.yaml", "3v3_spin.yaml",
			"flat_range.yaml"]:
		var path := SCENARIO_DIR + file
		var parsed: Variant = _parse_file(path)
		var normalized: Dictionary = Schema.validate(parsed)["data"]
		var text: String = Writer.dump(normalized)
		var reparsed: Variant = _parse_text(text)
		var again: Dictionary = Schema.validate(reparsed)
		_check("%s: round-trip dictionary" % file,
			_deep_equal(again["data"], normalized),
			_deep_diff(again["data"], normalized))
		_check("%s: round-trip text stable" % file,
			Writer.dump(again["data"]) == text)
		_check("%s: round-trip has no warnings" % file,
			(again["warnings"] as PackedStringArray).is_empty(),
			"; ".join(again["warnings"]))
		_check("%s: round-trip validates" % file, again["ok"],
			"; ".join(again["errors"]))


func _check_writer_save() -> void:
	var parsed: Variant = _parse_file(SCENARIO_DIR + "1v1_line.yaml")
	var data: Dictionary = Schema.validate(parsed)["data"]
	var error: Error = Writer.save(SAVE_PATH, data)
	_check("save: writes OK", error == OK, error_string(error))
	if error != OK:
		return
	var written: String = FileAccess.get_file_as_string(SAVE_PATH)
	_check("save: text matches dump", written == Writer.dump(data))
	var roundtrip: Dictionary = Schema.validate(_parse_text(written))
	_check("save: written file validates", roundtrip["ok"],
		"; ".join(roundtrip["errors"]))
	_check("save: written data matches",
		_deep_equal(roundtrip["data"], data))
	var remove_error := DirAccess.remove_absolute(SAVE_PATH)
	_check("save: cleanup", remove_error == OK, error_string(remove_error))


func _check_app_config() -> void:
	_check("app.yaml: exists", FileAccess.file_exists(APP_CONFIG))
	var parsed: Variant = _parse_file(APP_CONFIG)
	_check("app.yaml: parses to a mapping",
		typeof(parsed) == TYPE_DICTIONARY)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var config: Dictionary = parsed
	_check("app.yaml: has scenario key", config.has("scenario"))
	if not config.has("scenario"):
		return
	_check("app.yaml: scenario is a resource path string",
		typeof(config["scenario"]) == TYPE_STRING
		and String(config["scenario"]).begins_with("res://"),
		str(config["scenario"]))
	_check("app.yaml: selected scenario exists",
		FileAccess.file_exists(String(config["scenario"])),
		String(config["scenario"]))


# --- helpers -----------------------------------------------------------------

func _load_scenario(file: String) -> Dictionary:
	var path := SCENARIO_DIR + file
	_check("%s: exists" % file, FileAccess.file_exists(path))
	var parsed: Variant = _parse_file(path)
	_check("%s: parses to a mapping" % file,
		typeof(parsed) == TYPE_DICTIONARY)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var result: Dictionary = Schema.validate(parsed)
	_check("%s: validates" % file, result["ok"], "; ".join(result["errors"]))
	_check("%s: no warnings" % file,
		(result["warnings"] as PackedStringArray).is_empty(),
		"; ".join(result["warnings"]))
	_check("%s: name matches file" % file,
		String(result["data"]["name"]) == file.get_basename())
	return result["data"]


func _parse_file(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return _parse_text(FileAccess.get_file_as_string(path))


func _parse_text(text: String) -> Variant:
	return Parser.new().parse(text)


func _check_error(label: String, data: Dictionary, needle: String) -> void:
	var result: Dictionary = Schema.validate(data)
	_check("error: " + label, not result["ok"] and _has_error(result, needle),
		"; ".join(result["errors"]))


func _has_error(result: Dictionary, needle: String) -> bool:
	for message: String in result["errors"]:
		if message.contains(needle):
			return true
	return false


func _has_warning(result: Dictionary, needle: String) -> bool:
	for message: String in result["warnings"]:
		if message.contains(needle):
			return true
	return false


func _target_by_id(data: Dictionary, id: String) -> Dictionary:
	for target: Dictionary in data["targets"]:
		if String(target["id"]) == id:
			return target
	return {}


func _target_by_number(data: Dictionary, number: String) -> Dictionary:
	for target: Dictionary in data["targets"]:
		if String(target["number"]) == number:
			return target
	return {}


func _vector3(value: Variant) -> Vector3:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 3:
		return Vector3.ZERO
	var array: Array = value
	return Vector3(float(array[0]), float(array[1]), float(array[2]))


func _deep_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	match typeof(a):
		TYPE_DICTIONARY:
			var dict_a: Dictionary = a
			var dict_b: Dictionary = b
			if dict_a.size() != dict_b.size():
				return false
			for key: Variant in dict_a.keys():
				if not dict_b.has(key):
					return false
				if not _deep_equal(dict_a[key], dict_b[key]):
					return false
			return true
		TYPE_ARRAY:
			var array_a: Array = a
			var array_b: Array = b
			if array_a.size() != array_b.size():
				return false
			for i in array_a.size():
				if not _deep_equal(array_a[i], array_b[i]):
					return false
			return true
		_:
			return a == b


func _deep_diff(a: Variant, b: Variant) -> String:
	if typeof(a) != typeof(b):
		return "type %s vs %s" % [type_string(typeof(a)), type_string(typeof(b))]
	match typeof(a):
		TYPE_DICTIONARY:
			var dict_a: Dictionary = a
			var dict_b: Dictionary = b
			for key: Variant in dict_a.keys():
				if not dict_b.has(key):
					return "missing key %s" % key
				if not _deep_equal(dict_a[key], dict_b[key]):
					return "%s: %s vs %s" % [key, dict_a[key], dict_b[key]]
			for key: Variant in dict_b.keys():
				if not dict_a.has(key):
					return "extra key %s" % key
			return ""
		TYPE_ARRAY:
			var array_a: Array = a
			var array_b: Array = b
			if array_a.size() != array_b.size():
				return "%d vs %d items" % [array_a.size(), array_b.size()]
			for i in array_a.size():
				if not _deep_equal(array_a[i], array_b[i]):
					return "index %d: %s vs %s" % [i, array_a[i], array_b[i]]
			return ""
		_:
			return "%s vs %s" % [a, b]


func _check(name: String, ok: bool, detail: String = "") -> void:
	var suffix := "" if detail.is_empty() else "  " + detail
	print(("  ok   " if ok else "  FAIL ") + name + suffix)
	if not ok:
		_failures.append(name + suffix)
