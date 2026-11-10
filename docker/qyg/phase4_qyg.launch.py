"""Phase 4 QYG closed-loop launch.

Starts only the two QYG nodes the simulator is meant to drive:

  armor_detector  -- subscribes /image_raw + /camera_info (topic mode), runs
                     YOLO/traditional detection + PnP, publishes debug armors
                     and republishes camera_info.
  armor_solver    -- consumes the detector's frames in-process through
                     VisionStateMachine, runs the EKF tracker + ballistics and
                     publishes /armor_solver/cmd_gimbal.

They MUST live in the same process, because detector->solver data does not flow
over a topic (see docs/QYG_PHASE2_CONTRACT.md section 2.3), hence the composable
container. QYG's camera_driver / serial_driver / robot_state_publisher are not
started: the simulator supplies /image_raw, /camera_info, TF and
/serial/receive.

Parameter YAMLs are read from `params_dir` (default /qyg_ws/config, baked in by
docker/qyg/build.sh; docker/run.sh qyg bind-mounts the live QYG checkout over it
when available). The simulator-specific overrides are version-independent:

  use_state_machine_camera=false   topic mode, sim publishes the images
  debug=true                       needed for /armor_detector/armors
  device=CPU                       the host has no Intel GPU (OpenVINO CPU)
  detector=yolo|tradition          tradition is useful when the YOLO model does
                                   not recognise the rendered armors
  binary_thres=N                   only used by the traditional detector; the
                                   simulator's saturated LED bars can be darker
                                   in grayscale than QYG's 80 threshold
  ignore_negative=false            keep armors whose number classifier says
                                   "negative" (sim rendering differs from the
                                   real training data)

Usage (inside the rmvision-qyg image, simulator already running):

  ros2 launch /sim/docker/qyg/phase4_qyg.launch.py
  ros2 launch /sim/docker/qyg/phase4_qyg.launch.py mode:=1 detector:=tradition
"""

import os

import yaml
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess, OpaqueFunction, TimerAction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import ComposableNodeContainer
from launch_ros.descriptions import ComposableNode


def _load_parameters(params_dir, filename):
    """Return the `/**/ros__parameters` mapping of a QYG node_params YAML."""
    path = os.path.join(params_dir, filename)
    with open(path, encoding="utf-8") as stream:
        document = yaml.safe_load(stream) or {}
    wildcard = document.get("/**") or {}
    return dict(wildcard.get("ros__parameters") or {})


def _as_bool(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _launch_setup(context, *args, **kwargs):
    params_dir = LaunchConfiguration("params_dir").perform(context)
    mode = int(LaunchConfiguration("mode").perform(context))
    device = LaunchConfiguration("device").perform(context)
    detector_type = LaunchConfiguration("detector").perform(context)
    binary_thres = LaunchConfiguration("binary_thres").perform(context).strip()
    ignore_negative = _as_bool(LaunchConfiguration("ignore_negative").perform(context))
    detector_debug = _as_bool(LaunchConfiguration("detector_debug").perform(context))
    solver_debug = _as_bool(LaunchConfiguration("solver_debug").perform(context))
    yolo_conf = LaunchConfiguration("yolo_conf").perform(context).strip()
    target_frame = LaunchConfiguration("target_frame").perform(context)

    detector_params = _load_parameters(params_dir, "armor_detector_params.yaml")
    detector_params.update(
        {
            "use_state_machine_camera": False,
            "enable_record": False,
            "debug": detector_debug,
            "detector": detector_type,
            "device": device,
            "target_frame": target_frame,
        }
    )
    if binary_thres:
        detector_params["binary_thres"] = int(binary_thres)
    if yolo_conf:
        detector_params["yolo.conf_threshold"] = float(yolo_conf)
    if not ignore_negative:
        # An empty list is normalised to a tuple by launch and rejected as a
        # parameter value, so use a name that can never match a class.
        detector_params["ignore_classes"] = ["__none__"]

    solver_params = _load_parameters(params_dir, "armor_solver_params.yaml")
    solver_params.update(
        {
            "debug": solver_debug,
            "target_frame": target_frame,
            "gimble_frame": "gimbal_link",
        }
    )

    container = ComposableNodeContainer(
        name="phase4_qyg",
        namespace="",
        package="rclcpp_components",
        executable="component_container_mt",
        composable_node_descriptions=[
            ComposableNode(
                package="armor_detector",
                plugin="qd::auto_aim::ArmorDetectorNode",
                name="armor_detector",
                parameters=[detector_params],
                extra_arguments=[{"use_intra_process_comms": True}],
            ),
            ComposableNode(
                package="armor_solver",
                plugin="qd::auto_aim::ArmorSolverNode",
                name="armor_solver",
                parameters=[solver_params],
                extra_arguments=[{"use_intra_process_comms": True}],
            ),
        ],
        output="both",
        emulate_tty=True,
        ros_arguments=["--ros-args", "--log-level", "info"],
    )

    # The simulator acts as the MCU and never runs QYG's serial driver, which is
    # what normally pushes the vision mode into the state machine. Push it once
    # through the set_mode services a couple of seconds after the container
    # starts; 0 = auto-aim red, 1 = auto-aim blue.
    mode_setter = TimerAction(
        period=2.0,
        actions=[
            ExecuteProcess(
                cmd=["python3", os.path.join(os.path.dirname(__file__), "set_vision_mode.py"),
                     "--mode", str(mode)],
                name="set_vision_mode",
                output="screen",
                shell=False,
            )
        ],
    )

    return [container, mode_setter]


def generate_launch_description():
    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "params_dir",
                default_value="/qyg_ws/config",
                description="Directory holding QYG's rm_bringup node_params YAMLs.",
            ),
            DeclareLaunchArgument(
                "mode",
                default_value="0",
                description="Vision mode: 0 = auto-aim red, 1 = auto-aim blue.",
            ),
            DeclareLaunchArgument(
                "detector",
                default_value="yolo",
                description="QYG detector backend: yolo | tradition.",
            ),
            DeclareLaunchArgument(
                "device",
                default_value="CPU",
                description="OpenVINO device for the YOLO detector (CPU/GPU).",
            ),
            DeclareLaunchArgument(
                "binary_thres",
                default_value="",
                description="Override binary_thres (empty keeps the YAML value).",
            ),
            DeclareLaunchArgument(
                "ignore_negative",
                default_value="true",
                description="Drop armors whose number classifier says 'negative'.",
            ),
            DeclareLaunchArgument(
                "yolo_conf",
                default_value="",
                description="Override yolo.conf_threshold (empty keeps the YAML value).",
            ),
            DeclareLaunchArgument(
                "target_frame",
                default_value="odom",
                description="Frame the solver expresses targets in (sim publishes odom).",
            ),
            DeclareLaunchArgument(
                "detector_debug",
                default_value="true",
                description="Publish /armor_detector/armors and debug markers/images.",
            ),
            DeclareLaunchArgument(
                "solver_debug",
                default_value="false",
                description="Publish solver debug image/markers.",
            ),
            OpaqueFunction(function=_launch_setup),
        ]
    )
