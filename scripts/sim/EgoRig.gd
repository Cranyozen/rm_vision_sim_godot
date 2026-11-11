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
##   └─ GimbalYaw (world Y)         ← yaw pivot: profile `gimbal_yaw_node`
##        └─ GimbalPitch (local X)  ← pitch pivot: profile `gimbal_node`
##             ├─ GimbalVisual     ← meshes only; install-pitch compensation
##             │                       (profile `gimbal_rest_pitch_deg`)
##             ├─ CAM_DIRECTION / SHOT_DIRECTION (markers, not compensated)
##             └─ CameraMount      ← marker pose, or the profile's mount
##
## One-axis assets (no `gimbal_yaw_node`): the `gimbal_node` translation is both
## pivots and the head pitches around it.  Two-axis assets author a separate
## yaw joint; its translation is the yaw pivot and the pitch node keeps its
## authored offset from it, so yaw and pitch rotate about their real axes.

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

## Phase 5: URDF/SDF-backed profiles build a RobotRig instead of an imported
## GLB scene. The rig owns the link/joint tree; this EgoRig maps its yaw/pitch
## joints onto the operator gimbal and derives the camera mount from the
## description's optical frame. `_camera_link_node` / `_camera_optical_node`
## stay null for GLB profiles (RosBackend then uses the Phase 2/4 TF path).
var _robot_rig: RobotRig
var _robot_description: RobotDescription
var _yaw_joint_name := ""
var _pitch_joint_name := ""
## Sign that maps the operator convention (positive yaw = left, positive pitch
## = up) onto the description's joint axis direction; set when the rig is built.
var _yaw_sign := 1.0
var _pitch_sign := 1.0
var _camera_link_node: Node3D
var _camera_optical_node: Node3D


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
	_enhance_materials()
	_set_layers(self, 2)


## Build the rig from the normalized profile dictionary.
func _build_from_profile() -> void:
	_camera_marker_node = String(profile.get("camera_marker_node",
		SimConfig.CAM_DIRECTION_NODE))
	_marker_nodes = Array(profile.get("marker_nodes", []))
	camera_mount_offset = _vec3(profile.get("camera_mount_fallback_m", []))

	var description: Dictionary = profile.get("robot_description", {})
	if not String(description.get("path", "")).is_empty():
		_build_from_robot_description(description)
		return

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
	var yaw_node_name := String(profile.get("gimbal_yaw_node", ""))
	var yaw_joint: Node3D = null
	if not yaw_node_name.is_empty():
		yaw_joint = model.find_child(yaw_node_name, true, false) as Node3D

	if gimbal != null:
		_build_gimbal_from_model(gimbal, yaw_joint, floor_offset)
	elif not (profile.get("synthetic_gimbal", {}) as Dictionary).is_empty():
		_build_synthetic_gimbal(profile["synthetic_gimbal"])
	else:
		push_error("EgoRig: profile '%s' has no gimbal node '%s' and no synthetic_gimbal"
			% [preset, gimbal_node_name])


