class_name SettingsPanel
extends CanvasLayer

## Persistent settings page (CanvasLayer 20, above the start screen).
##
## Main owns the page: it passes the current AppSettings values with setup(),
## shows it with set_open() (F7, the START page's SETTINGS button or Tab panel),
## and reacts to the signals below.  The page never writes user://settings.cfg
## itself; it reports one changed key at a time so Main can persist it and apply
## the ones that are live (language / self-in-feed) without touching the world.
##
## Rows:
##   - language              -> I18n (user://ui.cfg, applied immediately)
##   - default robot model   -> AppSettings, used by the next start / launch
##   - default camera preset -> AppSettings, used by the next start / launch
##   - default ROS publish   -> AppSettings, used by the next start / launch
##   - self in feed          -> AppSettings + applied to the live feed now
##   - skip start screen     -> AppSettings, used by the next launch
##
## "" for the model / camera rows means "follow the scenario YAML".

signal setting_changed(key: String, value: Variant)
signal reset_requested
signal close_requested
## "en" | "zh_CN"; the page only reports the choice, Main applies / persists it.
signal language_changed(locale: String)

const CAMERA_PRESETS: Array[String] = ["qyg", "cad", "qyg_trim"]
const FOLLOW_SCENARIO := ""
const FOLLOW_MSGID := "(scenario default)"

var _built := false

# --- controls ---------------------------------------------------------------
var _root: Control
var _body: VBoxContainer
var _language_option: OptionButton
var _robot_option: OptionButton
var _camera_option: OptionButton
var _ros_check: CheckBox
var _self_check: CheckBox
var _skip_check: CheckBox
var _reset_button: Button
var _close_button: Button

var _text_bindings: Array[Dictionary] = []
var _model_ids: Array[String] = []
var _locale := I18n.FALLBACK_LOCALE


func _init() -> void:
	_build_ui()


func _ready() -> void:
	_build_ui()


# --- public API -------------------------------------------------------------

## Fill the controls from `values` without emitting anything.
## keys: locale, ego_model, camera_preset, ros_publish, self_in_feed, skip_home.
func setup(values: Dictionary) -> void:
	_build_ui()
	_locale = I18n.normalize_locale(_as_string(values.get("locale", _locale), _locale))
	_sync_language_selection()
	_select_robot(_as_string(values.get("ego_model", FOLLOW_SCENARIO), FOLLOW_SCENARIO))
	_select_camera(_as_string(values.get("camera_preset", FOLLOW_SCENARIO), FOLLOW_SCENARIO))
	_ros_check.set_pressed_no_signal(_as_bool(values.get("ros_publish", true), true))
	_self_check.set_pressed_no_signal(_as_bool(values.get("self_in_feed", false), false))
	_skip_check.set_pressed_no_signal(_as_bool(values.get("skip_home", false), false))


## Current control values (same keys setup() accepts).
func values() -> Dictionary:
	var model := FOLLOW_SCENARIO
	if _robot_option != null and _robot_option.selected > 0:
		var model_index := _robot_option.selected - 1
		if model_index < _model_ids.size():
			model = _model_ids[model_index]
	var camera := FOLLOW_SCENARIO
	if _camera_option != null:
		var camera_index := _camera_option.selected - 1
		if camera_index >= 0 and camera_index < CAMERA_PRESETS.size():
			camera = CAMERA_PRESETS[camera_index]
	return {
		"locale": I18n.get_locale(),
		"ego_model": model,
		"camera_preset": camera,
		"ros_publish": _ros_check.button_pressed,
		"self_in_feed": _self_check.button_pressed,
		"skip_home": _skip_check.button_pressed,
	}


func set_open(open: bool) -> void:
	_build_ui()
	visible = open


func is_open() -> bool:
	return visible


## Re-apply the active locale (after I18n.set_locale()).
func retranslate() -> void:
	_build_ui()
	_locale = I18n.get_locale()
	for binding in _text_bindings:
		_set_control_text(binding["node"] as Control, String(binding["msgid"]))
	_localize_robot_option()
	_localize_camera_option()
	_sync_language_selection()


# --- construction -----------------------------------------------------------

func _build_ui() -> void:
	if _built:
		return
	_built = true
	_locale = I18n.get_locale()
	layer = 20
	# Hidden until Main shows the page with set_open().
	visible = false

	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.010, 0.014, 0.020, 0.88)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(backdrop)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.name = "SettingsPanelBody"
	panel.custom_minimum_size = Vector2(560, 0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	center.add_child(panel)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 10)
	panel.add_child(body)
	_body = body

	var title := Label.new()
	title.name = "Title"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.35, 0.98, 0.68))
	_bind_text(title, "SETTINGS")
	body.add_child(title)

	var subtitle := Label.new()
	subtitle.add_theme_font_size_override("font_size", 12)
	subtitle.add_theme_color_override("font_color", Color(0.60, 0.85, 0.74))
	_bind_text(subtitle, "STARTUP DEFAULTS")
	body.add_child(subtitle)

	body.add_child(HSeparator.new())

	var language_row := _make_row()
	language_row.add_child(_make_row_label("Language"))
	_language_option = OptionButton.new()
	_language_option.name = "SettingsLanguageOption"
	_language_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_language_option.focus_mode = Control.FOCUS_NONE
	_language_option.item_selected.connect(_on_language_selected)
	language_row.add_child(_language_option)
	_rebuild_language_items()

	var robot_row := _make_row()
	robot_row.add_child(_make_row_label("Robot model"))
	_robot_option = OptionButton.new()
	_robot_option.name = "SettingsRobotOption"
	_robot_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_robot_option.focus_mode = Control.FOCUS_NONE
	_robot_option.item_selected.connect(_on_robot_selected)
	robot_row.add_child(_robot_option)
	_model_ids = EgoModelConfig.model_ids()
	_localize_robot_option()

	var camera_row := _make_row()
	camera_row.add_child(_make_row_label("Camera"))
	_camera_option = OptionButton.new()
	_camera_option.name = "SettingsCameraOption"
	_camera_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_camera_option.focus_mode = Control.FOCUS_NONE
	_camera_option.item_selected.connect(_on_camera_selected)
	camera_row.add_child(_camera_option)
	_localize_camera_option()

	_ros_check = CheckBox.new()
	_ros_check.name = "SettingsRosCheck"
	_ros_check.focus_mode = Control.FOCUS_NONE
	_ros_check.toggled.connect(func(pressed: bool) -> void:
		setting_changed.emit(AppSettings.KEY_ROS_PUBLISH, pressed))
	_bind_text(_ros_check, "ROS publish")
	body.add_child(_ros_check)

	_self_check = CheckBox.new()
	_self_check.name = "SettingsSelfFeedCheck"
	_self_check.focus_mode = Control.FOCUS_NONE
	_self_check.toggled.connect(func(pressed: bool) -> void:
		setting_changed.emit(AppSettings.KEY_SELF_IN_FEED, pressed))
	_bind_text(_self_check, "Self in feed")
	body.add_child(_self_check)

	_skip_check = CheckBox.new()
	_skip_check.name = "SettingsSkipHomeCheck"
	_skip_check.focus_mode = Control.FOCUS_NONE
	_skip_check.toggled.connect(func(pressed: bool) -> void:
		setting_changed.emit(AppSettings.KEY_SKIP_HOME, pressed))
	_bind_text(_skip_check, "Skip start screen on launch")
	body.add_child(_skip_check)

	body.add_child(HSeparator.new())

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	body.add_child(buttons)
	_reset_button = _make_button("RESET DEFAULTS")
	_reset_button.name = "ResetButton"
	_reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reset_button.pressed.connect(func() -> void:
		reset_requested.emit())
	buttons.add_child(_reset_button)
	_close_button = _make_button("CLOSE")
	_close_button.name = "SettingsCloseButton"
	_close_button.pressed.connect(func() -> void:
		close_requested.emit())
	buttons.add_child(_close_button)

	var hint := Label.new()
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.55, 0.75, 0.68))
	_bind_text(hint, "Esc closes · changes are saved immediately")
	body.add_child(hint)


func _make_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	if _body != null:
		_body.add_child(row)
	return row


func _make_row_label(msgid: String) -> Label:
	var label := Label.new()
	label.custom_minimum_size = Vector2(230, 0)
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.72, 0.90, 0.82))
	_bind_text(label, msgid)
	return label


func _make_button(msgid: String) -> Button:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_color_override("font_color", Color(0.80, 0.98, 0.90))
	_bind_text(button, msgid)
	return button


# --- localization -----------------------------------------------------------

func _bind_text(control: Control, msgid: String) -> void:
	_text_bindings.append({"node": control, "msgid": msgid})
	_set_control_text(control, msgid)


func _set_control_text(control: Control, msgid: String) -> void:
	var text := tr(msgid)
	if control is Label:
		(control as Label).text = text
	elif control is Button:
		(control as Button).text = text


func _localize_robot_option() -> void:
	if _robot_option == null:
		return
	var selected := _robot_option.selected
	_robot_option.clear()
	_robot_option.add_item(I18n.t(FOLLOW_MSGID))
	for model_id in _model_ids:
		_robot_option.add_item(String(model_id))
	_robot_option.select(clampi(selected, 0, maxi(0, _robot_option.item_count - 1)))


func _localize_camera_option() -> void:
	if _camera_option == null:
		return
	var selected := _camera_option.selected
	_camera_option.clear()
	_camera_option.add_item(I18n.t(FOLLOW_MSGID))
	for preset in CAMERA_PRESETS:
		_camera_option.add_item(I18n.t(String(preset)))
	_camera_option.select(clampi(selected, 0, maxi(0, _camera_option.item_count - 1)))


func _rebuild_language_items() -> void:
	if _language_option == null:
		return
	var selected := _language_option.selected
	_language_option.clear()
	for locale in I18n.SUPPORTED_LOCALES:
		_language_option.add_item(I18n.locale_display_name(locale))
	_language_option.select(maxi(0, selected))


func _sync_language_selection() -> void:
	if _language_option == null:
		return
	_locale = I18n.get_locale()
	var index := I18n.SUPPORTED_LOCALES.find(_locale)
	_language_option.select(maxi(0, index))


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.015, 0.022, 0.026, 0.96)
	sb.border_color = Color(0.20, 0.80, 0.55, 0.60)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	return sb


# --- signal handlers --------------------------------------------------------

func _on_language_selected(index: int) -> void:
	if index < 0 or index >= I18n.SUPPORTED_LOCALES.size():
		return
	language_changed.emit(I18n.SUPPORTED_LOCALES[index])


func _on_robot_selected(index: int) -> void:
	var model := FOLLOW_SCENARIO
	if index > 0 and index - 1 < _model_ids.size():
		model = _model_ids[index - 1]
	setting_changed.emit(AppSettings.KEY_EGO_MODEL, model)


func _on_camera_selected(index: int) -> void:
	var preset := FOLLOW_SCENARIO
	if index > 0 and index - 1 < CAMERA_PRESETS.size():
		preset = CAMERA_PRESETS[index - 1]
	setting_changed.emit(AppSettings.KEY_CAMERA_PRESET, preset)


# --- state helpers ----------------------------------------------------------

func _select_robot(model_id: String) -> void:
	var index := 0
	if model_id != "":
		var found := _model_ids.find(model_id)
		if found >= 0:
			index = found + 1
	_robot_option.select(clampi(index, 0, maxi(0, _robot_option.item_count - 1)))


func _select_camera(preset: String) -> void:
	var index := 0
	if preset != "":
		var found := CAMERA_PRESETS.find(preset)
		if found >= 0:
			index = found + 1
	_camera_option.select(clampi(index, 0, maxi(0, _camera_option.item_count - 1)))


func _as_string(value: Variant, fallback: String) -> String:
	if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
		return str(value)
	return fallback


func _as_bool(value: Variant, fallback: bool) -> bool:
	if typeof(value) == TYPE_BOOL:
		return bool(value)
	return fallback
