class_name RosConfig
extends RefCounted

## Phase 2 ROS interface contract (single source of truth).
##
## The simulator plays the role of the MCU: it publishes the camera stream, TF
## and SerialReceiveData, and consumes the solver's gimbal/chassis commands.
## Topic names, rates and QoS live here; the image geometry (1280x1024,
## intrinsics, crop) still comes from SimConfig.
##
## See docs/ARCHITECTURE.md § Feed pipeline / Phase 2 image contract and
## docs/QYG_PHASE2_CONTRACT.md for the QYG side.

# --- identity ----------------------------------------------------------------

const NODE_NAME := "rm_vision_sim"
const NODE_NAMESPACE := ""

const FRAME_MAP := "map"
const FRAME_ODOM := "odom"
const FRAME_GIMBAL := "gimbal_link"
const FRAME_CAMERA := "camera_link"
const FRAME_CAMERA_OPTICAL := "camera_optical_frame"

## Target TF frames. Each target centre is a `map` child:
##   target_<team>_<number>
## The origin is the target centre (midpoint of the lower armour group's plate
## centres). Its children are the armour strike-face frames:
##   target_<team>_<number>_armor_px|nx|py|ny
## where the suffix is the S120 direction vector (+X, -X, +Y, -Y) in the
## target body frame. The armour frame has +X across the plate, +Y up and +Z
## along the outward strike-face normal (15 deg above the horizon).
const FRAME_TARGET_PREFIX := "target_"


static func target_frame_id(team: String, number: String) -> String:
	return "%s%s_%s" % [FRAME_TARGET_PREFIX, team, number]


static func target_armor_frame_id(team: String, number: String, suffix: String) -> String:
	return "%s_%s" % [target_frame_id(team, number), suffix]

# --- topics ------------------------------------------------------------------

const TOPIC_IMAGE_RAW := "/image_raw"
const TOPIC_IMAGE_COMPRESSED := "/image_raw/compressed"
const TOPIC_CAMERA_INFO := "/camera_info"
const TOPIC_TF := "/tf"
const TOPIC_TF_STATIC := "/tf_static"
const TOPIC_SERIAL_RECEIVE := "/serial/receive"
const TOPIC_CMD_GIMBAL := "/armor_solver/cmd_gimbal"
## Legacy alias used by the Phase 2 plan / hand tests; subscribed for convenience.
const TOPIC_CMD_GIMBAL_LEGACY := "/cmd_gimbal"
const TOPIC_CMD_CHASSIS := "/cmd_chassis"

const TYPE_IMAGE_RAW := "sensor_msgs/msg/Image"
const TYPE_IMAGE_COMPRESSED := "sensor_msgs/msg/CompressedImage"
const TYPE_CAMERA_INFO := "sensor_msgs/msg/CameraInfo"
const TYPE_SERIAL_RECEIVE := "rm_interfaces/msg/SerialReceiveData"
const TYPE_CMD_GIMBAL := "rm_interfaces/msg/GimbalCmd"
const TYPE_CMD_CHASSIS := "rm_interfaces/msg/ChassisCmd"

# --- rates (Hz) --------------------------------------------------------------

const IMAGE_RAW_HZ := 30.0
const IMAGE_COMPRESSED_HZ := 60.0
const CAMERA_INFO_HZ := 10.0
const TF_HZ := 100.0
const SERIAL_HZ := 50.0
## Moving targets republish map -> target centre on /tf at this rate; static
## targets keep their centre edge on /tf_static (see RosBackend). Armour
## strike-face edges are always static children of the target centre frame.
const TARGET_TF_HZ := 30.0

# --- encoding ----------------------------------------------------------------

const IMAGE_ENCODING := "rgb8"
const JPEG_QUALITY := 0.90
const CAMERA_DISTORTION_MODEL := "plumb_bob"
## Phase 2 publishes no lens distortion; Phase 6 adds the Brown-Conrady model.
const CAMERA_D := [0.0, 0.0, 0.0, 0.0, 0.0]

# --- robot / MCU state -------------------------------------------------------

const BULLET_SPEED_MPS := 25.0   ## solver needs > 0 or fire_advice is always false
const SERIAL_MODE := 1          ## QYG: 1 = auto-aim blue (recorded only in this stack)
const GIMBAL_PITCH_LIMIT_DEG := 20.0

## A chassis command older than this is ignored, so a lost solver cannot drive
## the robot forever.
const CMD_TIMEOUT_S := 0.30
## A gimbal command older than this stops overriding the operator keyboard.
const GIMBAL_CMD_TIMEOUT_S := 0.50


static func qos_best_effort(depth := 1) -> Dictionary:
	return {"reliability": 1, "depth": depth, "history": 0, "durability": 0}


static func qos_reliable(depth := 10) -> Dictionary:
	return {"reliability": 0, "depth": depth, "history": 0, "durability": 0}


static func qos_transient_local(depth := 1) -> Dictionary:
	return {"reliability": 0, "depth": depth, "history": 0, "durability": 1}
