class_name ScenarioPanel
extends PanelContainer

## Phase 3 scenario overlay: scenario select / reload, target count, target
## motion parameters, camera preset, ROS publish toggle and a status readout.
##
## The whole panel is built in code so Main.tscn stays trivial.  Main owns the
## panel (it is not created by HUD) and toggles it with Tab through toggle();
## the panel itself never handles keyboard input, so Escape / Tab keep working
## in Main.
##
## Signals are the only way Main learns about edits; every control only emits
## on a real user interaction (update_state() uses the *_no_signal setters so
## refreshing the panel cannot bounce commands back into the scenario loader).

signal scenario_load_requested(path: String)
signal reload_requested
## {"type": String, "mode": String, "speed": float, "spin_deg_s": float}
signal motion_apply_requested(settings: Dictionary)
## "qyg" | "cad" | "qyg_trim" (mirrors SimConfig.CAMERA_PRESETS keys)
signal camera_preset_changed(preset: String)
signal publish_toggled(enabled: bool)
signal target_count_changed(count: int)
signal save_requested
## "en" | "zh_CN"; the panel only reports the choice, Main applies it.
signal language_changed(locale: String)

## Mirror of the scenario schema enums; keep in sync with ScenarioSchema /
## SimConfig.CAMERA_PRESETS.  Kept local so the UI parses even if the scenario
## layer is being edited concurrently.
const MOTION_TYPES: Array[String] = ["static", "line", "polyline", "spin"]
const MOTION_MODES: Array[String] = ["once", "loop", "pingpong"]
const CAMERA_PRESETS: Array[String] = ["qyg", "cad", "qyg_trim"]
const TARGET_COUNT_MIN := 1
const TARGET_COUNT_MAX := 12

var _built := false

# --- controls ---------------------------------------------------------------
var _scenario_option: OptionButton
var _reload_button: Button
var _field_value: Label
var _target_count_spin: SpinBox
var _motion_type_option: OptionButton
var _motion_mode_option: OptionButton
var _speed_spin: SpinBox
var _spin_spin: SpinBox
var _apply_button: Button
var _camera_option: OptionButton
var _language_option: OptionButton
var _ros_check: CheckBox
var _save_button: Button
var _status_label: Label
var _close_button: Button

## [{"node": Control, "msgid": String}] pairs the panel re-localizes when the
## UI language changes (the msgid doubles as the English text).
var _text_bindings: Array[Dictionary] = []

# --- state mirrored from update_state() -------------------------------------
var _scenario_paths: Array[String] = []
var _path_to_index: Dictionary = {}
var _scenario_path := ""
var _scenario_name := ""
var _field := "?"
var _target_count := 4
var _motion_summary := "?"
var _camera_preset := "qyg"
var _ros_enabled := false
var _ros_available := false
var _ros_status := ""
var _error := ""
var _fps := 0.0
var _frame_ms := 0.0
var _locale := I18n.FALLBACK_LOCALE


func _init() -> void:
	_build_ui()


func _ready() -> void:
	# Building in _init() keeps the panel usable in headless tests that never
	# add it to the tree; _ready() only re-asserts the built state.
	_build_ui()


# --- public API -------------------------------------------------------------

## Populate the scenario list and the initial state.  `current_path` selects
## the matching entry without emitting scenario_load_requested.
##
## `scenario_paths` is documented as Array[String] but typed as plain Array so
## callers can pass a dynamically built list (GDScript rejects an untyped Array
## variable for an Array[String] parameter); entries are stringified here.
func setup(scenario_paths: Array, current_path: String, state: Dictionary) -> void:
	_build_ui()
	_scenario_paths.clear()
	_path_to_index.clear()
	_scenario_option.clear()
	for i in range(scenario_paths.size()):
		var path := str(scenario_paths[i])
		if path == "":
			continue
		_scenario_paths.append(path)
		_scenario_option.add_item(_scenario_display_name(path))
		_path_to_index[path] = _scenario_paths.size() - 1
	if current_path != "":
		_scenario_path = current_path
		_scenario_name = _scenario_display_name(current_path)
		if _path_to_index.has(current_path):
			_scenario_option.select(int(_path_to_index[current_path]))
	elif _scenario_paths.size() > 0:
		_scenario_option.select(0)
	update_state(state)


