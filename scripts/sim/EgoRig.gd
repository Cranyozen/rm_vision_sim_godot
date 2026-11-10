class_name EgoRig
extends Node3D

## Own robot rig: chassis/vehicle mesh + a gimbal pivot chain that the Phase 2
## ROS backend drives with GimbalCmd (degrees, pitch up positive).
##
## Every ego robot is described by a profile (`config/ego/*.yaml`, see
## `EgoModelConfig`); this script has one config-driven builder, so adding a
## robot does not add a code branch. The standard model contract is:
## metres, Y up, forward = -Z at yaw 0, origin at the chassis centre on the
## ground, a gimbal pivot node (`GIMBAL`) and a camera marker
## (`CAM_DIRECTION`) under it. Assets that break the contract (chassis-only
## GLBs) declare `synthetic_gimbal` and the rig builds the pivot chain from the
## profile instead.
##
## EgoRoot (this node, chassis yaw)
##   └─ VehicleModel / chassis visual
##   └─ GimbalYaw (world Y)
##        └─ GimbalPitch (local X)  ← profile `gimbal_node` (default GIMBAL)
##             ├─ GimbalVisual     ← meshes only; install-pitch compensation
##             │                       (profile `gimbal_rest_pitch_deg`)
##             ├─ CAM_DIRECTION / SHOT_DIRECTION (markers, not compensated)
##             └─ CameraMount      ← marker pose, or the profile's mount

signal gimbal_changed(yaw_deg: float, pitch_deg: float)

## Profile id; the rig loads `config/ego/<preset>.yaml` when no profile was
## injected through `profile`. Kept as a String so scenarios stay simple.
var preset := SimConfig.EGO_DEFAULT_MODEL
## Optional pre-loaded/normalized profile (tests, tools). Empty = load by id.
var profile: Dictionary = {}

var chassis_yaw_deg := 0.0
var gimbal_yaw_deg := 0.0
var gimbal_pitch_deg := 0.0
var camera_mount_preset := SimConfig.CAMERA_MOUNT_PRESET   ## gimbal | cam_direction | qyg | model
var camera_mount_offset := Vector3.ZERO
var camera_mount_rpy := Vector3.ZERO
var camera_yaw_offset_deg := SimConfig.CAMERA_YAW_OFFSET_DEG

var _gimbal_yaw: Node3D
var _gimbal_pitch: Node3D
var _gimbal_visual: Node3D
var _camera_mount: Node3D
var _model_root: Node3D
var _marker_nodes: Array = []
var _camera_marker_node := SimConfig.CAM_DIRECTION_NODE
var _fixed_camera_mount := Transform3D.IDENTITY
var _has_fixed_camera_mount := false


func _ready() -> void:
	rotation.y = deg_to_rad(chassis_yaw_deg)
	_build()
	_set_layers(self, 2)
	set_gimbal(gimbal_yaw_deg, gimbal_pitch_deg)


func _build() -> void:
	if profile.is_empty():
		profile = EgoModelConfig.profile(preset)
	if profile.is_empty():
		push_error("EgoRig: unknown ego model profile '%s' (see %s)"
			% [preset, SimConfig.EGO_PROFILE_DIR])
		_build_fallback()
	else:
		_build_from_profile()
	# Search the whole rig: the gimbal subtree is re-parented out of the model
	# during the build, so a VehicleModel-only walk would miss it.
	if not profile.is_empty():
		_hide_nodes(self, profile.get("hide_node_prefixes", []))
	if _gimbal_yaw == null or _gimbal_pitch == null or _camera_mount == null:
		push_warning("EgoRig: profile '%s' incomplete, building fallback rig" % preset)
		_build_fallback()
	_brighten_dark_materials()
	_set_layers(self, 2)