## Phase 5: build the ego from a URDF/SDF robot description.
##
## The description owns the link/joint tree; the profile names the two joints
## that behave as the operator gimbal (yaw about the body vertical, pitch about
## the body lateral axis) and the camera frames. The camera mount is derived
## from the description's optical frame, so the feed, the FPV and the published
## ROS camera chain all come from the same URDF/SDF transform.
func _build_from_robot_description(description: Dictionary) -> void:
	var path := String(description.get("path", ""))
	var format := String(description.get("format", ""))
	_robot_description = SdfLoader.load_file(path) if format == "sdf" \
		else UrdfLoader.load_file(path)
	var desc := _robot_description
	if desc == null:
		push_error("EgoRig: cannot load robot description '%s'" % path)
		_build_fallback()
		return
	for warning in desc.warnings:
		push_warning("EgoRig: %s: %s" % [path, warning])
	if not desc.errors.is_empty():
		for error in desc.errors:
			push_error("EgoRig: %s: %s" % [path, error])
		_build_fallback()
		return

	_yaw_joint_name = String(description.get("yaw_joint", ""))
	_pitch_joint_name = String(description.get("pitch_joint", ""))
	if not desc.has_joint(_yaw_joint_name) or not desc.has_joint(_pitch_joint_name):
		push_error("EgoRig: profile '%s' maps unknown joints (yaw='%s', pitch='%s')"
			% [preset, _yaw_joint_name, _pitch_joint_name])
		_build_fallback()
		return

	var options := {
		"unit_scale": float(profile.get("unit_scale", 1.0)),
		"layers": 2,
	}
	var mesh_root := String(description.get("mesh_root", ""))
	if not mesh_root.is_empty():
		options["mesh_root"] = mesh_root
	_robot_rig = RobotRig.build(desc, options)
	_robot_rig.name = "RobotDescription"
	_robot_rig.position = Vector3(0.0, float(profile.get("floor_offset_m", 0.0)), 0.0)
	_model_root = _robot_rig
	add_child(_robot_rig)

	_gimbal_yaw = _robot_rig.get_joint_node(_yaw_joint_name)
	_gimbal_pitch = _robot_rig.get_joint_node(_pitch_joint_name)
	if _gimbal_yaw == null or _gimbal_pitch == null:
		push_error("EgoRig: robot description '%s' has no joint nodes for yaw/pitch"
			% path)
		_build_fallback()
		return
	# The operator gimbal assumes a vertical yaw axis and a lateral pitch axis;
	# a description that authors different axes still builds, but warns because
	# the on-screen gimbal angles would then mean something else.
	var yaw_axis := Vector3(desc.joint(_yaw_joint_name).get("axis", Vector3.UP))
	var pitch_axis := Vector3(desc.joint(_pitch_joint_name).get("axis", Vector3.RIGHT))
	_yaw_sign = 1.0 if yaw_axis.normalized().dot(Vector3.UP) >= 0.0 else -1.0
	_pitch_sign = 1.0 if pitch_axis.normalized().dot(Vector3.RIGHT) >= 0.0 else -1.0
	if absf(yaw_axis.normalized().dot(Vector3.UP)) < 0.99:
		push_warning("EgoRig: yaw joint '%s' axis is not vertical (Godot %s)"
			% [_yaw_joint_name, yaw_axis])
	if absf(pitch_axis.normalized().dot(Vector3.RIGHT)) < 0.99:
		push_warning("EgoRig: pitch joint '%s' axis is not lateral (Godot %s)"
			% [_pitch_joint_name, pitch_axis])

	# A description has no install-pitch compensation: its joint tree already
	# models the real axes, so the visual pivot is the pitch joint itself.
	_gimbal_visual = null
	_camera_link_node = _robot_rig.get_link_node(
		String(description.get("camera_link", "")))
	_camera_optical_node = _robot_rig.get_link_node(
		String(description.get("camera_optical_frame", "")))
	if _camera_optical_node == null and _camera_link_node == null:
		push_warning("EgoRig: description '%s' has no camera_link/optical frame; using the profile camera mount fallback"
			% path)
	_camera_mount = Node3D.new()
	_camera_mount.name = "CameraMount"
	_camera_mount.transform = _description_camera_mount()
	_gimbal_pitch.add_child(_camera_mount)


## Camera pose in the description, relative to the pitch joint.
##
## Description node transforms are stored in the "conjugated" Godot frame the
## loaders use (mesh vertices are authored in the Godot frame, so the same
## transform renders correctly); a Camera3D, however, interprets its basis as a
## normal frame (-Z forward, +Y up). Converting an optical-frame pose to a
## camera pose therefore needs one Godot<-body basis change plus the
## optical->camera axis flip (X right, -Y up, -Z forward).
func _description_camera_mount() -> Transform3D:
	if _gimbal_pitch == null:
		return Transform3D(Basis.IDENTITY, camera_mount_offset)
	var optical := _camera_optical_node
	if optical != null:
		var relative := _relative_transform(_gimbal_pitch, optical)
		var optical_camera_basis := relative.basis \
			* SimConfig.body_axes_to_godot(Basis.IDENTITY) \
			* Basis(Vector3.RIGHT, PI)
		return Transform3D(optical_camera_basis, relative.origin)
	if _camera_link_node != null:
		var link_relative := _relative_transform(_gimbal_pitch, _camera_link_node)
		var optical_rpy := Vector3(-PI / 2.0, 0.0, -PI / 2.0)
		var link_camera_basis := link_relative.basis \
			* SimConfig.body_basis_to_godot(SimConfig.body_rpy_basis(optical_rpy)) \
			* SimConfig.body_axes_to_godot(Basis.IDENTITY) \
			* Basis(Vector3.RIGHT, PI)
		return Transform3D(link_camera_basis, link_relative.origin)
	# Last resort: keep the calibrated gimbal-aligned mount (Phase 2/4 default)
	# with the profile's eye offset, and warn once during the build.
	return Transform3D(Basis(Vector3.UP, deg_to_rad(camera_yaw_offset_deg)),
		camera_mount_offset)


## `node`'s transform relative to `ancestor`, walked through local transforms
## (which also makes it independent of the rig root's unit_scale).
static func _relative_transform(ancestor: Node3D, node: Node3D) -> Transform3D:
	var transform := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != ancestor:
		if current is Node3D:
			transform = (current as Node3D).transform * transform
		current = current.get_parent()
	if current != ancestor:
		push_warning("EgoRig: '%s' is not a descendant of '%s'"
			% [node.name, ancestor.name])
		return Transform3D.IDENTITY
	return transform


