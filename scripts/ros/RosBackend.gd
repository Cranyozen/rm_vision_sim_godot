class_name RosBackend
extends Node

## Phase 2 ROS 2 backend (rclgd).
##
## Optional at runtime: when the rclgd GDExtension is not loaded (Phase 1 host
## runs, editor without ROS) the backend reports `available == false` and the
## simulator keeps running unchanged. All rclgd classes are looked up
## dynamically, so this script parses and loads without the extension.
##
## Publishes (see RosConfig and docs/QYG_PHASE2_CONTRACT.md):
##   /image_raw              sensor_msgs/Image            30 Hz  rgb8
##   /image_raw/compressed   sensor_msgs/CompressedImage  60 Hz  jpeg q90
##   /camera_info            sensor_msgs/CameraInfo       10 Hz
##   /tf                     map->odom (chassis position), odom->gimbal_link  100 Hz
##   /tf_static              gimbal->camera, camera->optical (once per world),
##                           target centre -> armour strike face for every
##                           TargetRig (once per world)
##   /tf (targets)           map->target centre at RosConfig.TARGET_TF_HZ, so
##                           Phase 3 target motion is visible to the solver
##   /serial/receive         rm_interfaces/SerialReceiveData 50 Hz
## Subscribes:
##   /cmd_gimbal             rm_interfaces/GimbalCmd   (degrees, world yaw)
##   /cmd_chassis            rm_interfaces/ChassisCmd (optional)
##
## The simulator is the MCU: it owns TF and SerialReceiveData and never runs
## QYG's camera_driver / serial_driver / robot_state_publisher.

signal gimbal_command(yaw_deg: float, pitch_deg: float)
signal chassis_command(forward: float, strafe: float, yaw_rate_dps: float)

# Publish periods are instance state in Phase 3: scenarios can override the
# raw/compressed rates (RosConfig keeps the defaults).
var raw_period := 1.0 / RosConfig.IMAGE_RAW_HZ
var jpeg_period := 1.0 / RosConfig.IMAGE_COMPRESSED_HZ
var camera_info_period := 1.0 / RosConfig.CAMERA_INFO_HZ
var serial_period := 1.0 / RosConfig.SERIAL_HZ
var target_tf_period := 1.0 / RosConfig.TARGET_TF_HZ
var jpeg_quality := RosConfig.JPEG_QUALITY
var raw_encoding := RosConfig.IMAGE_ENCODING

var available := false
var failure := ""
var enabled := true

var _rclgd: Object = null
var _node: Object = null
var _tf: Object = null
var _publishers: Dictionary = {}
var _subscribers: Dictionary = {}

var _ego: EgoRig = null
var _controller: EgoController = null
var _feed_image_provider := Callable()
var _targets: Array[TargetRig] = []

var _static_tf_done := false
var _target_armor_tf_done := false
var _last_feed_error := ""
var _last_image: Image = null
var _last_rgb: PackedByteArray = PackedByteArray()

# JPEG encoding runs on WorkerThreadPool tasks so the 1280x1024 q90 encode
# (~10 ms) does not stall the render thread. Two slots allow a second encode to
# start while the first is still running, which keeps the 60 Hz compressed
# stream alive when the machine is loaded (one slot halves it to ~30 Hz).
var _jpeg_tasks: Array[int] = [-1, -1]
var _jpeg_pending_image: Image = null
var _jpeg_pending_stamp = null
var _jpeg_work_image: Array = [null, null]
var _jpeg_work_stamp: Array = [null, null]
var _jpeg_mutex := Mutex.new()
var _jpeg_ready: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
var _jpeg_ready_stamp: Array = [null, null]
var _jpeg_worker_ms: Array[float] = [0.0, 0.0]

var _acc_raw := 0.0
var _acc_jpeg := 0.0
var _acc_camera_info := 0.0
var _acc_tf := 0.0
var _acc_serial := 0.0
var _acc_target_tf := 0.0

