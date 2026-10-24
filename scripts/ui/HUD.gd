class_name HUD
extends CanvasLayer

## Operator UI: status, controls, feed preview, fullscreen feed, centre
## reticle. All built in code so the scene file stays trivial.
##
## Phase 3 adds the scenario readout line and hosts the ScenarioPanel owned by
## Main (HUD never creates it): Main calls attach_scenario_panel() once and
## toggles the panel with Tab.

var _status: Label
var _controls_label: Label
var _preview_label: Label
var _hint_label: Label
var _preview_panel: PanelContainer
var _preview: TextureRect
var _fullscreen: Control
var _fullscreen_feed: TextureRect
var _target_count := 0
var _feed_texture: Texture2D
var _ego: EgoRig
var _ui_root: Control
var _scenario_panel: ScenarioPanel

## Last stats passed to _refresh_status(); replayed by retranslate() so a
## language switch immediately re-renders the status panel.
var _last_fps := 0.0
var _last_frame_ms := 0.0
var _last_yaw_deg := 0.0
var _last_pitch_deg := 0.0
var _last_self_fpv := false
var _last_free_cam := false
var _last_free_speed := 4.0
var _last_chassis_pos := Vector3.ZERO
var _last_chassis_speed := 0.0
var _last_follow_gimbal := true
var _last_view := "THIRD-PERSON"
var _last_ros_status := ""
var _last_scenario_name := ""
var _last_field := ""
var _last_target_count := -1


func _ready() -> void:
	if _status == null:
		_build_ui()


## `feed_texture` is the already-cropped 1280x1024 feed (Main.get_feed_texture).
func setup(feed_texture: Texture2D, ego: EgoRig, target_count: int) -> void:
	if _status == null:
		_build_ui()
	_feed_texture = feed_texture
	_ego = ego
	_target_count = target_count
	_preview.texture = feed_texture
	_fullscreen_feed.texture = feed_texture
	_refresh_status(0.0, 0.0, 0.0, 0.0, false, false, 4.0)


## The trailing scenario_name / field / target_count params are optional so
## existing Phase 1/2 callers keep working (target_count < 0 means "keep the
## count from setup()").
func set_stats(fps: float, frame_ms: float, yaw_deg: float, pitch_deg: float,
		self_fpv: bool, free_cam := false, free_speed := 4.0,
		chassis_pos := Vector3.ZERO, chassis_speed := 0.0,
		follow_gimbal := true, view := "THIRD-PERSON", ros_status := "",
		scenario_name := "", field := "", target_count := -1) -> void:
	_refresh_status(fps, frame_ms, yaw_deg, pitch_deg, self_fpv, free_cam, free_speed,
		chassis_pos, chassis_speed, follow_gimbal, view, ros_status,
		scenario_name, field, target_count)


## Host the Main-owned scenario overlay under the HUD canvas.  Reparents the
## panel if it already has a parent, and raises it once so it draws above the
## other HUD widgets.
func attach_scenario_panel(panel: ScenarioPanel) -> void:
	if _ui_root == null:
		_build_ui()
	if panel == null:
		return
	if panel.get_parent() != null:
		panel.get_parent().remove_child(panel)
	_ui_root.add_child(panel)
	if _fullscreen != null:
		# Keep the fullscreen feed above the scenario overlay.
		_ui_root.move_child(panel, _fullscreen.get_index())
	_scenario_panel = panel


func toggle_feed_fullscreen() -> void:
	_fullscreen.visible = not _fullscreen.visible
	_preview_panel.visible = not _fullscreen.visible


func close_feed_fullscreen() -> void:
	_fullscreen.visible = false
	_preview_panel.visible = true


func is_feed_fullscreen() -> bool:
	return _fullscreen.visible


## Re-apply the active locale to every static HUD string.  Called by Main after
## a language switch; the status panel normally refreshes via set_stats(), so
## replay the last known values to update it immediately.
func retranslate() -> void:
	if _status == null:
		_build_ui()
	_apply_static_texts()
	_refresh_status(_last_fps, _last_frame_ms, _last_yaw_deg, _last_pitch_deg,
		_last_self_fpv, _last_free_cam, _last_free_speed, _last_chassis_pos,
		_last_chassis_speed, _last_follow_gimbal, _last_view,
		_last_ros_status, _last_scenario_name, _last_field, _last_target_count)


## Localized text of the controls panel (msgids are the English UI lines).
func _controls_text() -> String:
	return (
		tr("Q / E    gimbal yaw") + "\n"
		+ tr("R / F    gimbal pitch") + "\n"
		+ tr("W / S    chassis fwd / back") + "\n"
		+ tr("A / D    chassis strafe") + "\n"
		+ tr("Shift    chassis boost") + "\n"
		+ tr("C        chassis follow gimbal") + "\n"
		+ tr("F3       operator FPV (mouse aim)") + "\n"
		+ tr("F1       feed fullscreen") + "\n"
		+ tr("F2       self in feed") + "\n"
		+ tr("F4       free camera (WASD, E/F up)") + "\n"
		+ tr("Wheel    free-cam speed") + "\n"
		+ tr("F5       reset pose") + "\n"
		+ tr("F6       ROS publish on / off") + "\n"
		+ tr("F8       reload scenario") + "\n"
		+ tr("F9       next scenario") + "\n"
		+ tr("Tab      scenario panel") + "\n"
		+ tr("F10      UI language") + "\n"
		+ tr("Esc      back / quit")
	)


