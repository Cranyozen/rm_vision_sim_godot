class_name EgoRig
extends Node3D

## Own robot rig: real chassis/vehicle mesh + a gimbal pivot chain that the
## Phase 2 ROS backend will drive with GimbalCmd (degrees, pitch up positive).
##
## EgoRoot (this node, chassis yaw)
##   └─ VehicleModel / chassis visual
##   └─ GimbalYaw (world Y)
##        └─ GimbalPitch (local X)  ← vehicle.glb "GIMBAL" node
##             └─ CameraMount      ← camera_link pose

signal gimbal_changed(yaw_deg: float, pitch_deg: float)

const VEHICLE_FLOOR_OFFSET := 0.2101   ## chassis bottom -> y=0 for vehicle.glb
const INFANTRY_FLOOR_OFFSET := 0.074366
const INFANTRY_TOP := 0.152

## vehicle.glb ships two "激光检测总装" (laser detection assembly) meshes under
## GIMBAL. They float 0.2 m / 0.4 m above the gimbal body instead of sitting on
## it, so they do not belong on the simulated robot. Hide them at load time and
## leave the source GLB untouched. Godot sanitises the imported names to
## "激光检测总装_001" / "激光检测总装_002".
const HIDDEN_MODEL_NODE_PREFIX := "激光检测总装"

var preset := "vehicle"                 ## vehicle | infantry_light | fallback
var chassis_yaw_deg := 0.0
var gimbal_yaw_deg := 0.0
var gimbal_pitch_deg := 0.0
var camera_mount_preset := "model"      ## model | qyg
var camera_mount_offset := SimConfig.VEHICLE_CAMERA_OFFSET
var camera_mount_rpy := Vector3.ZERO

var _gimbal_yaw: Node3D
var _gimbal_pitch: Node3D
var _camera_mount: Node3D
var _model_root: Node3D


func _ready() -> void:
	rotation.y = deg_to_rad(chassis_yaw_deg)
	_build()
	_set_layers(self, 2)
	set_gimbal(gimbal_yaw_deg, gimbal_pitch_deg)


func _build() -> void:
	match preset:
		"infantry_light":
			_build_infantry_light()
		_:
			_build_vehicle()
	# Search the whole rig: the gimbal subtree is re-parented out of the model
	# during _build_vehicle(), so a VehicleModel-only walk would miss it.
	_hide_laser_detection_modules(self)
	if _gimbal_yaw == null or _gimbal_pitch == null or _camera_mount == null:
		push_warning("EgoRig: preset '%s' incomplete, building fallback rig" % preset)
		_build_fallback()
	_brighten_dark_materials()
	_set_layers(self, 2)


## Hide every imported "激光检测总装*" node (laser detection assembly) in the
## source robot model. They are not mounted on the simulated robot and would
## otherwise render as floating parts above the gimbal. Recursive so it also
## covers models that nest the parts deeper than vehicle.glb does.
func _hide_laser_detection_modules(model: Node) -> void:
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var node := stack.pop_back() as Node
		if String(node.name).begins_with(HIDDEN_MODEL_NODE_PREFIX):
			var hidden := node as Node3D
			if hidden != null:
				hidden.visible = false
			continue
		stack.append_array(node.get_children())


func _build_vehicle() -> void:
	var packed := load(SimConfig.EGO_VEHICLE_PATH) as PackedScene
	if packed == null:
		push_error("EgoRig: cannot load %s" % SimConfig.EGO_VEHICLE_PATH)
		return
	var model := packed.instantiate() as Node3D
	if model == null:
		push_error("EgoRig: vehicle scene root is not Node3D")
		return
	model.name = "VehicleModel"
	model.position = Vector3(0.0, VEHICLE_FLOOR_OFFSET, 0.0)
	_model_root = model
	add_child(model)

	var gimbal := model.find_child("GIMBAL", true, false) as Node3D
	if gimbal == null:
		push_error("EgoRig: GIMBAL node not found in vehicle.glb")
		return

	_gimbal_yaw = Node3D.new()
	_gimbal_yaw.name = "GimbalYaw"
	_gimbal_yaw.position = Vector3(0.0, VEHICLE_FLOOR_OFFSET, 0.0)
	add_child(_gimbal_yaw)

	# Keep the imported gimbal subtree intact; only its pivot changes.
	gimbal.reparent(_gimbal_yaw, true)
	gimbal.name = "GimbalPitch"
	gimbal.position = Vector3.ZERO
	gimbal.rotation = Vector3.ZERO
	_gimbal_pitch = gimbal

	_camera_mount = Node3D.new()
	_camera_mount.name = "CameraMount"
	_camera_mount.transform = _make_camera_mount_transform()
	gimbal.add_child(_camera_mount)