## Pivot chain around an authored gimbal node: keep the imported subtree, make
## it the pitch joint.
##
## One-axis assets (no separate yaw node): the pitch node's translation is also
## the yaw pivot, so both joints share that point (vehicle.glb authors GIMBAL at
## the model origin, lifted by the floor offset).
##
## Two-axis assets: `yaw_joint` is the authored yaw node and must contain the
## pitch node. Its translation becomes the yaw pivot (rotation about world Y),
## and the pitch node keeps its authored offset from it, so the pitch axis sits
## where the CAD pitches (e.g. the launcher head of the 24-sentry).
func _build_gimbal_from_model(gimbal: Node3D, yaw_joint: Node3D,
		floor_offset: float) -> void:
	var two_axis := yaw_joint != null and yaw_joint != gimbal \
		and yaw_joint.is_ancestor_of(gimbal)
	if yaw_joint != null and not two_axis:
		push_warning("EgoRig: gimbal_yaw_node '%s' does not contain gimbal node '%s'; using the single-pivot joint"
			% [yaw_joint.name, gimbal.name])
	var pivot := Vector3.ZERO
	if two_axis:
		pivot = yaw_joint.transform.origin
	else:
		pivot = gimbal.transform.origin
	_gimbal_yaw = Node3D.new()
	_gimbal_yaw.name = "GimbalYaw"
	_gimbal_yaw.position = Vector3(0.0, floor_offset, 0.0) + pivot
	add_child(_gimbal_yaw)

	if two_axis:
		# The yaw joint owns the vertical axis; the pitch joint keeps its
		# authored offset, so the two axes no longer collapse into one point.
		yaw_joint.reparent(_gimbal_yaw, true)
		yaw_joint.name = "GimbalYawJoint"
		yaw_joint.position = Vector3.ZERO
		yaw_joint.rotation = Vector3.ZERO
		gimbal.name = "GimbalPitch"
		gimbal.rotation = Vector3.ZERO
	else:
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
	if _robot_rig != null:
		# Description-backed rigs are also `_model_root`; clear it before the
		# free so the fallback boxes are built under a fresh node.
		if _model_root == _robot_rig:
			_model_root = null
		_robot_rig.queue_free()
		_robot_rig = null
		_robot_description = null
		_camera_link_node = null
		_camera_optical_node = null
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
	if _robot_rig != null:
		# Description-backed rig: drive the named joints; the axis (and the
		# sign convention) comes from the URDF/SDF, not from this script. The
		# sign factors keep the operator convention (positive yaw = left,
		# positive pitch = up) no matter which way the description points the
		# joint axes.
		_robot_rig.set_joint_value(_yaw_joint_name,
			deg_to_rad(gimbal_yaw_deg) * _yaw_sign)
		_robot_rig.set_joint_value(_pitch_joint_name,
			deg_to_rad(gimbal_pitch_deg) * _pitch_sign)
	else:
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
	# Description-backed rigs take the mount from their optical frame, so the
	# GLB camera presets ("qyg" / "cad" / "qyg_trim") are not applicable. Keep
	# the fields in sync but never override the URDF/SDF camera pose.
	if _robot_rig != null:
		return
	if _camera_mount != null and _gimbal_pitch != null:
		_camera_mount.transform = _make_camera_mount_transform(_gimbal_pitch)


func get_camera_mount() -> Node3D:
	return _camera_mount


## The gimbal pitch joint (yaw + pitch, no visual install-pitch compensation).
## This is the ROS `gimbal_link` frame: its global pose is
## odom -> gimbal_link. Null only before the rig is built.
func get_gimbal_link() -> Node3D:
	return _gimbal_pitch


## The gimbal yaw pivot: the root of the whole gimbal chain (yaw platform plus
## pitch head). Two-axis GLB assets and URDF/SDF descriptions put yaw-only
## meshes (hopper, big-yaw hardware) under it, so consumers that need "the
## chassis only" must exclude this subtree, not just the pitch joint. Null only
## before the rig is built.
func get_gimbal_yaw() -> Node3D:
	return _gimbal_yaw


## Pivot that carries the static install-pitch compensation of the head mesh.
## Null for rigs without a model mesh / compensation (and for description-backed
## rigs, whose joint tree already models the real pitch axis).
func get_gimbal_visual() -> Node3D:
	return _gimbal_visual


## Phase 5 description-backed rigs expose their ROS camera frames. The backend
## publishes these relative transforms (the URDF/SDF chain) instead of the GLB
## mount + fixed optical RPY. Both are null for GLB profiles.
func get_camera_link() -> Node3D:
	return _camera_link_node


func get_camera_optical_frame() -> Node3D:
	return _camera_optical_node


## The loaded description (null for GLB profiles / before the rig is built).
func get_robot_description() -> RobotDescription:
	return _robot_description


func get_robot_rig() -> RobotRig:
	return _robot_rig


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


## Phase 5 material pass. Missing metallic/roughness and anisotropic filtering
## live in `EgoMaterials` so new assets do not grow this rig. Authored albedo
## colours/textures are intentionally left untouched (no brightening); the
## vehicle's dark paint is the GLB's own look.
func _enhance_materials() -> void:
	EgoMaterials.enhance(self)



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