## Refresh labels and controls from Main's current state.  Every key is
## optional and wrong types are ignored, so Main can pass a partial dict.
## state keys: scenario_path, scenario_name, field, target_count,
##             motion_summary, camera_preset, ros_enabled, ros_available,
##             ros_status, error, fps, frame_ms, locale
func update_state(state: Dictionary) -> void:
	_build_ui()
	if state.has("locale"):
		var locale := _as_string(state["locale"], _locale)
		if locale != _locale:
			_locale = locale
			_apply_locale_texts()
	if state.has("error"):
		_error = _as_string(state["error"], "")
	if state.has("scenario_path"):
		_scenario_path = _as_string(state["scenario_path"], _scenario_path)
		if _path_to_index.has(_scenario_path):
			_scenario_option.select(int(_path_to_index[_scenario_path]))
			_scenario_name = _scenario_display_name(_scenario_path)
	if state.has("scenario_name"):
		_scenario_name = _as_string(state["scenario_name"], _scenario_name)
	if state.has("field"):
		_field = _as_string(state["field"], _field)
	if state.has("target_count"):
		_target_count = clampi(_as_int(state["target_count"], _target_count),
			TARGET_COUNT_MIN, TARGET_COUNT_MAX)
		_target_count_spin.set_value_no_signal(float(_target_count))
	if state.has("motion_summary"):
		_motion_summary = _as_string(state["motion_summary"], _motion_summary)
	if state.has("camera_preset"):
		var preset := _as_string(state["camera_preset"], _camera_preset)
		if CAMERA_PRESETS.has(preset):
			_camera_preset = preset
			_camera_option.select(CAMERA_PRESETS.find(preset))
	if state.has("ros_enabled"):
		_ros_enabled = _as_bool(state["ros_enabled"], _ros_enabled)
		_ros_check.set_pressed_no_signal(_ros_enabled)
	if state.has("ros_available"):
		_ros_available = _as_bool(state["ros_available"], _ros_available)
	if state.has("ros_status"):
		_ros_status = _as_string(state["ros_status"], _ros_status)
	if state.has("fps"):
		_fps = maxf(0.0, _as_float(state["fps"], _fps))
	if state.has("frame_ms"):
		_frame_ms = maxf(0.0, _as_float(state["frame_ms"], _frame_ms))
	_refresh_status()


func toggle() -> void:
	set_open(not is_open())


func is_open() -> bool:
	return visible


func set_open(open: bool) -> void:
	_build_ui()
	visible = open
	if open and get_parent() != null:
		# Show the panel above the rest of the HUD overlay.
		move_to_front()


# --- control construction ---------------------------------------------------

