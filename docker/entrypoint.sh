#!/usr/bin/env bash
# Container entrypoint: make ROS Humble + the rclgd overlay available, then
# hand off to the requested command.
set -e

# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
if [ -f /ros_ws/install/setup.bash ]; then
    # shellcheck disable=SC1091
    source /ros_ws/install/setup.bash
fi

# A fixed domain keeps the simulator off any other ROS 2 graph on the host;
# --network host means DDS discovery would otherwise reach the host.
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"

exec "$@"
