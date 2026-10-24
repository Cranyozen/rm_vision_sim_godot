extends SceneTree

## Headless check for the Phase 1 camera model:
## - the published 1280x1024 feed is a 5:4 crop of the QYG 1440x1080 sensor,
##   rendered on a larger canvas so the off-centre principal point is kept;
## - intrinsics are square-pixel (fx == fy) and consistent with the crop;
## - both the feed camera and the operator FPV look along the gimbal/aim axis
##   (no leftover 3.7 deg CAM_DIRECTION yaw).
##
## Usage: godot --headless --path . --script res://tests/camera_accuracy_check.gd
## Expects: CAMERA_ACCURACY: PASS

var _main
var _frames := 0
var _failures: Array[String] = []


func _initialize() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)


func _check(name: String, ok: bool, detail := "") -> void:
	print(("  ok   " if ok else "  FAIL ") + name + ("  " + detail if detail != "" else ""))
	if not ok:
		_failures.append(name)


func _process(_delta: float) -> bool:
	_frames += 1
	match _frames:
		3:
			# Aim 30 deg left, 10 deg up; enter FPV so both cameras are synced.
			_main._controller.set_gimbal(30.0, 10.0)
			_main._controller.apply_to_rig()
			_main._set_fpv_mode(true)
		7:
			_check_feed_model()
			_check_camera_alignment()
		10:
			_check_fpv_alignment()
		12:
			if _failures.is_empty():
				print("CAMERA_ACCURACY: PASS")
			else:
				printerr("CAMERA_ACCURACY: FAIL (%d)" % _failures.size())
			quit(0 if _failures.is_empty() else 1)
			return true
	return false


func _check_feed_model() -> void:
	var intr := SimConfig.feed_intrinsics()
	var canvas := SimConfig.feed_canvas_size()
	var crop := SimConfig.feed_crop_rect()
	var vfov := SimConfig.vertical_fov_deg()
	var hfov := SimConfig.horizontal_fov_deg()

	_check("feed size is 1280x1024",
		intr["width"] == 1280 and intr["height"] == 1024,
		"%dx%d" % [intr["width"], intr["height"]])
	_check("feed has square pixels (fx == fy)",
		is_equal_approx(float(intr["fx"]), float(intr["fy"])),
		"fx=%.3f fy=%.3f" % [intr["fx"], intr["fy"]])
	_check("feed canvas is larger than the crop",
		canvas.x >= crop.size.x and canvas.y >= crop.size.y,
		"canvas=%s crop=%s" % [canvas, crop])
	_check("feed viewport renders the canvas",
		_main._feed_viewport.size == canvas,
		"viewport=%s canvas=%s" % [_main._feed_viewport.size, canvas])
	_check("feed camera FOV is the canvas FOV",
		is_equal_approx(_main._feed_camera.fov, SimConfig.feed_canvas_fov_deg()),
		"camera=%.3f canvas=%.3f" % [_main._feed_camera.fov, SimConfig.feed_canvas_fov_deg()])
	_check("crop sits where the principal point is",
		absf(float(intr["cx"]) - (float(canvas.x) * 0.5 - crop.position.x)) < 0.51
			and absf(float(intr["cy"]) - (float(canvas.y) * 0.5 - crop.position.y)) < 0.51,
		"cx=%.2f cy=%.2f crop=%s" % [intr["cx"], intr["cy"], crop])
	# tan(hfov/2) / tan(vfov/2) must equal 1280/1024 for a square-pixel camera.
	_check("hfov/vfov ratio matches the 5:4 feed",
		absf(tan(deg_to_rad(hfov) * 0.5) / tan(deg_to_rad(vfov) * 0.5) - 1.25) < 0.001,
		"hfov=%.3f vfov=%.3f" % [hfov, vfov])
	_check("feed vertical FOV stays 17.207 deg",
		absf(vfov - 17.207) < 0.01, "vfov=%.3f" % vfov)
	var tex: Texture2D = _main.get_feed_texture()
	_check("HUD feed texture is the 1280x1024 crop",
		tex is AtlasTexture and (tex as AtlasTexture).region.size == Vector2(1280, 1024),
		"%s" % [tex])


func _check_camera_alignment() -> void:
	var mount: Node3D = _main._ego.get_camera_mount()
	var aim: Vector3 = _aim_direction()
	var feed_forward: Vector3 = -_main._feed_camera.global_basis.z.normalized()
	_check("feed camera sits on the camera mount",
		_main._feed_camera.global_position.is_equal_approx(mount.global_position),
		"feed=%s mount=%s" % [_main._feed_camera.global_position, mount.global_position])
	_check("feed camera looks along the gimbal aim axis",
		feed_forward.dot(aim) > 0.9999,
		"dot=%.6f" % feed_forward.dot(aim))
	_check("feed camera is level (no CAD yaw)",
		absf((-mount.global_basis.z.normalized()).dot(aim)) > 0.9999,
		"mount forward dot aim=%.6f" % (-mount.global_basis.z.normalized()).dot(aim))

	# Godot's projection centre is the canvas centre; the crop must move it to
	# the published principal point.  Project a point exactly on the aim axis.
	var canvas := SimConfig.feed_canvas_size()
	var crop := SimConfig.feed_crop_rect()
	var intr := SimConfig.feed_intrinsics()
	var probe: Vector3 = _main._feed_camera.global_position + aim * 3.0
	var canvas_px: Vector2 = _main._feed_camera.unproject_position(probe)
	var feed_px := canvas_px - Vector2(crop.position)
	_check("aim axis projects to the canvas centre",
		canvas_px.distance_to(Vector2(canvas) * 0.5) < 0.6,
		"canvas=%s centre=%s" % [canvas_px, Vector2(canvas) * 0.5])
	_check("cropped feed puts the aim axis on (cx, cy)",
		absf(feed_px.x - float(intr["cx"])) < 0.6 and absf(feed_px.y - float(intr["cy"])) < 0.6,
		"feed=%s cx=%.2f cy=%.2f" % [feed_px, intr["cx"], intr["cy"]])


func _check_fpv_alignment() -> void:
	var aim: Vector3 = _aim_direction()
	var fpv_forward: Vector3 = -_main._fpv_camera.global_basis.z.normalized()
	_check("operator FPV looks along the gimbal aim axis",
		fpv_forward.dot(aim) > 0.9999,
		"dot=%.6f" % fpv_forward.dot(aim))
	_check("operator FPV keeps its wide 70 deg FOV",
		is_equal_approx(_main._fpv_camera.fov, 70.0),
		"fov=%.3f" % _main._fpv_camera.fov)


func _aim_direction() -> Vector3:
	var yaw := deg_to_rad(_main._controller.gimbal_yaw_deg)
	var pitch := deg_to_rad(_main._controller.gimbal_pitch_deg)
	return (Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * Vector3.FORWARD).normalized()