func _build_ui() -> void:
	if _built:
		return
	_built = true
	_locale = I18n.get_locale()

	name = "ScenarioPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# Sit directly below the HUD status panel (top-left) and stay clear of the
	# bottom-right feed preview and the top-right controls panel.
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	offset_left = 16.0
	offset_top = 272.0
	offset_right = 464.0
	offset_bottom = 892.0
	add_theme_stylebox_override("panel", _panel_style())

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 3)
	add_child(body)

	# --- title row ----------------------------------------------------------
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	body.add_child(title_row)

	var title := Label.new()
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.35, 0.95, 0.65))
	_bind_text(title, "SCENARIO")
	title_row.add_child(title)

	var title_spacer := Control.new()
	title_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_spacer)

	_close_button = _make_button("CLOSE")
	_close_button.name = "CloseButton"
	_close_button.pressed.connect(_on_close_pressed)
	title_row.add_child(_close_button)

	# --- scenario row -------------------------------------------------------
	var scenario_row := HBoxContainer.new()
	scenario_row.add_theme_constant_override("separation", 6)
	body.add_child(scenario_row)

	scenario_row.add_child(_make_row_label("Scenario", 82))
	_scenario_option = OptionButton.new()
	_scenario_option.name = "ScenarioOption"
	_scenario_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scenario_option.focus_mode = Control.FOCUS_NONE
	_scenario_option.item_selected.connect(_on_scenario_selected)
	scenario_row.add_child(_scenario_option)

	_reload_button = _make_button("RELOAD")
	_reload_button.name = "ReloadButton"
	_reload_button.pressed.connect(_on_reload_pressed)
	scenario_row.add_child(_reload_button)

	# --- field row ----------------------------------------------------------
	var field_row := HBoxContainer.new()
	field_row.add_theme_constant_override("separation", 6)
	body.add_child(field_row)

	field_row.add_child(_make_row_label("Field", 82))
	_field_value = Label.new()
	_field_value.name = "FieldValue"
	_field_value.text = "?"
	_field_value.add_theme_font_size_override("font_size", 13)
	_field_value.add_theme_color_override("font_color", Color(0.72, 0.95, 0.85))
	field_row.add_child(_field_value)

	# --- target count row ---------------------------------------------------
	var count_row := HBoxContainer.new()
	count_row.add_theme_constant_override("separation", 6)
	body.add_child(count_row)

	count_row.add_child(_make_row_label("Targets", 82))
	_target_count_spin = SpinBox.new()
	_target_count_spin.name = "TargetCountSpin"
	_target_count_spin.min_value = TARGET_COUNT_MIN
	_target_count_spin.max_value = TARGET_COUNT_MAX
	_target_count_spin.step = 1.0
	_target_count_spin.value = 4.0
	_target_count_spin.custom_minimum_size = Vector2(96, 0)
	# Keyboard focus stays in Main; the arrows / wheel still work with mouse.
	_target_count_spin.focus_mode = Control.FOCUS_NONE
	_target_count_spin.value_changed.connect(_on_target_count_changed)
	count_row.add_child(_target_count_spin)

	body.add_child(HSeparator.new())

	# --- motion section -----------------------------------------------------
	var motion_title := Label.new()
	motion_title.add_theme_font_size_override("font_size", 12)
	motion_title.add_theme_color_override("font_color", Color(0.65, 0.95, 0.80))
	_bind_text(motion_title, "TARGET MOTION")
	body.add_child(motion_title)

	var type_row := HBoxContainer.new()
	type_row.add_theme_constant_override("separation", 6)
	body.add_child(type_row)
	type_row.add_child(_make_row_label("Type", 82))
	_motion_type_option = _make_option("MotionTypeOption", MOTION_TYPES)
	type_row.add_child(_motion_type_option)

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	body.add_child(mode_row)
	mode_row.add_child(_make_row_label("Mode", 82))
	_motion_mode_option = _make_option("MotionModeOption", MOTION_MODES)
	mode_row.add_child(_motion_mode_option)

	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 6)
	body.add_child(speed_row)
	speed_row.add_child(_make_row_label("Speed m/s", 82))
	_speed_spin = _make_spin("SpeedSpin", 0.1, 5.0, 0.1, 1.0)
	speed_row.add_child(_speed_spin)

	var spin_row := HBoxContainer.new()
	spin_row.add_theme_constant_override("separation", 6)
	body.add_child(spin_row)
	spin_row.add_child(_make_row_label("Spin deg/s", 82))
	_spin_spin = _make_spin("SpinDegSpin", 5.0, 360.0, 5.0, 90.0)
	spin_row.add_child(_spin_spin)

	_apply_button = _make_button("APPLY MOTION")
	_apply_button.name = "ApplyButton"
	_apply_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_button.pressed.connect(_on_apply_pressed)
	body.add_child(_apply_button)

	# --- camera preset row --------------------------------------------------
	var camera_row := HBoxContainer.new()
	camera_row.add_theme_constant_override("separation", 6)
	body.add_child(camera_row)
	camera_row.add_child(_make_row_label("Camera", 82))
	_camera_option = _make_option("CameraPresetOption", CAMERA_PRESETS)
	_camera_option.item_selected.connect(_on_camera_selected)
	camera_row.add_child(_camera_option)

	# --- language row -------------------------------------------------------
	# Labels are native names ("English" / "中文") so they are not translated;
	# the panel only signals the choice and Main applies it.
	var language_row := HBoxContainer.new()
	language_row.add_theme_constant_override("separation", 6)
	body.add_child(language_row)
	language_row.add_child(_make_row_label("Language", 82))
	_language_option = OptionButton.new()
	_language_option.name = "LanguageOption"
	_language_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_language_option.focus_mode = Control.FOCUS_NONE
	_language_option.item_selected.connect(_on_language_selected)
	language_row.add_child(_language_option)
	_rebuild_language_items()

	# --- ROS publish checkbox ----------------------------------------------
	_ros_check = CheckBox.new()
	_ros_check.name = "RosPublishCheck"
	_ros_check.focus_mode = Control.FOCUS_NONE
	_ros_check.toggled.connect(_on_ros_toggled)
	_bind_text(_ros_check, "ROS publish")
	body.add_child(_ros_check)

	# --- save row -----------------------------------------------------------
	_save_button = _make_button("SAVE YAML")
	_save_button.name = "SaveButton"
	_save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_button.pressed.connect(_on_save_pressed)
	body.add_child(_save_button)

	# --- status readout -----------------------------------------------------
	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color(0.80, 0.93, 0.87))
	_status_label.clip_text = true
	body.add_child(_status_label)

	var hint := Label.new()
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.55, 0.75, 0.68))
	hint.clip_text = true
	_bind_text(hint, "Tab closes · Esc releases the mouse")
	body.add_child(hint)

	# Defaults match the scenario schema defaults (static / once / 1.0 m/s /
	# 90 deg/s and the calibrated "qyg" camera preset).
	_motion_type_option.select(0)
	_motion_mode_option.select(0)
	_camera_option.select(CAMERA_PRESETS.find(_camera_preset))
	_refresh_status()