var _last_gimbal_cmd_ms := -1000000
var _last_chassis_cmd_ms := -1000000
var _pending_gimbal := Vector2.ZERO   ## yaw_deg, pitch_deg in odom (chassis frame)
var _pending_gimbal_world_yaw := 0.0  ## converted to world at command receipt
var _pending_gimbal_distance := -1.0
var _chassis_cmd := Vector3.ZERO   ## forward, strafe, yaw rate (deg/s)

var _rate_window_s := 0.0
var _rate_counts := {"raw": 0, "jpeg": 0, "camera_info": 0, "tf": 0, "serial": 0}
var _rates := {"raw": 0.0, "jpeg": 0.0, "camera_info": 0.0, "tf": 0.0, "serial": 0.0}
var _timings := {"capture_ms": 0.0, "convert_ms": 0.0, "jpeg_ms": 0.0, "publish_ms": 0.0}
var _command_stats := {"gimbal": 0, "chassis": 0}


func start(ego: EgoRig, controller: EgoController, feed_image_provider: Callable,
		targets: Array[TargetRig] = []) -> bool:
	_ego = ego
	_controller = controller
	_feed_image_provider = feed_image_provider
	_targets = targets
	_target_armor_tf_done = false
	if not _try_init():
		set_process(false)
		return false
	set_process(true)
	return true


func _try_init() -> bool:
	if not ClassDB.class_exists("RosNode"):
		failure = "rclgd GDExtension not loaded"
		push_warning("RosBackend: %s; ROS publishing is off" % failure)
		return false
	_rclgd = Engine.get_singleton("rclgd")
	if _rclgd == null:
		failure = "rclgd singleton missing"
		push_warning("RosBackend: %s" % failure)
		return false
	_rclgd.call("init")

	_node = ClassDB.instantiate("RosNode")
	if _node == null:
		failure = "cannot instantiate RosNode"
		return false
	_node.call("init", RosConfig.NODE_NAME, RosConfig.NODE_NAMESPACE)

	var ok := true
	ok = _create_publisher(RosConfig.TOPIC_IMAGE_RAW, RosConfig.TYPE_IMAGE_RAW,
		RosConfig.qos_best_effort(1)) and ok
	ok = _create_publisher(RosConfig.TOPIC_IMAGE_COMPRESSED, RosConfig.TYPE_IMAGE_COMPRESSED,
		RosConfig.qos_best_effort(1)) and ok
	ok = _create_publisher(RosConfig.TOPIC_CAMERA_INFO, RosConfig.TYPE_CAMERA_INFO,
		RosConfig.qos_reliable(10)) and ok
	ok = _create_publisher(RosConfig.TOPIC_SERIAL_RECEIVE, RosConfig.TYPE_SERIAL_RECEIVE,
		RosConfig.qos_best_effort(1)) and ok
	_tf = _node.call("create_tf_broadcaster")
	if _tf == null:
		failure = "cannot create TF broadcaster"
		ok = false
	ok = _create_subscription(RosConfig.TOPIC_CMD_GIMBAL, RosConfig.TYPE_CMD_GIMBAL,
		Callable(self, "_on_cmd_gimbal"), RosConfig.qos_best_effort(5)) and ok
	ok = _create_subscription(RosConfig.TOPIC_CMD_GIMBAL_LEGACY, RosConfig.TYPE_CMD_GIMBAL,
		Callable(self, "_on_cmd_gimbal"), RosConfig.qos_best_effort(5)) and ok
	ok = _create_subscription(RosConfig.TOPIC_CMD_CHASSIS, RosConfig.TYPE_CMD_CHASSIS,
		Callable(self, "_on_cmd_chassis"), RosConfig.qos_best_effort(5)) and ok
	if not ok:
		failure = failure if failure != "" else "publisher/subscriber creation failed"
		push_error("RosBackend: %s" % failure)
		return false

	available = true
	failure = ""
	var logger = _node.call("get_logger")
	if logger != null:
		logger.call("info", "rm_vision_sim ROS backend up (rclgd)")
	return true


