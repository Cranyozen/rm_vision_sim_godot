class_name AppSettings
extends RefCounted

## Persistent operator-facing application settings (user://settings.cfg).
##
## Two UI pages share this file:
##   - StartScreen: the startup choices shown before the operator drives
##     (scenario / robot model / camera preset / ROS publish / remember).
##   - SettingsPanel: the persistent defaults (robot model / camera preset /
##     ROS publish / self-in-feed / skip the start screen).
##
## The UI language is intentionally NOT stored here: I18n owns user://ui.cfg so
## there is exactly one owner for the locale.  Every other value is a plain
## typed key/value pair; unknown keys are dropped and wrong-typed values fall
## back to the documented default, so a hand-edited file can never break
## startup.
##
## Empty strings for `ego_model` / `camera_preset` mean "follow the scenario
## YAML" (the scenario is still the single source of truth for the world).
##
## Precedence for the startup scenario:
##   `--scenario` CLI > `startup_scenario` here > config/app.yaml > built-in
##   default (see Main._startup_scenario_path()).

const CONFIG_PATH := "user://settings.cfg"
const SECTION := "app"

const KEY_STARTUP_SCENARIO := "startup_scenario"
const KEY_EGO_MODEL := "ego_model"
const KEY_CAMERA_PRESET := "camera_preset"
const KEY_ROS_PUBLISH := "ros_publish"
const KEY_SELF_IN_FEED := "self_in_feed"
const KEY_SKIP_HOME := "skip_home"

## "" for the model / camera keys means "use the scenario's value".
const DEFAULTS := {
	KEY_STARTUP_SCENARIO: "",
	KEY_EGO_MODEL: "",
	KEY_CAMERA_PRESET: "",
	KEY_ROS_PUBLISH: true,
	KEY_SELF_IN_FEED: false,
	KEY_SKIP_HOME: false,
}

static var _cache: Dictionary = {}
static var _loaded := false


## Current settings snapshot (copy; callers may edit it freely).
static func snapshot() -> Dictionary:
	_ensure_loaded()
	return _cache.duplicate(true)


## One setting with a fallback for unknown keys.
static func get_value(key: String, fallback: Variant = null) -> Variant:
	_ensure_loaded()
	if _cache.has(key):
		return _cache[key]
	return fallback


## Merge `values` into the settings and persist them.  Unknown keys and
## wrong-typed values are ignored (a warning-free defensive filter: the UI is
## expected to pass the right types, but a stale config file must not crash).
static func save_values(values: Dictionary) -> void:
	_ensure_loaded()
	for key_value in values:
		var key := String(key_value)
		if not DEFAULTS.has(key):
			continue
		var value: Variant = values[key_value]
		if _is_valid(key, value):
			_cache[key] = value
	_write()


## Reset every setting to its documented default and persist the result.
static func reset() -> void:
	_loaded = true
	_cache = DEFAULTS.duplicate(true)
	_write()


## Forget the in-memory copy so the next access re-reads user://settings.cfg.
static func reload() -> void:
	_loaded = false
	_cache.clear()


static func startup_scenario() -> String:
	return String(get_value(KEY_STARTUP_SCENARIO, ""))


static func ego_model() -> String:
	return String(get_value(KEY_EGO_MODEL, ""))


static func camera_preset() -> String:
	return String(get_value(KEY_CAMERA_PRESET, ""))


static func ros_publish() -> bool:
	return bool(get_value(KEY_ROS_PUBLISH, true))


static func self_in_feed() -> bool:
	return bool(get_value(KEY_SELF_IN_FEED, false))


static func skip_home() -> bool:
	return bool(get_value(KEY_SKIP_HOME, false))


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_cache = DEFAULTS.duplicate(true)
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	for key_value in DEFAULTS:
		var key := String(key_value)
		if not config.has_section_key(SECTION, key):
			continue
		var raw: Variant = config.get_value(SECTION, key)
		if _is_valid(key, raw):
			_cache[key] = raw


static func _is_valid(key: String, value: Variant) -> bool:
	var fallback: Variant = DEFAULTS[key]
	match typeof(fallback):
		TYPE_BOOL:
			return typeof(value) == TYPE_BOOL
		TYPE_STRING:
			return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME
		TYPE_INT:
			return typeof(value) == TYPE_INT
	return false


static func _write() -> void:
	var config := ConfigFile.new()
	# Keep unrelated sections / hand-added keys intact.
	config.load(CONFIG_PATH)
	for key_value in _cache:
		config.set_value(SECTION, String(key_value), _cache[key_value])
	var err := config.save(CONFIG_PATH)
	if err != OK:
		# Headless / sandboxed user:// may be read-only; the choice simply does
		# not persist, which is not an error for the running session.
		push_warning("AppSettings: cannot save %s (%s)"
			% [CONFIG_PATH, error_string(err)])