func _make_row_label(msgid: String, min_width: float) -> Label:
	var label := Label.new()
	label.custom_minimum_size = Vector2(min_width, 0)
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.70, 0.88, 0.80))
	_bind_text(label, msgid)
	return label


func _make_button(msgid: String) -> Button:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", Color(0.78, 0.96, 0.88))
	_bind_text(button, msgid)
	return button


## OptionButton whose item labels are localized schema values; the selected
## index still maps to the raw `items` entry (signals / state keep raw values).
func _make_option(node_name: String, items: Array[String]) -> OptionButton:
	var option := OptionButton.new()
	option.name = node_name
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.focus_mode = Control.FOCUS_NONE
	_localize_option(option, items)
	return option


# --- localization -----------------------------------------------------------

## Rebuild an OptionButton's item labels from `values` via I18n.t(), keeping the
## current selection index (the raw value stays the source of truth).
func _localize_option(option: OptionButton, values: Array[String]) -> void:
	if option == null:
		return
	var selected := option.selected
	option.clear()
	for value in values:
		option.add_item(I18n.t(value))
	if values.is_empty():
		return
	option.select(clampi(selected, 0, values.size() - 1))


## Register a control's text with an English msgid and apply it now.
func _bind_text(control: Control, msgid: String) -> void:
	_text_bindings.append({"node": control, "msgid": msgid})
	_set_control_text(control, msgid)


func _set_control_text(control: Control, msgid: String) -> void:
	var text := tr(msgid)
	if control is Label:
		(control as Label).text = text
	elif control is Button:
		(control as Button).text = text


## Re-localize every built-in static label, the localized dropdown items and
## the status readout after the UI language changed.  Main owns the actual
## locale switch (I18n.set_locale()); the panel only follows it.
func _apply_locale_texts() -> void:
	_build_ui()
	for binding in _text_bindings:
		_set_control_text(binding["node"] as Control, String(binding["msgid"]))
	_localize_option(_motion_type_option, MOTION_TYPES)
	_localize_option(_motion_mode_option, MOTION_MODES)
	_sync_language_selection()
	_refresh_status()


## Keep the language dropdown in sync without clearing it while its own
## item_selected handler is still running (Main refreshes the panel from there).
func _sync_language_selection() -> void:
	if _language_option == null:
		return
	if _language_option.item_count != I18n.SUPPORTED_LOCALES.size():
		_rebuild_language_items()
		return
	_language_option.select(maxi(0, _current_locale_index()))


func _rebuild_language_items() -> void:
	if _language_option == null:
		return
	var selected := _current_locale_index()
	_language_option.clear()
	for locale in I18n.SUPPORTED_LOCALES:
		_language_option.add_item(I18n.locale_display_name(locale))
	_language_option.select(maxi(0, selected))


func _current_locale_index() -> int:
	var index := I18n.SUPPORTED_LOCALES.find(_locale)
	return index if index >= 0 else 0


func _make_spin(node_name: String, min_value: float, max_value: float,
		step: float, initial: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.name = node_name
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = initial
	spin.custom_minimum_size = Vector2(96, 0)
	spin.focus_mode = Control.FOCUS_NONE
	return spin


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.015, 0.022, 0.026, 0.90)
	sb.border_color = Color(0.20, 0.80, 0.55, 0.60)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