## Apply a scenario's `ros:` section: publish rates, image encoding / JPEG
## quality and the publish switch. Called on every scenario load, before or
## after start(); safe with no rclgd (values still take effect when it starts).
func apply_scenario(ros_cfg: Dictionary) -> void:
	var raw_hz := clampf(float(ros_cfg.get("raw_hz", RosConfig.IMAGE_RAW_HZ)), 1.0, 120.0)
	var compressed_hz := clampf(float(ros_cfg.get("compressed_hz", RosConfig.IMAGE_COMPRESSED_HZ)),
		1.0, 240.0)
	raw_period = 1.0 / raw_hz
	jpeg_period = 1.0 / compressed_hz
	var quality := clampf(float(ros_cfg.get("jpeg_quality", 90.0)), 1.0, 100.0) / 100.0
	jpeg_quality = quality
	raw_encoding = String(ros_cfg.get("raw_encoding", RosConfig.IMAGE_ENCODING))
	if raw_encoding != RosConfig.IMAGE_ENCODING:
		push_warning(("RosBackend: raw_encoding '%s' is not implemented (Phase 6 sim_codec);"
			+ " publishing rgb8") % raw_encoding)
		raw_encoding = RosConfig.IMAGE_ENCODING
	var backend := String(ros_cfg.get("backend", "rclgd"))
	if backend != "rclgd":
		push_warning("RosBackend: backend '%s' is not implemented; rclgd is the only backend" % backend)
	set_enabled(bool(ros_cfg.get("enabled", true)))


## Rebind the backend to a rebuilt ego rig / controller (scenario switch or
## ego-model change). The image provider stays the same Main callable.
func bind_robot(ego: EgoRig, controller: EgoController) -> void:
	_ego = ego
	_controller = controller
	on_world_rebuilt()


## Point the backend at the current target list (scenario / UI rebuild).
## Armour strike-face static TF is republished; the centre frames are dynamic
## and pick up the new nodes automatically.
func set_targets(targets: Array[TargetRig]) -> void:
	_targets = targets
	_target_armor_tf_done = false
	_acc_target_tf = 0.0


## Called after Main rebuilds the field / ego / targets: republish the static
## camera-mount chain and the target armour frames for the new world.
func on_world_rebuilt() -> void:
	_static_tf_done = false
	_target_armor_tf_done = false
	_acc_target_tf = 0.0


func _create_publisher(topic: String, type: String, qos_spec: Dictionary) -> bool:
	var pub = _node.call("create_publisher", topic, type, _make_qos(qos_spec))
	if pub == null:
		failure = "publisher failed: %s" % topic
		return false
	_publishers[topic] = pub
	return true


func _create_subscription(topic: String, type: String, callback: Callable, qos_spec: Dictionary) -> bool:
	var sub = _node.call("create_subscription", topic, type, callback, _make_qos(qos_spec))
	if sub == null:
		failure = "subscription failed: %s" % topic
		return false
	_subscribers[topic] = sub
	return true


func _make_qos(spec: Dictionary) -> Object:
	var qos = ClassDB.instantiate("RosQoS")
	qos.set("reliability", int(spec.get("reliability", 0)))
	qos.set("history", int(spec.get("history", 0)))
	qos.set("depth", int(spec.get("depth", 10)))
	qos.set("durability", int(spec.get("durability", 0)))
	return qos


# --- per-frame ----------------------------------------------------------------

## Apply the latest solver commands. Call before EgoController.step().
##
## The solver publishes at ~250 Hz; callbacks only stash the newest command and
## it is applied once per rendered frame. Gimbal commands are absolute world
## angles in degrees, up-positive; idle frames carry distance=-1 and must be
## ignored (otherwise the gimbal would snap to yaw=0 every time the solver
## loses the target).
func apply_commands(delta: float) -> void:
	if not available or not enabled:
		return
	var now_ms := Time.get_ticks_msec()
	if _pending_gimbal_distance >= 0.0 \
			and now_ms - _last_gimbal_cmd_ms <= int(RosConfig.GIMBAL_CMD_TIMEOUT_S * 1000.0):
		_controller.set_gimbal(_pending_gimbal_world_yaw, _pending_gimbal.y)
		gimbal_command.emit(_pending_gimbal_world_yaw, _pending_gimbal.y)
	if now_ms - _last_chassis_cmd_ms <= int(RosConfig.CMD_TIMEOUT_S * 1000.0):
		_controller.move_chassis(_chassis_cmd.x, _chassis_cmd.y, false, delta)
		if absf(_chassis_cmd.z) > 1e-3:
			_controller.rotate_chassis(_chassis_cmd.z * delta)
		_last_chassis_cmd_ms = now_ms


