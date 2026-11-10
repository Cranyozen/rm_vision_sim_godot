#!/usr/bin/env python3
"""Push the QYG vision mode into the detector and solver nodes.

The real robot's serial driver does this from the MCU mode byte; the simulator
publishes /serial/receive itself and never runs that driver, so Phase 4 sets the
mode once through the nodes' /set_mode services.

  python3 set_vision_mode.py --mode 0     # auto-aim red
  python3 set_vision_mode.py --mode 1     # auto-aim blue

Exits non-zero if the services do not appear or reject the request.
"""

import argparse
import sys
import time

import rclpy
from rclpy.node import Node

from rm_interfaces.srv import SetMode


SERVICES = ("/armor_detector/set_mode", "/armor_solver/set_mode")


class ModeSetter(Node):
    def __init__(self):
        super().__init__("phase4_set_vision_mode")
        self.mode_clients = {
            name: self.create_client(SetMode, name) for name in SERVICES
        }


def call(node, name, mode, timeout):
    client = node.mode_clients[name]
    deadline = time.monotonic() + timeout
    while not client.wait_for_service(timeout_sec=0.5):
        if time.monotonic() > deadline:
            node.get_logger().error(f"{name} not available after {timeout:.0f}s")
            return False

    request = SetMode.Request()
    request.mode = mode
    future = client.call_async(request)
    rclpy.spin_until_future_complete(node, future, timeout_sec=timeout)
    if not future.done() or future.result() is None:
        node.get_logger().error(f"{name} call failed: {future.exception()}")
        return False
    result = future.result()
    node.get_logger().info(
        f"{name} -> mode {mode}: success={result.success} message='{result.message}'"
    )
    return bool(result.success)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", type=int, default=0, choices=(0, 1),
                        help="0 = auto-aim red, 1 = auto-aim blue")
    parser.add_argument("--timeout", type=float, default=40.0)
    args = parser.parse_args()

    rclpy.init()
    node = ModeSetter()
    try:
        results = [call(node, name, args.mode, args.timeout) for name in SERVICES]
    finally:
        node.destroy_node()
        rclpy.shutdown()

    if not all(results):
        sys.exit(1)
    print(f"PHASE4_MODE: set vision mode {args.mode}")


if __name__ == "__main__":
    main()