func _build_infantry_light() -> void:
	var packed := load(SimConfig.EGO_INFANTRY_PATH) as PackedScene
	if packed == null:
		push_error("EgoRig: cannot load %s" % SimConfig.EGO_INFANTRY_PATH)
		return
	var model := packed.instantiate() as Node3D
	if model == null:
		return
	model.name = "InfantryModel"
	model.scale = Vector3.ONE * 0.001          # glb is authored in millimetres
	model.position = Vector3(0.0, INFANTRY_FLOOR_OFFSET, 0.0)
	_model_root = model
	add_child(model)

	_gimbal_yaw = Node3D.new()
	_gimbal_yaw.name = "GimbalYaw"
	_gimbal_yaw.position = Vector3(0.0, INFANTRY_TOP, 0.0)
	add_child(_gimbal_yaw)
	_add_cylinder(_gimbal_yaw, 0.055, 0.035, Vector3(0.0, 0.02, 0.0), Color(0.09, 0.10, 0.11))

	_gimbal_pitch = Node3D.new()
	_gimbal_pitch.name = "GimbalPitch"
	_gimbal_pitch.position = Vector3(0.0, 0.045, 0.0)
	_gimbal_yaw.add_child(_gimbal_pitch)
	_add_box(_gimbal_pitch, Vector3(0.16, 0.075, 0.13), Vector3(0.0, 0.02, -0.02), Color(0.06, 0.07, 0.08))
	_add_box(_gimbal_pitch, Vector3(0.075, 0.06, 0.11), Vector3(0.055, 0.02, -0.07), Color(0.10, 0.11, 0.12))
	_add_box(_gimbal_pitch, Vector3(0.075, 0.06, 0.11), Vector3(-0.055, 0.02, -0.07), Color(0.10, 0.11, 0.12))
	_add_cylinder(_gimbal_pitch, 0.026, 0.045, Vector3(0.0, 0.02, -0.135), Color(0.02, 0.02, 0.02)).rotation.x = PI * 0.5

	_camera_mount = Node3D.new()
	_camera_mount.name = "CameraMount"
	_camera_mount.position = Vector3(0.0, 0.035, -0.11)
	_gimbal_pitch.add_child(_camera_mount)


func _build_fallback() -> void:
	if _gimbal_yaw != null:
		_gimbal_yaw.queue_free()
		_gimbal_yaw = null
	if _model_root == null:
		_model_root = Node3D.new()
		_model_root.name = "FallbackModel"
		add_child(_model_root)
		_add_box(_model_root, Vector3(0.50, 0.20, 0.44), Vector3(0.0, 0.10, 0.0), Color(0.10, 0.11, 0.12))
	_add_box(_model_root, Vector3(0.24, 0.08, 0.20), Vector3(0.0, 0.22, 0.0), Color(0.06, 0.07, 0.08))

	_gimbal_yaw = Node3D.new()
	_gimbal_yaw.name = "GimbalYaw"
	_gimbal_yaw.position = Vector3(0.0, 0.22, 0.0)
	add_child(_gimbal_yaw)
	_gimbal_pitch = Node3D.new()
	_gimbal_pitch.name = "GimbalPitch"
	_gimbal_pitch.position = Vector3(0.0, 0.05, 0.0)
	_gimbal_yaw.add_child(_gimbal_pitch)
	_add_box(_gimbal_pitch, Vector3(0.18, 0.14, 0.16), Vector3(0.0, 0.02, -0.03), Color(0.07, 0.08, 0.09))

	_camera_mount = Node3D.new()
	_camera_mount.name = "CameraMount"
	_camera_mount.position = Vector3(0.0, 0.03, -0.13)
	_gimbal_pitch.add_child(_camera_mount)


func _make_camera_mount_transform() -> Transform3D:
	if camera_mount_preset == "qyg":
		return Transform3D(Basis.from_euler(SimConfig.QYG_CAMERA_RPY), SimConfig.QYG_CAMERA_OFFSET)
	return Transform3D(Basis.from_euler(camera_mount_rpy), camera_mount_offset)


func set_gimbal(yaw_deg: float, pitch_deg: float) -> void:
	gimbal_yaw_deg = yaw_deg
	gimbal_pitch_deg = clampf(pitch_deg, -30.0, 30.0)
	if _gimbal_yaw != null:
		_gimbal_yaw.rotation.y = deg_to_rad(gimbal_yaw_deg)
	if _gimbal_pitch != null:
		_gimbal_pitch.rotation.x = deg_to_rad(gimbal_pitch_deg)
	gimbal_changed.emit(gimbal_yaw_deg, gimbal_pitch_deg)


func set_chassis_yaw(yaw_deg: float) -> void:
	chassis_yaw_deg = yaw_deg
	rotation.y = deg_to_rad(yaw_deg)


func get_camera_mount() -> Node3D:
	return _camera_mount


func get_gimbal_pivot() -> Node3D:
	return _gimbal_yaw


func _add_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = _matte(color)
	mi.layers = 2
	parent.add_child(mi)
	return mi


func _add_cylinder(parent: Node3D, radius: float, height: float, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 20
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = _matte(color)
	mi.layers = 2
	parent.add_child(mi)
	return mi


func _matte(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.35
	mat.roughness = 0.62
	return mat


func _set_layers(root: Node, layers: int) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node := stack.pop_back() as Node
		if node == null:
			continue
		if node is GeometryInstance3D:
			(node as GeometryInstance3D).layers = layers
		for child in node.get_children():
			stack.append(child)


## The sourced vehicle model uses near-black paint (albedo ~0.008 and pure
## black). Lift those surfaces slightly so the ego silhouette is readable in
## the third-person view; team/emissive materials are left untouched.
func _brighten_dark_materials() -> void:
	for mi in _all_mesh_instances(self):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var mat := mi.get_active_material(i)
			if not (mat is StandardMaterial3D):
				continue
			var std := mat as StandardMaterial3D
			if std.emission_enabled:
				continue
			if std.albedo_color.get_luminance() > 0.06:
				continue
			var lifted := std.duplicate() as StandardMaterial3D
			lifted.albedo_color = Color(0.085, 0.090, 0.100)
			lifted.metallic = 0.30
			lifted.roughness = 0.55
			mi.set_surface_override_material(i, lifted)


func _all_mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node := stack.pop_back() as Node
		if node == null:
			continue
		if node is MeshInstance3D:
			out.append(node as MeshInstance3D)
		for child in node.get_children():
			stack.append(child)
	return out
