class_name HUD
extends CanvasLayer

## Phase 1 operator UI: status, controls, feed preview, fullscreen feed,
## centre reticle. All built in code so the scene file stays trivial.

var _status: Label
var _preview_panel: PanelContainer
var _preview: TextureRect
var _fullscreen: Control
var _fullscreen_feed: TextureRect
var _target_count := 0
var _feed_texture: Texture2D
var _ego: EgoRig


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


func set_stats(fps: float, frame_ms: float, yaw_deg: float, pitch_deg: float,
		self_fpv: bool, free_cam := false, free_speed := 4.0,
		chassis_pos := Vector3.ZERO, chassis_speed := 0.0,
		follow_gimbal := true, view := "THIRD-PERSON", ros_status := "") -> void:
	_refresh_status(fps, frame_ms, yaw_deg, pitch_deg, self_fpv, free_cam, free_speed,
		chassis_pos, chassis_speed, follow_gimbal, view, ros_status)


func toggle_feed_fullscreen() -> void:
	_fullscreen.visible = not _fullscreen.visible
	_preview_panel.visible = not _fullscreen.visible


func close_feed_fullscreen() -> void:
	_fullscreen.visible = false
	_preview_panel.visible = true


func is_feed_fullscreen() -> bool:
	return _fullscreen.visible


func _refresh_status(fps: float, frame_ms: float, yaw_deg: float, pitch_deg: float,
		self_fpv: bool, free_cam := false, free_speed := 4.0,
		chassis_pos := Vector3.ZERO, chassis_speed := 0.0,
		follow_gimbal := true, view := "THIRD-PERSON", ros_status := "") -> void:
	var preset := _ego.preset if _ego != null else "?"
	var fpv := "ON" if self_fpv else "OFF"
	var cam := "FREE  %.1f m/s  (WASD / E F)" % free_speed if free_cam else "camera follow (F4 = free)"
	var drive := "follow gimbal (C = toggle)" if follow_gimbal else "independent (C = toggle)"
	_status.text = (
		"RM VISION SIM · PHASE 2\n"
		+ "Field: 1v1   Ego: %s   View: %s\n" % [preset, view]
		+ "FPS %5.1f   frame %5.2f ms\n" % [fps, frame_ms]
		+ "Gimbal  yaw %+6.1f°   pitch %+6.1f°\n" % [yaw_deg, pitch_deg]
		+ "Chassis x %+5.2f  z %+5.2f   %4.1f m/s\n" % [chassis_pos.x, chassis_pos.z, chassis_speed]
		+ "Drive: %s\n" % drive
		+ "Targets %d   feed 1280×1024   self-FPV %s\n" % [_target_count, fpv]
		+ "Camera: %s\n" % cam
		+ (ros_status if ros_status != "" else "ROS: off")
	)


func _build_ui() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

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
	controls_panel.offset_bottom = 316
	controls_panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(controls_panel)
	var controls := Label.new()
	controls.add_theme_font_size_override("font_size", 13)
	controls.add_theme_color_override("font_color", Color(0.80, 0.90, 0.86))
	controls.text = (
		"Q / E    gimbal yaw\n"
		+ "R / F    gimbal pitch\n"
		+ "W / S    chassis fwd / back\n"
		+ "A / D    chassis strafe\n"
		+ "Shift    chassis boost\n"
		+ "C        chassis follow gimbal\n"
		+ "F3       operator FPV (mouse aim)\n"
		+ "F1       feed fullscreen\n"
		+ "F2       self in feed\n"
		+ "F4       free camera (WASD, E/F up)\n"
		+ "Wheel    free-cam speed\n"
		+ "F5       reset pose\n"
		+ "F6       ROS publish on / off\n"
		+ "Esc      back / quit"
	)
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
	plabel.text = "FEED 1280×1024  ·  ROS /image_raw + /image_raw/compressed"
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
	hint.text = "F1 返回"
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
