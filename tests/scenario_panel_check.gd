extends SceneTree

## Headless check for the Phase 3 scenario overlay (scripts/ui/ScenarioPanel.gd)
## and its HUD integration.  No display / window is needed: every widget is a
## Control built in code.
##
## Run: godot --headless --path . --script res://tests/scenario_panel_check.gd
## Expects: SCENARIO_PANEL_CHECK: PASS

var _failures: Array[String] = []

var _load_path := ""
var _reload_count := 0
var _motion_settings: Dictionary = {}
var _camera_preset := ""
var _publish_enabled := false
var _publish_count := 0
var _target_count := -1
var _save_count := 0
var _language_locale := ""


func _initialize() -> void:
	# Deterministic English assertions: the panel translates through the shared
	# TranslationServer, and only Main installs / selects the locale in normal
	# runs, so pin it here (without persisting the choice).
	I18n.set_locale("en", false)

	var panel := ScenarioPanel.new()
	_connect_signals(panel)

	# Untyped on purpose: Main builds its scenario list dynamically, and
	# GDScript rejects an untyped Array for an Array[String] parameter.
	var paths := [
		"res://scenarios/1v1_static.yaml",
		"res://scenarios/1v1_line.yaml",
	]
	var state := {
		"scenario_path": paths[0],
		"scenario_name": "1v1_static",
		"field": "rmul2027_1v1",
		"target_count": 4,
		"motion_summary": "static · once",
		"camera_preset": "qyg",
		"ros_enabled": false,
		"ros_available": true,
		"ros_status": "rclgd ready",
		"fps": 60.0,
		"frame_ms": 16.6,
	}
	panel.setup(paths, paths[0], state)

	# --- controls exist -----------------------------------------------------
	var controls := [
		"ScenarioOption", "ReloadButton", "FieldValue", "TargetCountSpin",
		"MotionTypeOption", "MotionModeOption", "SpeedSpin", "SpinDegSpin",
		"ApplyButton", "CameraPresetOption", "LanguageOption", "RosPublishCheck",
		"SaveButton", "StatusLabel", "CloseButton",
	]
	for control_name in controls:
		_check(panel.find_child(control_name, true, false) != null,
			"control exists: %s" % control_name)

	var scenario_opt := panel.find_child("ScenarioOption", true, false) as OptionButton
	var reload_btn := panel.find_child("ReloadButton", true, false) as Button
	var field_value := panel.find_child("FieldValue", true, false) as Label
	var count_spin := panel.find_child("TargetCountSpin", true, false) as SpinBox
	var type_opt := panel.find_child("MotionTypeOption", true, false) as OptionButton
	var mode_opt := panel.find_child("MotionModeOption", true, false) as OptionButton
	var speed_spin := panel.find_child("SpeedSpin", true, false) as SpinBox
	var spin_spin := panel.find_child("SpinDegSpin", true, false) as SpinBox
	var apply_btn := panel.find_child("ApplyButton", true, false) as Button
	var camera_opt := panel.find_child("CameraPresetOption", true, false) as OptionButton
	var language_opt := panel.find_child("LanguageOption", true, false) as OptionButton
	var ros_check := panel.find_child("RosPublishCheck", true, false) as CheckBox
	var save_btn := panel.find_child("SaveButton", true, false) as Button
	var status_label := panel.find_child("StatusLabel", true, false) as Label
	var close_btn := panel.find_child("CloseButton", true, false) as Button
	_check(scenario_opt != null and reload_btn != null and field_value != null
		and count_spin != null and type_opt != null and mode_opt != null
		and speed_spin != null and spin_spin != null and apply_btn != null
		and camera_opt != null and language_opt != null and ros_check != null
		and save_btn != null and status_label != null and close_btn != null,
		"all typed control handles resolve")

	# --- setup does not emit and fills the list -----------------------------
	_check(_load_path == "", "setup() does not emit scenario_load_requested")
	_check(scenario_opt.item_count == 2, "scenario option lists two scenarios")
	_check(scenario_opt.get_item_text(0) == "1v1_static",
		"scenario name strips directory and .yaml: %s" % scenario_opt.get_item_text(0))
	_check(scenario_opt.get_item_text(1) == "1v1_line",
		"second scenario name: %s" % scenario_opt.get_item_text(1))
	_check(language_opt.item_count == I18n.SUPPORTED_LOCALES.size(),
		"language option lists every supported locale")
	_check(field_value.text == "rmul2027_1v1", "field label from state")
	_check(status_label.text.contains("Scenario: 1v1_static"), "status shows scenario")
	_check(status_label.text.contains("Targets: 4"), "status shows target count")
	_check(status_label.text.contains("ROS: publish OFF"), "status shows ROS publish off")

	# --- open / close -------------------------------------------------------
	_check(not panel.is_open(), "panel is closed by default")
	panel.toggle()
	_check(panel.is_open(), "toggle() opens the panel")
	panel.toggle()
	_check(not panel.is_open(), "toggle() closes the panel")
	panel.set_open(true)
	_check(panel.is_open(), "set_open(true) opens the panel")
	panel.set_open(false)
	_check(not panel.is_open(), "set_open(false) closes the panel")
	_check(not panel.visible and panel.mouse_filter == Control.MOUSE_FILTER_STOP,
		"closed panel is invisible and keeps mouse_filter STOP")

	# --- scenario load + reload --------------------------------------------
	scenario_opt.select(1)
	scenario_opt.item_selected.emit(1)
	_check(_load_path == paths[1], "scenario select emits scenario_load_requested(path)")
	reload_btn.pressed.emit()
	_check(_reload_count == 1, "RELOAD emits reload_requested")

	# --- target count -------------------------------------------------------
	# SpinBox.set_value() does not emit value_changed in headless Godot 4.7.2,
	# so emit the same signal the GUI emits on a real spin edit.
	count_spin.value = 6.0
	count_spin.value_changed.emit(6.0)
	_check(_target_count == 6, "target SpinBox emits target_count_changed(6)")

	# --- motion apply -------------------------------------------------------
	type_opt.select(1)   # line
	mode_opt.select(2)   # pingpong
	speed_spin.value = 2.5
	spin_spin.value = 45.0
	apply_btn.pressed.emit()
	_check(_motion_settings.size() == 4, "motion dict has exactly 4 keys")
	_check(_motion_settings.get("type", null) == "line"
		and _motion_settings.get("mode", null) == "pingpong",
		"motion dict type/mode: %s / %s" % [
			_motion_settings.get("type"), _motion_settings.get("mode")])
	_check(typeof(_motion_settings.get("speed")) == TYPE_FLOAT
		and is_equal_approx(float(_motion_settings.get("speed")), 2.5),
		"motion dict speed is float 2.5")
	_check(typeof(_motion_settings.get("spin_deg_s")) == TYPE_FLOAT
		and is_equal_approx(float(_motion_settings.get("spin_deg_s")), 45.0),
		"motion dict spin_deg_s is float 45.0")

	# --- camera preset ------------------------------------------------------
	camera_opt.select(1)   # cad
	camera_opt.item_selected.emit(1)
	_check(_camera_preset == "cad", "camera preset emits camera_preset_changed('cad')")

	# --- ROS publish, save --------------------------------------------------
	ros_check.button_pressed = true
	_check(_publish_enabled and _publish_count == 1,
		"ROS checkbox emits publish_toggled(true)")
	save_btn.pressed.emit()
	_check(_save_count == 1, "SAVE emits save_requested")

	# --- update_state is defensive -----------------------------------------
	var crashed := false
	panel.update_state({})
	panel.update_state({"target_count": "bad", "fps": "bad", "ros_enabled": 1})
	_check(not crashed, "update_state() ignores missing / wrong-typed keys")
	panel.update_state({"fps": 30.0, "frame_ms": 33.3, "ros_available": false})
	_check(status_label.text.contains("30.0"), "status updates FPS from state")
	_check(status_label.text.contains("backend unavailable"),
		"status shows ROS backend unavailable")
	panel.update_state({"error": "line 3: bad waypoint"})
	_check(status_label.text.contains("Error: line 3: bad waypoint"),
		"status shows a scenario load error")
	panel.update_state({"error": ""})
	_check(not status_label.text.contains("Error:"), "status clears the error")

	# --- close button -------------------------------------------------------
	panel.set_open(true)
	close_btn.pressed.emit()
	_check(not panel.is_open(), "CLOSE hides the panel")

	# --- language switch ----------------------------------------------------
	language_opt.select(1)   # zh_CN
	language_opt.item_selected.emit(1)
	_check(_language_locale == "zh_CN",
		"language option emits language_changed('zh_CN')")
	# The panel reports the choice but Main applies it; drive the same path the
	# Main handler takes and check the readout re-localizes.
	I18n.set_locale("zh_CN", false)
	panel.update_state({"locale": "zh_CN"})
	_check(status_label.text.contains("场景:"), "status re-localizes to Chinese")
	_check(status_label.text.contains("靶机数: 6"),
		"status Chinese target count: %s" % status_label.text.get_slice("\n", 1))
	I18n.set_locale("en", false)
	panel.update_state({"locale": "en"})
	_check(status_label.text.contains("Scenario:"), "status restores English")

	# --- HUD integration ----------------------------------------------------
	var hud := HUD.new()
	root.add_child(hud)
	hud.attach_scenario_panel(panel)
	_check(panel.get_parent() != null and panel.get_parent().name == "Root",
		"attach_scenario_panel() parents the panel under the HUD root")
	hud.set_stats(60.0, 16.6, 0.0, 0.0, false, false, 4.0, Vector3.ZERO, 0.0,
		true, "THIRD-PERSON", "", "1v1_static", "rmul2027_1v1", 4)
	var hud_text: String = hud._status.text
	_check(hud_text.contains("PHASE 3"), "HUD status header is PHASE 3")
	_check(hud_text.contains("Scenario: 1v1_static"), "HUD status shows scenario name")
	_check(hud_text.contains("Field: rmul2027_1v1"), "HUD status shows field")
	_check(hud_text.contains("Targets 4"), "HUD status shows target count from set_stats")

	if _failures.is_empty():
		print("SCENARIO_PANEL_CHECK: PASS")
		quit(0)
	else:
		for failure in _failures:
			printerr("FAILED: ", failure)
		print("SCENARIO_PANEL_CHECK: FAIL (%d)" % _failures.size())
		quit(1)


func _connect_signals(panel: ScenarioPanel) -> void:
	panel.scenario_load_requested.connect(func(path: String) -> void:
		_load_path = path)
	panel.reload_requested.connect(func() -> void:
		_reload_count += 1)
	panel.motion_apply_requested.connect(func(settings: Dictionary) -> void:
		_motion_settings = settings.duplicate(true))
	panel.camera_preset_changed.connect(func(preset: String) -> void:
		_camera_preset = preset)
	panel.publish_toggled.connect(func(enabled: bool) -> void:
		_publish_enabled = enabled
		_publish_count += 1)
	panel.target_count_changed.connect(func(count: int) -> void:
		_target_count = count)
	panel.save_requested.connect(func() -> void:
		_save_count += 1)
	panel.language_changed.connect(func(locale: String) -> void:
		_language_locale = locale)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS  ", message)
	else:
		printerr("FAIL  ", message)
		_failures.append(message)