func _apply_static_texts() -> void:
	if _controls_label != null:
		_controls_label.text = _controls_text()
	if _preview_label != null:
		_preview_label.text = tr("FEED 1280×1024  ·  ROS /image_raw + /image_raw/compressed")
	if _hint_label != null:
		_hint_label.text = tr("F1  back")


func _refresh_status(fps: float, frame_ms: float, yaw_deg: float, pitch_deg: float,
		self_fpv: bool, free_cam := false, free_speed := 4.0,
		chassis_pos := Vector3.ZERO, chassis_speed := 0.0,
		follow_gimbal := true, view := "THIRD-PERSON", ros_status := "",
		scenario_name := "", field := "", target_count := -1) -> void:
	_last_fps = fps
	_last_frame_ms = frame_ms
	_last_yaw_deg = yaw_deg
	_last_pitch_deg = pitch_deg
	_last_self_fpv = self_fpv
	_last_free_cam = free_cam
	_last_free_speed = free_speed
	_last_chassis_pos = chassis_pos
	_last_chassis_speed = chassis_speed
	_last_follow_gimbal = follow_gimbal
	_last_view = view
	_last_ros_status = ros_status
	_last_scenario_name = scenario_name
	_last_field = field
	_last_target_count = target_count

	var preset := _ego.preset if _ego != null else "?"
	var fpv := tr("ON") if self_fpv else tr("OFF")
	var cam: String
	if free_cam:
		cam = tr("FREE  %.1f m/s  (WASD / E F)") % free_speed
	else:
		cam = tr("camera follow (F4 = free)")
	var drive: String
	if follow_gimbal:
		drive = tr("follow gimbal (C = toggle)")
	else:
		drive = tr("independent (C = toggle)")
	var shown_targets := target_count if target_count >= 0 else _target_count
	_status.text = (
		tr("RM VISION SIM · PHASE 3") + "\n"
		+ tr("Scenario: %s   Field: %s") % [
			scenario_name if scenario_name != "" else "—",
			field if field != "" else "—"]
		+ "\n"
		+ tr("Ego: %s   View: %s") % [preset, tr(view)]
		+ "\n"
		+ tr("FPS %5.1f   frame %5.2f ms") % [fps, frame_ms]
		+ "\n"
		+ tr("Gimbal  yaw %+6.1f°   pitch %+6.1f°") % [yaw_deg, pitch_deg]
		+ "\n"
		+ tr("Chassis x %+5.2f  z %+5.2f   %4.1f m/s") % [
			chassis_pos.x, chassis_pos.z, chassis_speed]
		+ "\n"
		+ tr("Drive: %s") % drive
		+ "\n"
		+ tr("Targets %d   feed 1280×1024   self-FPV %s") % [shown_targets, fpv]
		+ "\n"
		+ tr("Camera: %s") % cam
		+ "\n"
		+ (tr(ros_status) if ros_status != "" else tr("ROS: off"))
	)


func _build_ui() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_ui_root = root

	# --- status panel (top-left) ---
	var status_panel := PanelContainer.new()
	status_panel.name = "StatusPanel"
	status_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	status_panel.offset_left = 16
	status_panel.offset_top = 16
	status_panel.offset_right = 440
	status_panel.offset_bottom = 262
	status_panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(status_panel)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", Color(0.86, 0.94, 0.90))
	status_panel.add_child(_status)

	# --- controls panel (top-right) ---
	var controls_panel := PanelContainer.new()
	controls_panel.name = "ControlsPanel"
	controls_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	controls_panel.offset_left = -336
	controls_panel.offset_top = 16
	controls_panel.offset_right = -16
	controls_panel.offset_bottom = 394
	controls_panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(controls_panel)
	var controls := Label.new()
	controls.add_theme_font_size_override("font_size", 13)
	controls.add_theme_color_override("font_color", Color(0.80, 0.90, 0.86))
	_controls_label = controls
	controls.text = _controls_text()
	controls_panel.add_child(controls)

	# --- feed preview (bottom-right) ---
	_preview_panel = PanelContainer.new()
	_preview_panel.name = "FeedPreview"
	_preview_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_preview_panel.offset_left = -372
	_preview_panel.offset_top = -324
	_preview_panel.offset_right = -16
	_preview_panel.offset_bottom = -16
	_preview_panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(_preview_panel)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 4)
	_preview_panel.add_child(pv)
	var plabel := Label.new()
	_preview_label = plabel
	plabel.text = tr("FEED 1280×1024  ·  ROS /image_raw + /image_raw/compressed")
	plabel.add_theme_font_size_override("font_size", 12)
	plabel.add_theme_color_override("font_color", Color(0.65, 0.85, 0.75))
	pv.add_child(plabel)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(320, 256)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pv.add_child(_preview)

	# --- centre reticle over the 3D view ---
	var cross := Crosshair.new()
	root.add_child(cross)

	# --- fullscreen feed overlay ---
	_fullscreen = Control.new()
	_fullscreen.name = "FullscreenFeed"
	_fullscreen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fullscreen.visible = false
	root.add_child(_fullscreen)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fullscreen.add_child(bg)

	_fullscreen_feed = TextureRect.new()
	_fullscreen_feed.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fullscreen_feed.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fullscreen_feed.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fullscreen.add_child(_fullscreen_feed)

	var hint := Label.new()
	_hint_label = hint
	hint.text = tr("F1  back")
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.7, 0.9, 0.8))
	hint.position = Vector2(20, 18)
	_fullscreen.add_child(hint)

	var cross_full := Crosshair.new()
	_fullscreen.add_child(cross_full)


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.015, 0.022, 0.026, 0.84)
	sb.border_color = Color(0.20, 0.80, 0.55, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb
