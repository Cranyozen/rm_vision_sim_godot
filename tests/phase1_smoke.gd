extends SceneTree

## Phase 1 smoke test: parse/load only. Never instantiates GLB scenes (a
## Godot 4.7.2 headless GLB instantiation in SceneTree._init has crashed).

const REQUIRED := [
	"res://scripts/app/Main.gd",
	"res://scripts/sim/SimConfig.gd",
	"res://scripts/sim/EgoRig.gd",
	"res://scripts/sim/EgoController.gd",
	"res://scripts/sim/ArmorPlate.gd",
	"res://scripts/sim/TargetRig.gd",
	"res://scripts/ui/HUD.gd",
	"res://scripts/ros/RosConfig.gd",
	"res://scripts/ros/RosBackend.gd",
	"res://scripts/ui/Crosshair.gd",
	"res://scenes/Main.tscn",
	"res://scenes/ego/EgoRig.tscn",
	"res://scenes/ui/HUD.tscn",
	"res://assets/fields/rmul2027_1v1.glb",
	"res://assets/fields/rmul2027_3v3.glb",
	"res://assets/models/ego/vehicle.glb",
	"res://assets/models/ego/infantry.glb",
	"res://assets/models/armor/armor_small.glb",
	"res://assets/models/armor/armor_large.glb",
]


func _initialize() -> void:
	var failed := 0
	if not FileAccess.file_exists("res://project.godot"):
		printerr("MISSING: res://project.godot")
		failed += 1
	for path in REQUIRED:
		var res := ResourceLoader.load(path)
		if res == null:
			printerr("MISSING/UNPARSABLE: ", path)
			failed += 1
		else:
			print("OK  ", path, "  (", res.get_class(), ")")

	var intrinsics := SimConfig.feed_intrinsics()
	var vfov := SimConfig.vertical_fov_deg()
	var hfov := SimConfig.horizontal_fov_deg()
	var canvas := SimConfig.feed_canvas_size()
	var crop := SimConfig.feed_crop_rect()
	print("feed intrinsics: ", intrinsics)
	print("feed vertical fov deg: ", vfov, "  horizontal: ", hfov)
	print("feed canvas: ", canvas, "  crop: ", crop)
	if intrinsics["width"] != 1280 or intrinsics["height"] != 1024:
		printerr("bad feed size")
		failed += 1
	if vfov <= 0.0 or vfov >= 90.0:
		printerr("bad fov: ", vfov)
		failed += 1
	# A rendered perspective camera has square pixels: fx == fy, and the
	# horizontal/vertical FOV ratio must match the 5:4 feed aspect exactly.
	if not is_equal_approx(float(intrinsics["fx"]), float(intrinsics["fy"])):
		printerr("feed fx != fy (non-square pixels)")
		failed += 1
	if absf(tan(deg_to_rad(hfov) * 0.5) / tan(deg_to_rad(vfov) * 0.5) - 1.25) > 0.001:
		printerr("feed hfov/vfov do not match the 5:4 aspect")
		failed += 1
	# The off-centre principal point is realised by cropping a larger canvas.
	if crop.size != Vector2i(1280, 1024):
		printerr("bad feed crop size: ", crop.size)
		failed += 1
	if crop.position.x < 0 or crop.position.y < 0 \
			or crop.end.x > canvas.x or crop.end.y > canvas.y:
		printerr("feed crop outside canvas: ", crop, " vs ", canvas)
		failed += 1
	if not is_equal_approx(float(intrinsics["cx"]), float(canvas.x) * 0.5 - crop.position.x):
		printerr("feed cx does not match the canvas crop")
		failed += 1
	if not is_equal_approx(float(intrinsics["cy"]), float(canvas.y) * 0.5 - crop.position.y):
		printerr("feed cy does not match the canvas crop")
		failed += 1

	if ProjectSettings.get_setting("application/run/main_scene", "") != "res://scenes/Main.tscn":
		printerr("bad main scene")
		failed += 1

	if failed == 0:
		print("PHASE1_SMOKE: PASS")
	else:
		printerr("PHASE1_SMOKE: FAIL (%d)" % failed)
	quit(1 if failed > 0 else 0)
