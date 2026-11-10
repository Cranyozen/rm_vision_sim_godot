# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Phase 4: QYG `armor_detector` + `armor_solver` runtime image.
#
# Derived from `rmvision-rclgd:humble` so the same container can run the
# simulator (Godot + rclgd) or the QYG vision stack. Only the four QYG packages
# needed for the closed loop are built; QYG's camera/serial drivers and
# robot_state_publisher are deliberately not built or started (the simulator
# supplies /image_raw, /camera_info, TF and /serial/receive itself).
#
# Build (stages the QYG sources first):
#   docker/qyg/build.sh
#
# Run (needs the simulator running with the same ROS_DOMAIN_ID / DDS domain):
#   docker/run.sh qyg
# ---------------------------------------------------------------------------
FROM rmvision-rclgd:humble

ARG DEBIAN_FRONTEND=noninteractive

# ROS/OpenCV/Ceres deps required by rm_utils, armor_detector and armor_solver.
# See QYG_QDVision2026/src/{rm_utils,rm_auto_aim/*}/package.xml.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      git \
      gnupg \
      pkg-config \
      python3-colcon-common-extensions \
      libopencv-dev \
      libeigen3-dev \
      libceres-dev \
      libfmt-dev \
      libtbb-dev \
      libyaml-cpp-dev \
      ros-humble-ament-cmake-auto \
      ros-humble-ament-cmake-gtest \
      ros-humble-ament-cmake-clang-format \
      ros-humble-angles \
      ros-humble-camera-info-manager \
      ros-humble-cv-bridge \
      ros-humble-eigen3-cmake-module \
      ros-humble-image-transport \
      ros-humble-image-transport-plugins \
      ros-humble-message-filters \
      ros-humble-rclcpp-components \
      ros-humble-rcpputils \
      ros-humble-rosidl-default-generators \
      ros-humble-rosidl-default-runtime \
      ros-humble-tf2 \
      ros-humble-tf2-geometry-msgs \
      ros-humble-tf2-ros \
      ros-humble-vision-opencv \
 && rm -rf /var/lib/apt/lists/*

# OpenVINO 2025.3 (QYG's YOLO armor detector uses the IR model under
# armor_detector/model/IR/). Pinned to the version QYG's own Dockerfile uses.
# The simulator host here has an AMD CPU, so the launch defaults to device=CPU;
# OpenVINO's CPU plugin is x86 and works on AMD. Intel GPU would need the Intel
# driver stack and an Intel GPU.
RUN curl -fsSL https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
        -o /tmp/intel-gpg.pub \
 && gpg --dearmor < /tmp/intel-gpg.pub > /usr/share/keyrings/intel-openvino.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/intel-openvino.gpg] https://apt.repos.intel.com/openvino ubuntu22 main" \
        > /etc/apt/sources.list.d/intel-openvino.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends openvino-2025.3.0 \
 && rm -rf /var/lib/apt/lists/* /tmp/intel-gpg.pub

# QYG sources staged by build.sh: only the packages the closed loop needs.
COPY src/ /qyg_ws/src/
# Node parameter YAMLs (rm_bringup is not built; the launch loads these files).
COPY config/ /qyg_ws/config/

# rm_utils optionally compiles its Hik camera driver when the vendored SDK is
# present (it always is in the QYG checkout). The simulator never opens a Hik
# camera, but libarmor_detector.so/libarmor_solver.so end up with a DT_NEEDED
# on libMvCameraControl.so, so the runtime loader needs it on the library path.
RUN cp /qyg_ws/src/rm_utils/hikSDK/lib/amd64/*.so /usr/local/lib/ && ldconfig

WORKDIR /qyg_ws
RUN bash -c 'set -e; source /opt/ros/humble/setup.bash; \
    colcon build \
      --packages-select rm_interfaces rm_utils armor_detector armor_solver \
      --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF'

# Make the overlay available in login shells / scripts that source the profile.
RUN echo 'source /qyg_ws/install/setup.bash' >> /root/.bashrc \
 && echo 'source /qyg_ws/install/setup.bash' >> /etc/bash.bashrc

ENV QYG_WS=/qyg_ws

WORKDIR /sim