## Build the rig from the normalized profile dictionary.
func _build_from_profile() -> void:
	_camera_marker_node = String(profile.get("camera_marker_node",
		SimConfig.CAM_DIRECTION_NODE))
	_marker_nodes = Array(profile.get("marker_nodes", []))
	camera_mount_offset = _vec3(profile.get("camera_mount_fallback_m", []))

	var scene_path := String(profile.get("scene_path", ""))
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("EgoRig: cannot load ego model scene '%s'" % scene_path)
		return
	var model := packed.instantiate() as Node3D
	if model == null:
		push_error("EgoRig: ego model scene root is not Node3D: %s" % scene_path)
		return
	model.name = "VehicleModel"
	var floor_offset := float(profile.get("floor_offset_m", 0.0))
	var scale := float(profile.get("unit_scale", 1.0))
	if not is_equal_approx(scale, 1.0):
		model.scale = Vector3.ONE * scale
	model.position = Vector3(0.0, floor_offset, 0.0)
	_model_root = model
	add_child(model)

	var gimbal_node_name := String(profile.get("gimbal_node", "GIMBAL"))
	var gimbal: Node3D = null
	if not gimbal_node_name.is_empty():
		gimbal = model.find_child(gimbal_node_name, true, false) as Node3D

	if gimbal != null:
		_build_gimbal_from_model(gimbal, floor_offset)
	elif not (profile.get("synthetic_gimbal", {}) as Dictionary).is_empty():
		_build_synthetic_gimbal(profile["synthetic_gimbal"])
	else:
		push_error("EgoRig: profile '%s' has no gimbal node '%s' and no synthetic_gimbal"
			% [preset, gimbal_node_name])


## Pivot chain around an authored gimbal node: keep the imported subtree, make
## it the pitch joint. The pivot sits where the model authors its gimbal node
## (vehicle.glb has it at the model origin), lifted by the floor offset.
func _build_gimbal_from_model(gimbal: Node3D, floor_offset: float) -> void:
	var pivot := gimbal.transform.origin
	_gimbal_yaw = Node3D.new()
	_gimbal_yaw.name = "GimbalYaw"
	_gimbal_yaw.position = Vector3(0.0, floor_offset, 0.0) + pivot
	add_child(_gimbal_yaw)

	# Keep the imported gimbal subtree intact; only its pivot changes.
	gimbal.reparent(_gimbal_yaw, true)
	gimbal.name = "GimbalPitch"
	gimbal.position = Vector3.ZERO
	gimbal.rotation = Vector3.ZERO
	_gimbal_pitch = gimbal
	_build_gimbal_visual(gimbal, float(profile.get("gimbal_rest_pitch_deg", 0.0)),
		_vec3(profile.get("gimbal_visual_offset_m", [])))

	_camera_mount = Node3D.new()
	_camera_mount.name = "CameraMount"
	_camera_mount.transform = _make_camera_mount_transform(gimbal)
	gimbal.add_child(_camera_mount)


## Build the yaw/pitch chain and its meshes from `synthetic_gimbal` (used by
## chassis-only assets). Positions are in rig space, above the ground plane.
func _build_synthetic_gimbal(synthetic: Dictionary) -> void:
	_gimbal_yaw = Node3D.new()
	_gimbal_yaw.name = "GimbalYaw"
	_gimbal_yaw.position = _vec3(synthetic.get("yaw_joint_m", []))
	add_child(_gimbal_yaw)

	_gimbal_pitch = Node3D.new()
	_gimbal_pitch.name = "GimbalPitch"
	_gimbal_pitch.position = _vec3(synthetic.get("pitch_joint_m", []))
	_gimbal_yaw.add_child(_gimbal_pitch)

	for part in synthetic.get("parts", []):
		_add_profile_part(part)

	var mount_position := _vec3(synthetic.get("camera_mount_m", []))
	_fixed_camera_mount = Transform3D(Basis.IDENTITY, mount_position)
	_has_fixed_camera_mount = true
	_camera_mount = Node3D.new()
	_camera_mount.name = "CameraMount"
	_camera_mount.transform = _fixed_camera_mount
	_gimbal_pitch.add_child(_camera_mount)