# --- signal handlers --------------------------------------------------------

func _on_scenario_selected(index: int) -> void:
	if index < 0 or index >= _scenario_paths.size():
		return
	_scenario_path = _scenario_paths[index]
	_scenario_name = _scenario_display_name(_scenario_path)
	_refresh_status()
	scenario_load_requested.emit(_scenario_path)


func _on_reload_pressed() -> void:
	reload_requested.emit()


func _on_target_count_changed(value: float) -> void:
	_target_count = clampi(int(round(value)), TARGET_COUNT_MIN, TARGET_COUNT_MAX)
	_refresh_status()
	target_count_changed.emit(_target_count)


func _on_apply_pressed() -> void:
	var motion_type := MOTION_TYPES[clampi(_motion_type_option.selected, 0, MOTION_TYPES.size() - 1)]
	var motion_mode := MOTION_MODES[clampi(_motion_mode_option.selected, 0, MOTION_MODES.size() - 1)]
	var settings := {
		"type": motion_type,
		"mode": motion_mode,
		"speed": float(_speed_spin.value),
		"spin_deg_s": float(_spin_spin.value),
	}
	_motion_summary = "%s · %s" % [I18n.t(motion_type), I18n.t(motion_mode)]
	_refresh_status()
	motion_apply_requested.emit(settings)


func _on_camera_selected(index: int) -> void:
	if index < 0 or index >= CAMERA_PRESETS.size():
		return
	_camera_preset = CAMERA_PRESETS[index]
	_refresh_status()
	camera_preset_changed.emit(_camera_preset)


## The panel only reports the choice; Main calls I18n.set_locale() and then
## refreshes the panel state (which re-localizes the built-in texts).
func _on_language_selected(index: int) -> void:
	if index < 0 or index >= I18n.SUPPORTED_LOCALES.size():
		return
	language_changed.emit(I18n.SUPPORTED_LOCALES[index])


func _on_ros_toggled(enabled: bool) -> void:
	_ros_enabled = enabled
	_refresh_status()
	publish_toggled.emit(enabled)


func _on_save_pressed() -> void:
	save_requested.emit()


func _on_close_pressed() -> void:
	set_open(false)


# --- status -----------------------------------------------------------------

func _refresh_status() -> void:
	if _status_label == null:
		return
	_field_value.text = _field if _field != "" else "?"
	var scenario := _scenario_name
	if scenario == "":
		scenario = _scenario_display_name(_scenario_path) if _scenario_path != "" else "?"
	var ros_line := "ROS: "
	if not _ros_available:
		ros_line += tr("backend unavailable")
	else:
		ros_line += tr("publish ON") if _ros_enabled else tr("publish OFF")
	if _ros_status != "":
		ros_line += " · " + _ros_status
	_status_label.add_theme_color_override("font_color",
		Color(1.0, 0.72, 0.45) if _error != "" else Color(0.80, 0.93, 0.87))
	_status_label.text = (
		tr("Scenario: %s · Field: %s") % [scenario, _field if _field != "" else "?"]
		+ "\n" + tr("Targets: %d") % _target_count
		+ "\n" + tr("Motion: %s") % (_motion_summary if _motion_summary != "" else "?")
		+ "\n" + tr("Camera: %s") % _camera_preset
		+ "\n" + tr("FPS %5.1f   frame %5.2f ms") % [_fps, _frame_ms]
		+ "\n" + ros_line
		+ ("\n" + tr("Error: ") + _error if _error != "" else "")
	)


func _scenario_display_name(path: String) -> String:
	if path == "":
		return ""
	return path.get_file().get_basename()


# --- defensive state coercion ----------------------------------------------

func _as_string(value: Variant, fallback: String) -> String:
	if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
		return str(value)
	return fallback


func _as_float(value: Variant, fallback: float) -> float:
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return float(value)
	return fallback


func _as_int(value: Variant, fallback: int) -> int:
	if typeof(value) == TYPE_INT:
		return int(value)
	if typeof(value) == TYPE_FLOAT:
		return int(round(float(value)))
	return fallback


func _as_bool(value: Variant, fallback: bool) -> bool:
	if typeof(value) == TYPE_BOOL:
		return bool(value)
	return fallback