## Publish this frame's ROS data. Call after the pose/camera sync.
func process(delta: float) -> void:
	if not available:
		return
	_poll_jpeg()
	_rate_window_s += delta
	if _rate_window_s >= 1.0:
		for key in _rates:
			_rates[key] = float(_rate_counts[key]) / _rate_window_s
			_rate_counts[key] = 0
		_rate_window_s = 0.0

	if not enabled:
		return

	# The camera mount is static, so its two edges are published once. The
	# target armour strike-face edges are static children of the target centre
	# frame; only the centre frame moves with the target (Phase 3 motion), so it
	# is republished on /tf below. Publishing the centre frames independently of
	# the camera stream keeps them available in --headless runs and lets the
	# solver or Foxglove resolve them before the first image.
	if not _static_tf_done:
		_publish_static_tf_once()
	if not _target_armor_tf_done:
		_publish_target_armor_static_tf()

	# Target centres are now dynamic TF (map -> target_<team>_<number>). They
	# are published at TARGET_TF_HZ for every target, static or moving, so a
	# scenario switch (new/removed targets) never leaves a stale latched pose
	# and tf2 can interpolate moving targets at the image stamp.
	_acc_target_tf += delta
	if _acc_target_tf >= target_tf_period:
		_acc_target_tf = fmod(_acc_target_tf, target_tf_period)
		_publish_target_centers(_make_stamp())

	_acc_serial += delta
	var serial_due := _acc_serial >= serial_period
	if serial_due:
		_acc_serial = fmod(_acc_serial, serial_period)

	_acc_camera_info += delta
	var camera_info_due := _acc_camera_info >= camera_info_period
	if camera_info_due:
		_acc_camera_info = fmod(_acc_camera_info, camera_info_period)

	_acc_raw += delta
	_acc_jpeg += delta
	var raw_due := _acc_raw >= raw_period
	var jpeg_due := _acc_jpeg >= jpeg_period
	if raw_due:
		_acc_raw = fmod(_acc_raw, raw_period)
	if jpeg_due:
		_acc_jpeg = fmod(_acc_jpeg, jpeg_period)

	var stamp = null
	if raw_due or jpeg_due:
		if _capture_feed():
			stamp = _make_stamp()
			# TF must cover the image stamp: the solver looks the gimbal pose up
			# at the image timestamp and drops frames that are newer than the
			# newest TF sample. Publish the chain with the exact image stamp
			# (immediately, so no stale sample is emitted when the JPEG finishes
			# later) before the image/camera_info messages.
			_publish_map_odom(stamp)
			_publish_gimbal_tf(stamp)
			if camera_info_due:
				_publish_camera_info(stamp)
				camera_info_due = false
			if raw_due:
				_publish_raw_image(stamp)
			if jpeg_due:
				_submit_jpeg_encode(stamp)

	if camera_info_due:
		_publish_camera_info(_make_stamp())
	if serial_due:
		_publish_serial()


# --- image path ---------------------------------------------------------------