func _add_profile_part(part: Dictionary) -> void:
	var attach := String(part.get("attach", "pitch"))
	var parent: Node3D = _gimbal_pitch
	if attach == "yaw":
		parent = _gimbal_yaw
	elif attach == "model":
		parent = _model_root
	if parent == null:
		return
	var position := _vec3(part.get("position", []))
	var color_parts := _vec4(part.get("color", []))
	var color := Color(color_parts[0], color_parts[1], color_parts[2], color_parts[3])
	var part_name := String(part.get("name", "PART"))
	var mesh_instance: MeshInstance3D
	if String(part.get("shape", "box")) == "cylinder":
		mesh_instance = _add_cylinder(parent, float(part.get("radius", 0.05)),
			float(part.get("height", 0.1)), position, color)
	else:
		mesh_instance = _add_box(parent, _vec3(part.get("size", [])), position, color)
	mesh_instance.name = part_name
	var rotation_deg := _vec3(part.get("rotation_deg", []))
	if not rotation_deg.is_zero_approx():
		mesh_instance.rotation_degrees = rotation_deg


## Hide imported nodes whose names begin with one of the configured prefixes
## (e.g. detached sub-assemblies that are not mounted on the simulated robot).
func _hide_nodes(root: Node, prefixes: Array) -> void:
	if prefixes.is_empty():
		return
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node := stack.pop_back() as Node
		var hidden := false
		for prefix in prefixes:
			if String(node.name).begins_with(String(prefix)):
				hidden = true
				break
		if hidden:
			var node_3d := node as Node3D
			if node_3d != null:
				node_3d.visible = false
			continue
		stack.append_array(node.get_children())


## Static install-pitch compensation for models whose visual head is authored
## nose-up: rotate the visual children of the pitch node by
## `rest_pitch_deg` about the joint origin, leave the camera/shot markers on
## the pitch node untouched.
func _build_gimbal_visual(pitch_node: Node3D, rest_pitch_deg: float,
		visual_offset: Vector3) -> void:
	var visual := Node3D.new()
	visual.name = "GimbalVisual"
	visual.position = visual_offset
	visual.rotation_degrees = Vector3(rest_pitch_deg, 0.0, 0.0)
	pitch_node.add_child(visual)
	for child in pitch_node.get_children():
		if child == visual:
			continue
		if String(child.name) in _marker_nodes:
			continue
		# keep_global_transform=false: the child keeps its authored local pose
		# and therefore inherits the compensation, which is the point.
		child.reparent(visual, false)
	_gimbal_visual = visual


func _build_fallback() -> void:
	if _gimbal_yaw != null:
		_gimbal_yaw.queue_free()
		_gimbal_yaw = null
		_gimbal_pitch = null
		_gimbal_visual = null
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

	_has_fixed_camera_mount = false
	_camera_mount = Node3D.new()
	_camera_mount.name = "CameraMount"
	_camera_mount.position = Vector3(0.0, 0.03, -0.13)
	_gimbal_pitch.add_child(_camera_mount)


func _make_camera_mount_transform(pivot: Node3D) -> Transform3D:
	# Chassis-only profiles own their mount (built with the synthetic gimbal).
	if _has_fixed_camera_mount:
		return _fixed_camera_mount
	# The QYG calibration measured the optical axis along gimbal_link +X, i.e.
	# exactly the gimbal's forward axis.  The default mount therefore keeps the
	# model's eye position (camera marker translation) but uses the gimbal
	# orientation, so the FPV and the feed look where the robot aims instead of
	# 3.7 deg to the left of it.
	if camera_mount_preset == "gimbal":
		var origin := _camera_origin_from_model(pivot)
		var yaw := deg_to_rad(camera_yaw_offset_deg)
		return Transform3D(Basis(Vector3.UP, yaw), origin)
	if camera_mount_preset == "qyg":
		# Kept for comparing against the real robot calibration.  Note: this
		# preset feeds a ROS camera_link pose to a Godot camera and does not
		# include the camera_link -> camera_optical_frame basis; treat it as an
		# experiment, not a calibrated mount.
		return Transform3D(Basis.from_euler(SimConfig.QYG_CAMERA_RPY), SimConfig.QYG_CAMERA_OFFSET)
	if camera_mount_preset == "cam_direction":
		var marker := cam_direction_node(pivot, _camera_marker_node)
		if marker != null:
			return cam_direction_transform(_marker_local_transform(pivot, marker))
		push_warning("EgoRig: %s node not found, falling back to the gimbal mount"
			% _camera_marker_node)
		return Transform3D(Basis(Vector3.UP, deg_to_rad(camera_yaw_offset_deg)),
			_camera_origin_from_model(pivot))
	return Transform3D(Basis.from_euler(camera_mount_rpy), camera_mount_offset)


