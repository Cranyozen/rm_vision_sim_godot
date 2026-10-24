#!/usr/bin/env python3
"""Measure the simulator's Phase 2 topic rates and camera_info in one process.

`ros2 topic hz` starts a separate Python subscriber per topic; on a loaded
machine the best-effort image stream can look far slower than it is. This probe
subscribes once to every topic, warms up, then counts for a fixed window.

Usage (inside the ROS 2 Humble container, simulator running):
    source /opt/ros/humble/setup.bash && source /ros_ws/install/setup.bash
    python3 tests/phase2_rate_probe.py
Prints:
    RATES raw=30.0 jpg=60.0 info=10.0 serial=50.0 tf=160.0
    K 3383.96 3383.96 605.0 536.5
Exits 0 on success (rates are checked by phase2_ros_cli.sh).
"""

import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from sensor_msgs.msg import CameraInfo, CompressedImage, Image
from tf2_msgs.msg import TFMessage

try:
    from rm_interfaces.msg import SerialReceiveData
except ImportError:
    SerialReceiveData = None


def qos(depth: int) -> QoSProfile:
    return QoSProfile(depth=depth,
                      history=HistoryPolicy.KEEP_LAST,
                      reliability=ReliabilityPolicy.BEST_EFFORT)


class RateProbe(Node):
    def __init__(self) -> None:
        super().__init__('phase2_rate_probe')
        self.counts = {'raw': 0, 'jpg': 0, 'info': 0, 'serial': 0, 'tf': 0}
        self.tf_counts = {'map_odom': 0, 'gimbal': 0}
        self.tf_stamps = {'map_odom': [], 'gimbal': []}
        self.k = None
        self.create_subscription(Image, '/image_raw', self._raw, qos(5))
        self.create_subscription(CompressedImage, '/image_raw/compressed', self._jpg, qos(5))
        self.create_subscription(CameraInfo, '/camera_info', self._info, qos(5))
        self.create_subscription(TFMessage, '/tf', self._tf, qos(100))
        if SerialReceiveData is not None:
            self.create_subscription(SerialReceiveData, '/serial/receive', self._serial, qos(5))

    def _raw(self, _msg):
        self.counts['raw'] += 1

    def _jpg(self, _msg):
        self.counts['jpg'] += 1

    def _info(self, msg):
        self.counts['info'] += 1
        self.k = list(msg.k)

    def _serial(self, _msg):
        self.counts['serial'] += 1

    def _tf(self, msg):
        self.counts['tf'] += 1
        for tr in msg.transforms:
            key = (tr.header.frame_id, tr.child_frame_id)
            name = None
            if key == ('map', 'odom'):
                name = 'map_odom'
            elif key == ('odom', 'gimbal_link'):
                name = 'gimbal'
            if name is not None:
                self.tf_counts[name] += 1
                self.tf_stamps[name].append(
                    tr.header.stamp.sec + tr.header.stamp.nanosec * 1e-9)


def main() -> int:
    rclpy.init()
    node = RateProbe()
    try:
        # Discovery + publisher matching, then discard the warm-up samples.
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.05)
        node.counts = {key: 0 for key in node.counts}
        node.tf_counts = {key: 0 for key in node.tf_counts}
        node.tf_stamps = {key: [] for key in node.tf_stamps}

        window = 3.0
        deadline = time.monotonic() + window
        while time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.05)
        elapsed = window
    finally:
        node.destroy_node()
        rclpy.shutdown()

    rates = {key: node.counts[key] / elapsed for key in node.counts}
    print('RATES ' + ' '.join('%s=%.1f' % (key, rates[key]) for key in
                              ('raw', 'jpg', 'info', 'serial', 'tf')))
    tf_rates = {key: node.tf_counts[key] / elapsed for key in node.tf_counts}
    mono = {key: int(all(b > a for a, b in zip(stamps, stamps[1:])))
            for key, stamps in node.tf_stamps.items()}
    print('TFRATES map_odom=%.1f gimbal=%.1f mono_map_odom=%d mono_gimbal=%d' % (
        tf_rates['map_odom'], tf_rates['gimbal'],
        mono['map_odom'], mono['gimbal']))
    if node.k and len(node.k) == 9:
        print('K %.6f %.6f %.6f %.6f' % (node.k[0], node.k[4], node.k[2], node.k[5]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
