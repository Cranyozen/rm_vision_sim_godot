# syntax=docker/dockerfile:1
#
# rmvision-rclgd:humble — rclgd (ROS 2 GDExtension for Godot) built against
# ROS 2 Humble, for the rm_vision_sim_godot simulator.
#
# Build it through docker/build.sh (it stages the pinned sources, the Godot
# 4.7.2 archive and the proxy settings), not with a bare `docker build .`.
#
# What this image contains:
#   /ros_ws                     colcon workspace (source + install overlay)
#     install/rclgd/lib/rclgd/librclgd.so        rclgd GDExtension library
#     install/rclgd/lib/rclgd/godot-bin          Godot 4.7.2 engine (hash verified)
#     install/rm_interfaces/...                  rm_interfaces custom messages
#     install/ros_babel_fish/...                 runtime message handler
#   /usr/local/bin/godot        symlink to the bundled Godot 4.7.2 binary
#   /opt/rclgd-test             headless smoke test project + runner
#
# The three patches under /opt/patches are the only source changes; see
# docker/README.md for what each one does.

FROM ros:humble-ros-base

# Only used to derive the staged engine archive name; the apt layer uses the
# build daemon's direct network (the host-side proxy is not reachable from the
# build network).
ARG GODOT_VERSION=4.7.2
ARG GODOT_SLUG=linux.x86_64

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    ROS_DISTRO=humble

# Build deps: compilers/CMake for rclgd + godot-cpp, patch for the rclgd
# patches, and the Humble packages rclgd/ros_babel_fish link against.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        patch \
        python3-colcon-common-extensions \
        ros-humble-ament-index-cpp \
        ros-humble-rcpputils \
        ros-humble-rosidl-runtime-cpp \
        ros-humble-rosidl-typesupport-cpp \
        ros-humble-rosidl-typesupport-introspection-cpp \
        ros-humble-rclcpp-action \
        ros-humble-tf2-ros \
        ros-humble-tf2-msgs \
        ros-humble-rosgraph-msgs \
        ros-humble-geometry-msgs \
        ros-humble-std-msgs \
        ros-humble-sensor-msgs \
        libgl1 \
        libegl1 \
        libglx-mesa0 \
        libgl1-mesa-dri \
        mesa-vulkan-drivers \
        libvulkan1 \
        libx11-6 \
        libxext6 \
        libxrandr2 \
        libxcursor1 \
        libxi6 \
        libxinerama1 \
        libxrender1 \
        libxfixes3 \
        libxkbcommon0 \
        libwayland-client0 \
        libwayland-cursor0 \
        libwayland-egl1 \
        libdbus-1-3 \
        libfontconfig1 \
        libfreetype6 \
        libasound2 \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Pinned sources (staged by docker/build.sh)
#   rclgd           rolling @ 4d0a8b3 (3.0.0, targets Godot 4.7)
#   ros_babel_fish  humble  @ c76d4ef (1.x API, the branch that supports Humble)
#   godot-cpp       master  @ 8070599 (API JSON for 4.6..4.8, we build 4.7)
#   rm_interfaces   copy of QYG_QDVision2026/src/rm_interfaces
# ---------------------------------------------------------------------------
COPY src/ /opt/rclgd-src/
COPY patches/ /opt/patches/
COPY godot/ /opt/godot-archive/

# Retarget rclgd to Godot 4.7.2, teach it godot-cpp's versioned API JSON,
# adapt it to ros_babel_fish 1.x and Humble's rclcpp (see patches/).
RUN cd /opt/rclgd-src \
    && for p in /opt/patches/*.patch; do \
           echo "applying $(basename "$p")"; \
           patch -p1 --batch --forward -i "$p"; \
       done

# Assemble the colcon workspace. rclgd expects its godot-cpp checkout at
# rclgd/godot-cpp (normally a git submodule).
RUN mkdir -p /ros_ws/src \
    && cp -a /opt/rclgd-src/ros_babel_fish /ros_ws/src/ros_babel_fish \
    && cp -a /opt/rclgd-src/rm_interfaces /ros_ws/src/rm_interfaces \
    && cp -a /opt/rclgd-src/rclgd_cli /ros_ws/src/rclgd_cli \
    && cp -a /opt/rclgd-src/colcon_rclgd /ros_ws/src/colcon_rclgd \
    && cp -a /opt/rclgd-src/rclgd /ros_ws/src/rclgd \
    && rm -rf /ros_ws/src/rclgd/godot-cpp \
    && cp -a /opt/rclgd-src/godot-cpp /ros_ws/src/rclgd/godot-cpp

# rm_interfaces and ros_babel_fish first (rclgd links ros_babel_fish).
# GODOTCPP_API_VERSION=4.7 selects godot-cpp's extension_api-4-7.json.
# RCLGD_GODOT_ARCHIVE makes the engine download step use the staged archive
# (SHA512 is still verified by rclgd's CMakeLists).
RUN source /opt/ros/humble/setup.bash \
    && export RCLGD_GODOT_ARCHIVE="/opt/godot-archive/Godot_v${GODOT_VERSION}-stable_${GODOT_SLUG}.zip" \
    && cd /ros_ws \
    && colcon build \
         --packages-select ros_babel_fish rm_interfaces rclgd rclgd_cli colcon_rclgd \
         --cmake-args -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release \
                      -DGODOTCPP_API_VERSION=4.7 \
    && echo "build ok"

RUN ls -l /ros_ws/install/rclgd/lib/rclgd/

# Ship the smoke-test project and a runner that wires the extension in.
COPY test/ /opt/rclgd-test/

ENV RCLGD_OVERLAY=/ros_ws/install/setup.bash
RUN ln -sf /ros_ws/install/rclgd/lib/rclgd/godot-bin /usr/local/bin/godot \
    && chmod +x /opt/rclgd-test/run_smoke.sh /opt/rclgd-test/prepare_sim_project.sh \
    && install -m 0755 /opt/rclgd-test/prepare_sim_project.sh /opt/prepare_sim_project.sh

# Foxglove Studio debug bridge (WebSocket server, default ws://localhost:8765).
# Own layer on purpose: adding/removing the bridge must not invalidate the
# expensive rclgd + godot-cpp build above.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ros-humble-foxglove-bridge \
    && rm -rf /var/lib/apt/lists/*

# Drop the colcon build tree (500+ MB) and the copied godot-cpp sources; the
# installed overlay keeps everything needed at run time.
RUN rm -rf /ros_ws/build /ros_ws/log /ros_ws/src/rclgd/godot-cpp \
       /opt/rclgd-src/godot-cpp /opt/godot-archive

COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

WORKDIR /sim
ENTRYPOINT ["/opt/entrypoint.sh"]
CMD ["bash"]
