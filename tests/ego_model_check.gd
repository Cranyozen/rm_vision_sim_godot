extends SceneTree

## Headless check for the vehicle ego rig:
## - the detached "激光检测总装" (laser detection assembly) meshes are hidden,
## - the head mesh is levelled by the static install-pitch compensation while
##   the CAD camera/shot markers keep their authored orientation,
## - the default camera mount sits at CAM_DIRECTION and looks along the gimbal
##   forward axis.
## Usage: godot --headless --path . --script res://tests/ego_model_check.gd
## Expects: EGO_MODEL_CHECK: PASS

const HIDDEN_PREFIX := "激光检测总装"

var _frames := 0
var _rig: EgoRig
var _checked := false


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		# Build the GLB scene after the SceneTree is running; instantiating a
		# GLB from _initialize crashes on Godot 4.7.2 headless.
		_rig = load("res://scenes/ego/EgoRig.tscn").instantiate() as EgoRig
		if _rig == null:
			printerr("EGO_MODEL_CHECK: cannot instantiate EgoRig.tscn")
			printerr("EGO_MODEL_CHECK: FAIL")
			quit(1)
			return true
		root.add_child(_rig)
		return false
	if _frames < 4:
		return false

	var gimbal := _rig.find_child("GimbalPitch", true, false) as Node3D
	var failures: Array[String] = []
	if gimbal == null:
		failures.append("GimbalPitch missing")
	else:
		var hidden_count := 0
		for node in _rig.find_children(HIDDEN_PREFIX + "*", "", true, false):
			hidden_count += 1
			var is_visible := (node as Node3D).visible
			print("laser part: ", node.name, " visible=", is_visible)
			if is_visible:
				failures.append("%s still visible" % node.name)
		if hidden_count != 2:
			failures.append("expected 2 laser parts, found %d" % hidden_count)

		# Static install-pitch compensation: the model's head is authored 25 deg
		# nose-up, so the visual pivot cancels it while the CAD markers stay on
		# the pitch node with their authored (level) orientation.
		var visual := gimbal.get_node_or_null("GimbalVisual") as Node3D
		if visual == null:
			failures.append("GimbalVisual missing")
		else:
			var rest_deg := rad_to_deg(visual.rotation.x)
			print("GimbalVisual rest pitch=%.3f deg (expected %.1f)" % [rest_deg, SimConfig.GIMBAL_REST_PITCH_DEG])
			if absf(rest_deg - SimConfig.GIMBAL_REST_PITCH_DEG) > 0.01:
				failures.append("GimbalVisual rest pitch is %.3f deg" % rest_deg)
			for marker_name in SimConfig.GIMBAL_MARKER_NODES:
				var marker_node := gimbal.get_node_or_null(marker_name) as Node3D
				if marker_node == null:
					failures.append("%s is not a direct child of GimbalPitch" % marker_name)
			var main := visual.get_node_or_null("GIMBAL_MAIN") as Node3D
			if main == null:
				failures.append("GIMBAL_MAIN not under GimbalVisual")
			elif not main.visible:
				failures.append("GIMBAL_MAIN hidden by mistake")
			# The markers must NOT inherit the compensation: their authored
			# camera forward stays level in rig space.
			var marker := EgoRig.cam_direction_node(gimbal)
			if marker == null:
				failures.append("CAM_DIRECTION missing")
			elif marker.get_parent() != gimbal:
				failures.append("CAM_DIRECTION is under the compensated pivot")
			else:
				var cad_forward: Vector3 = (marker.global_transform.basis.orthonormalized()
					* Vector3(0.0, -1.0, 0.0)).normalized()
				print("CAD marker forward=", cad_forward)
				if absf(cad_forward.y) > 0.001:
					failures.append("CAD marker forward is not level (%s)" % cad_forward)

		# Default mount policy is "gimbal": the eye position comes from the
		# model's CAM_DIRECTION translation, but the orientation is the gimbal
		# forward axis (QYG calibration measured a 0.000 deg optical-axis
		# offset).  The marker's own 3.7 deg left yaw is deliberately NOT used,
		# otherwise the FPV and feed look 3.7 deg left of where the robot aims.
		var mount := _rig.get_camera_mount()
		var marker := EgoRig.cam_direction_node(gimbal)
		if mount == null or marker == null:
			failures.append("CameraMount / CAM_DIRECTION missing")
		elif _rig.camera_mount_preset != "gimbal":
			failures.append("default camera_mount_preset is not 'gimbal'")
		elif not mount.transform.origin.is_equal_approx(marker.transform.origin):
			failures.append("CameraMount not at CAM_DIRECTION")
		else:
			var forward := -mount.transform.basis.z.normalized()
			var up := mount.transform.basis.y.normalized()
			print("camera forward=", forward, " up=", up)
			if absf(up.dot(Vector3.UP)) < 0.9999:
				failures.append("camera is not level (up=%s)" % up)
			if forward.dot(Vector3.FORWARD) < 0.9999:
				failures.append("camera does not look along the gimbal forward axis (forward=%s)" % forward)

	# Nothing visible may float above the gimbal body: the real chassis + gimbal
	# top out around y = 0.44 in rig space, the hidden laser parts reach 0.90.
	var visible_top := -INF
	for node in _rig.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if not mesh_instance.is_visible_in_tree():
			continue
		var bounds := mesh_instance.global_transform * mesh_instance.get_aabb()
		visible_top = maxf(visible_top, bounds.end.y)
	print("visible mesh top y=", visible_top)
	if visible_top > 0.55:
		failures.append("visible geometry floats above the gimbal (y=%.3f)" % visible_top)

	if failures.is_empty():
		print("EGO_MODEL_CHECK: PASS")
	else:
		for failure in failures:
			printerr("EGO_MODEL_CHECK: ", failure)
		printerr("EGO_MODEL_CHECK: FAIL")
	quit(0 if failures.is_empty() else 1)
	return true