## Eye position in gimbal space, taken from the model's camera marker when
## available (its translation already includes the gimbal arm).
func _camera_origin_from_model(pivot: Node3D) -> Vector3:
	var marker := cam_direction_node(pivot, _camera_marker_node)
	if marker == null:
		return camera_mount_offset
	return _marker_local_transform(pivot, marker).origin


func _marker_local_transform(pivot: Node3D, marker: Node3D) -> Transform3D:
	if marker.get_parent() == pivot:
		return marker.transform
	return pivot.global_transform.affine_inverse() * marker.global_transform


## The model's camera eye-position node, in `pivot`'s space (the gimbal pitch
## node). Returns null when the active model does not ship one.
static func cam_direction_node(pivot: Node, node_name := SimConfig.CAM_DIRECTION_NODE) -> Node3D:
	if pivot == null:
		return null
	return pivot.find_child(String(node_name), true, false) as Node3D


## Convert a camera marker's local transform into a Godot camera pose: the
## marker's -Y is the view direction and its -Z is up, while a Camera3D looks
## down -Z with +Y up. The exported basis also carries a 0.001 scale, which is
## stripped before it is used as a camera orientation.
static func cam_direction_transform(marker: Transform3D) -> Transform3D:
	var correction := Basis.from_euler(SimConfig.CAM_DIRECTION_TO_CAMERA_RPY)
	return Transform3D(marker.basis.orthonormalized() * correction, marker.origin)


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


## Switch the camera mount at runtime (Phase 3 scenario camera presets / UI).
## Only the mount node is re-derived; the rig and gimbal chain are untouched.
## The feed and FPV cameras copy the mount every frame, so the change is live.
func set_camera_mount(preset_name: String, yaw_offset_deg: float) -> void:
	camera_mount_preset = preset_name
	camera_yaw_offset_deg = yaw_offset_deg
	if _camera_mount != null and _gimbal_pitch != null:
		_camera_mount.transform = _make_camera_mount_transform(_gimbal_pitch)


func get_camera_mount() -> Node3D:
	return _camera_mount


## The gimbal pitch joint (yaw + pitch, no visual install-pitch compensation).
## This is the ROS `gimbal_link` frame: its global pose is
## odom -> gimbal_link. Null only before the rig is built.
func get_gimbal_link() -> Node3D:
	return _gimbal_pitch


## Pivot that carries the static install-pitch compensation of the head mesh.
## Null for rigs without a model mesh / compensation.
func get_gimbal_visual() -> Node3D:
	return _gimbal_visual


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


# --- profile helper conversions --------------------------------------------

static func _vec3(value: Variant) -> Vector3:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() < 3:
		return Vector3.ZERO
	var items: Array = value
	return Vector3(float(items[0]), float(items[1]), float(items[2]))


static func _vec4(value: Variant) -> Array:
	if typeof(value) != TYPE_ARRAY:
		return [0.0, 0.0, 0.0, 1.0]
	var items: Array = value
	var out: Array = [0.0, 0.0, 0.0, 1.0]
	for i in mini(4, items.size()):
		out[i] = float(items[i])
	return out