func _capture_feed() -> bool:
	if not _feed_image_provider.is_valid():
		return false
	var t0 := Time.get_ticks_usec()
	var image = _feed_image_provider.call()
	if image == null or not (image is Image) or (image as Image).get_width() <= 0:
		if _last_feed_error == "":
			_last_feed_error = "feed image unavailable (headless / no renderer)"
			push_warning("RosBackend: %s; camera topics publish no image" % _last_feed_error)
		return false
	# get_feed_image() returns a fresh CPU copy of the viewport texture, so it is
	# safe to convert in place (no second 4 MB duplicate).
	var rgb: Image = image
	if rgb.get_format() != Image.FORMAT_RGB8:
		rgb.convert(Image.FORMAT_RGB8)
	_last_image = rgb
	_last_rgb = rgb.get_data()
	_timings["capture_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	return true


func _publish_raw_image(stamp = null) -> void:
	if _last_image == null:
		return
	var t0 := Time.get_ticks_usec()
	var msg = _new_msg(RosConfig.TYPE_IMAGE_RAW)
	if msg == null:
		return
	_fill_header(msg, RosConfig.FRAME_CAMERA_OPTICAL, stamp)
	msg.set("height", _last_image.get_height())
	msg.set("width", _last_image.get_width())
	msg.set("encoding", raw_encoding)
	msg.set("is_bigendian", 0)
	msg.set("step", _last_image.get_width() * 3)
	msg.set("data", _last_rgb)
	_publishers[RosConfig.TOPIC_IMAGE_RAW].call("publish", msg)
	_rate_counts["raw"] += 1
	_timings["publish_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0


func _submit_jpeg_encode(stamp) -> void:
	if _last_image == null:
		return
	var slot := _free_jpeg_slot()
	if slot == -1:
		# Both workers are busy; keep only the newest pending frame. Dropping
		# the oldest pending frame is correct for a live camera stream.
		_jpeg_pending_image = _last_image
		_jpeg_pending_stamp = stamp
		return
	_start_jpeg_task(slot, _last_image, stamp)


func _free_jpeg_slot() -> int:
	for i in _jpeg_tasks.size():
		if _jpeg_tasks[i] == -1:
			return i
	return -1


func _start_jpeg_task(slot: int, image: Image, stamp) -> void:
	_jpeg_work_image[slot] = image
	_jpeg_work_stamp[slot] = stamp
	_jpeg_ready[slot] = PackedByteArray()
	_jpeg_ready_stamp[slot] = null
	_jpeg_tasks[slot] = WorkerThreadPool.add_task(
		Callable(self, "_jpeg_encode_worker").bind(slot), false, "rm_vision_sim jpeg")


func _jpeg_encode_worker(slot: int) -> void:
	var t0 := Time.get_ticks_usec()
	var jpeg: PackedByteArray = _jpeg_work_image[slot].save_jpg_to_buffer(jpeg_quality)
	var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
	_jpeg_mutex.lock()
	_jpeg_ready[slot] = jpeg
	_jpeg_ready_stamp[slot] = _jpeg_work_stamp[slot]
	_jpeg_worker_ms[slot] = elapsed
	_jpeg_mutex.unlock()


func _poll_jpeg() -> void:
	for slot in _jpeg_tasks.size():
		if _jpeg_tasks[slot] == -1 or not WorkerThreadPool.is_task_completed(_jpeg_tasks[slot]):
			continue
		WorkerThreadPool.wait_for_task_completion(_jpeg_tasks[slot])
		_jpeg_tasks[slot] = -1
		_jpeg_mutex.lock()
		var jpeg := _jpeg_ready[slot]
		var stamp = _jpeg_ready_stamp[slot]
		_jpeg_ready[slot] = PackedByteArray()
		_jpeg_ready_stamp[slot] = null
		_jpeg_mutex.unlock()
		_timings["jpeg_ms"] = _jpeg_worker_ms[slot]
		if not jpeg.is_empty():
			_publish_compressed_buffer(stamp, jpeg)
		# Start the newest frame that arrived while this slot was busy.
		if _jpeg_pending_image != null:
			var next_image := _jpeg_pending_image
			var next_stamp = _jpeg_pending_stamp
			_jpeg_pending_image = null
			_jpeg_pending_stamp = null
			_start_jpeg_task(slot, next_image, next_stamp)


func _publish_compressed_buffer(stamp, jpeg: PackedByteArray) -> void:
	# The TF sample for this stamp was already published at capture time; do not
	# republish it here with an older stamp (out-of-order TF confuses Foxglove
	# and makes the robot appear to lag).
	var t1 := Time.get_ticks_usec()
	var msg = _new_msg(RosConfig.TYPE_IMAGE_COMPRESSED)
	if msg == null:
		return
	_fill_header(msg, RosConfig.FRAME_CAMERA_OPTICAL, stamp)
	msg.set("format", "jpeg")
	msg.set("data", jpeg)
	_publishers[RosConfig.TOPIC_IMAGE_COMPRESSED].call("publish", msg)
	_rate_counts["jpeg"] += 1
	_timings["publish_ms"] = float(Time.get_ticks_usec() - t1) / 1000.0


func _publish_camera_info(stamp = null) -> void:
	var k := SimConfig.feed_intrinsics()
	var fx := float(k["fx"])
	var fy := float(k["fy"])
	var cx := float(k["cx"])
	var cy := float(k["cy"])
	var msg = _new_msg(RosConfig.TYPE_CAMERA_INFO)
	if msg == null:
		return
	_fill_header(msg, RosConfig.FRAME_CAMERA_OPTICAL, stamp)
	msg.set("height", int(k["height"]))
	msg.set("width", int(k["width"]))
	msg.set("distortion_model", RosConfig.CAMERA_DISTORTION_MODEL)
	msg.set("d", PackedFloat64Array(RosConfig.CAMERA_D))
	msg.set("k", PackedFloat64Array([fx, 0.0, cx, 0.0, fy, cy, 0.0, 0.0, 1.0]))
	msg.set("r", PackedFloat64Array([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]))
	msg.set("p", PackedFloat64Array([
		fx, 0.0, cx, 0.0,
		0.0, fy, cy, 0.0,
		0.0, 0.0, 1.0, 0.0,
	]))
	_publishers[RosConfig.TOPIC_CAMERA_INFO].call("publish", msg)
	_rate_counts["camera_info"] += 1


# --- TF -----------------------------------------------------------------------

## map is the field frame (Godot world origin = field centre) and odom is the
## robot's gimbal-base frame in the field: chassis position + chassis yaw.
## This is the standard map -> odom odometry pose, so Foxglove/RViz show the
## robot moving and turning inside the field.
func _map_odom_transform() -> Transform3D:
	var link := _ego.get_gimbal_link()
	var origin := _controller.chassis_position
	if link != null:
		origin = link.global_position
	var yaw := deg_to_rad(_controller.chassis_yaw_deg)
	return Transform3D(Basis(Vector3.UP, yaw), origin)


func _publish_map_odom(stamp = null) -> void:
	if _tf == null or _controller == null:
		return
	_tf.call("send_transform", _map_odom_transform(),
		RosConfig.FRAME_ODOM, RosConfig.FRAME_MAP, false, stamp)
	_rate_counts["tf"] += 1


## odom -> gimbal_link: rotation-only (zero translation), because QYG's solver
## treats the gimbal as the origin of odom. The chassis offset lives in
## map -> odom, so the TF tree is field-rooted while detections stay
## robot-relative.
func _publish_gimbal_tf(stamp = null) -> void:
	if _tf == null or _ego == null:
		return
	var link := _ego.get_gimbal_link()
	if link == null:
		return
	# local gimbal pose in odom: this is what QYG's solver expects (odom and
	# gimbal coincide, zero translation, yaw/pitch relative to the chassis).
	var local := _map_odom_transform().affine_inverse() * link.global_transform
	var xform := Transform3D(local.basis.orthonormalized(), Vector3.ZERO)
	_tf.call("send_transform", xform,
		RosConfig.FRAME_GIMBAL, RosConfig.FRAME_ODOM, false, stamp)
	_rate_counts["tf"] += 1


## gimbal_link->camera_link (measured mount, static) and
## camera_link->camera_optical_frame (REP-103, static). map->odom is dynamic
## (see _publish_gimbal_tf), so it is published on every TF tick.
func _publish_static_tf_once() -> void:
	if _static_tf_done or _tf == null or _ego == null:
		return
	var mount := _ego.get_camera_mount()
	var link := _ego.get_gimbal_link()
	if mount == null or link == null:
		return
	var mount_in_gimbal := link.global_transform.affine_inverse() * mount.global_transform
	_tf.call("send_transform", mount_in_gimbal,
		RosConfig.FRAME_CAMERA, RosConfig.FRAME_GIMBAL, true, null)
	_tf.call("send_transform", _optical_frame_transform(),
		RosConfig.FRAME_CAMERA_OPTICAL, RosConfig.FRAME_CAMERA, true, null)
	_static_tf_done = true


## Armour strike-face frames are static children of the target centre frame:
## `target centre -> target_..._armor_px|nx|py|ny`. The frames are built in
## target-body coordinates by TargetRig and converted to the equivalent Godot
## transform here. Published once per world rebuild (see on_world_rebuilt).
func _publish_target_armor_static_tf() -> void:
	if _tf == null:
		_target_armor_tf_done = true
		return
	for target in _targets:
		if target == null or not is_instance_valid(target):
			continue
		var center_frame := RosConfig.target_frame_id(target.team, target.number)
		for armor in target.get_armor_frames():
			var body_basis: Basis = armor["body_basis"]
			var body_position: Vector3 = armor["body_position"]
			var rel := Transform3D(
				SimConfig.body_basis_to_godot(body_basis),
				SimConfig.body_to_godot(body_position))
			_tf.call("send_transform", rel,
				RosConfig.target_armor_frame_id(target.team, target.number,
					String(armor["suffix"])),
				center_frame, true, null)
			_rate_counts["tf"] += 1
	_target_armor_tf_done = true


## Dynamic target TF: `map -> target centre`, republished every target TF tick
## from the live TargetRig root transform (Phase 3 motion moves the root, so
## the centre pose follows automatically). Static targets are republished too:
## this keeps scenario switches correct without relying on latched /tf_static
## messages for frames that may disappear.
func _publish_target_centers(stamp = null) -> void:
	if _tf == null:
		return
	for target in _targets:
		if target == null or not is_instance_valid(target):
			continue
		var center_frame := RosConfig.target_frame_id(target.team, target.number)
		_tf.call("send_transform", target.get_center_global_transform(),
			center_frame, RosConfig.FRAME_MAP, false, stamp)
		_rate_counts["tf"] += 1


## ROS camera_link -> camera_optical_frame is rpy(-pi/2, 0, -pi/2). Build the
## equivalent Godot transform so rclgd's TF broadcaster emits exactly that.
func _optical_frame_transform() -> Transform3D:
	var ros_basis := Basis.from_euler(Vector3(-PI / 2.0, 0.0, -PI / 2.0))
	return Transform3D(SimConfig.body_basis_to_godot(ros_basis), Vector3.ZERO)


# --- serial receive (MCU -> vision) ------------------------------------------

func _publish_serial() -> void:
	var msg = _new_msg(RosConfig.TYPE_SERIAL_RECEIVE)
	if msg == null:
		return
	_fill_header(msg, RosConfig.FRAME_ODOM, null)
	msg.set("mode", RosConfig.SERIAL_MODE)
	msg.set("bullet_speed", RosConfig.BULLET_SPEED_MPS)
	msg.set("roll", 0.0)
	msg.set("pitch", _controller.gimbal_pitch_deg)
	# SerialReceiveData is in odom (chassis) frame, like the TF gimbal pose.
	msg.set("yaw", wrapf(_controller.gimbal_yaw_deg - _controller.chassis_yaw_deg,
		-180.0, 180.0))
	msg.set("mcu_timestamp", Time.get_ticks_msec() & 0xFFFFFFFF)
	var judge = msg.get("judge_system_data")
	if judge != null:
		judge.set("game_status", 0)
		judge.set("remaining_time", 0)
		judge.set("blood", 0)
		judge.set("outpost_hp", 0)
	_publishers[RosConfig.TOPIC_SERIAL_RECEIVE].call("publish", msg)
	_rate_counts["serial"] += 1


# --- command subscriptions ----------------------------------------------------

func _on_cmd_gimbal(msg) -> void:
	if _controller == null:
		return
	# The solver publishes at ~250 Hz; just stash the newest command. Idle
	# frames are yaw=0/pitch=0/distance=-1 and must not move the gimbal.
	var local_yaw := float(msg.get("yaw"))
	_pending_gimbal = Vector2(local_yaw, float(msg.get("pitch")))
	# QYG commands are absolute angles in odom; odom is the chassis-aligned
	# gimbal base frame, so convert to the simulator's world yaw at receipt.
	_pending_gimbal_world_yaw = wrapf(_controller.chassis_yaw_deg + local_yaw,
		-180.0, 180.0)
	# A persistent odom-relative command plus chassis follow would be a positive
	# feedback loop (chassis chases gimbal, gimbal is chassis + constant), so ROS
	# gimbal control owns the gimbal and stops the automatic chassis follow.
	# The operator can still re-enable follow with C once commands stop.
	if _controller.follow_gimbal:
		_controller.follow_gimbal = false
	_pending_gimbal_distance = float(msg.get("distance"))
	_last_gimbal_cmd_ms = Time.get_ticks_msec()
	_command_stats["gimbal"] += 1


func _on_cmd_chassis(msg) -> void:
	var twist = msg.get("twist")
	if twist == null:
		return
	var linear = twist.get("linear")
	var angular = twist.get("angular")
	if linear == null or angular == null:
		return
	# ROS REP-103 ground vehicle: +x forward, +y left, +z yaw left.
	# EgoController.move_chassis expects strafe + = right.
	_chassis_cmd = Vector3(float(linear.get("x")), -float(linear.get("y")),
		rad_to_deg(float(angular.get("z"))))
	_last_chassis_cmd_ms = Time.get_ticks_msec()
	_command_stats["chassis"] += 1
	chassis_command.emit(_chassis_cmd.x, _chassis_cmd.y, _chassis_cmd.z)


# --- helpers ------------------------------------------------------------------

func _new_msg(type: String):
	var msg = ClassDB.instantiate("RosMsg")
	if msg == null:
		return null
	msg.call("init", type)
	return msg


func _make_stamp():
	var stamp = _new_msg("builtin_interfaces/msg/Time")
	if stamp == null:
		return null
	var now := Time.get_unix_time_from_system()
	var sec := int(floor(now))
	stamp.set("sec", sec)
	stamp.set("nanosec", int(round((now - float(sec)) * 1e9)))
	return stamp


func _fill_header(msg, frame: String, stamp = null) -> void:
	var header = msg.get("header")
	if header == null:
		return
	header.set("frame_id", frame)
	var time_msg = stamp
	if time_msg == null:
		time_msg = _make_stamp()
	if time_msg != null:
		header.set("stamp", time_msg)



func set_enabled(value: bool) -> void:
	enabled = value


func toggle_enabled() -> bool:
	enabled = not enabled
	return enabled


func get_status_line() -> String:
	if not available:
		return "ROS: off (%s)" % (failure if failure != "" else "rclgd not loaded")
	var state := "ON" if enabled else "PAUSED"
	return ("ROS rclgd %s  raw %.0f  jpg %.0f  info %.0f  tf %.0f  serial %.0f Hz\n"
		+ "enc %.1f ms  (capture %.1f / jpeg %.1f)  cmd g%d c%d"
	) % [state, _rates["raw"], _rates["jpeg"], _rates["camera_info"], _rates["tf"],
		_rates["serial"], _timings["jpeg_ms"], _timings["capture_ms"],
		(_timings["capture_ms"] + _timings["jpeg_ms"]),
		_command_stats["gimbal"], _command_stats["chassis"]]


func get_stats() -> Dictionary:
	return {
		"available": available,
		"enabled": enabled,
		"failure": failure,
		"rates": _rates.duplicate(),
		"timings": _timings.duplicate(),
		"commands": _command_stats.duplicate(),
	}


func shutdown() -> void:
	set_process(false)
	for slot in _jpeg_tasks.size():
		if _jpeg_tasks[slot] != -1:
			WorkerThreadPool.wait_for_task_completion(_jpeg_tasks[slot])
			_jpeg_tasks[slot] = -1
	_subscribers.clear()
	_publishers.clear()
	_tf = null
	_node = null
	if _rclgd != null:
		_rclgd.call("shutdown")
		_rclgd = null
	available = false
