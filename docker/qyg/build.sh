#!/usr/bin/env bash
# Build the Phase 4 QYG image: rmvision-qyg:humble.
#
#   docker/qyg/build.sh              # incremental (uses the docker layer cache)
#   docker/qyg/build.sh --no-cache   # force a full rebuild
#   QYG_DIR=/path/to/QYG_QDVision2026 docker/qyg/build.sh
#
# Only rm_interfaces / rm_utils / armor_detector / armor_solver sources and the
# node parameter YAMLs are staged into the build context, so the QYG checkout
# stays the source of truth without copying its whole tree into the image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QYG_DIR="${QYG_DIR:-$REPO_ROOT/../QYG_QDVision2026}"
IMAGE="${QYG_IMAGE:-rmvision-qyg:humble}"
CTX="${QYG_BUILD_CTX:-/tmp/rmvision-qyg-ctx}"

DOCKER_BUILD_ARGS=()
[ "${1:-}" = "--no-cache" ] && DOCKER_BUILD_ARGS+=(--no-cache)

if [ ! -d "$QYG_DIR/src/rm_auto_aim" ]; then
    echo "QYG checkout not found at $QYG_DIR (set QYG_DIR=...)" >&2
    exit 2
fi

log() { printf '\n=== %s\n' "$*"; }

log "staging build context in $CTX"
rm -rf "$CTX"
mkdir -p "$CTX/src" "$CTX/config"
cp "$SCRIPT_DIR/Dockerfile" "$CTX/Dockerfile"

# Package set required for the closed loop.
cp -a "$QYG_DIR/src/rm_interfaces" "$CTX/src/"
cp -a "$QYG_DIR/src/rm_utils" "$CTX/src/"
mkdir -p "$CTX/src/rm_auto_aim"
cp -a "$QYG_DIR/src/rm_auto_aim/armor_detector" "$CTX/src/rm_auto_aim/"
cp -a "$QYG_DIR/src/rm_auto_aim/armor_solver" "$CTX/src/rm_auto_aim/"
rm -rf "$CTX/src"/*/build "$CTX/src"/*/install "$CTX/src"/*/log 2>/dev/null || true

# Node parameter YAMLs used by docker/qyg/phase4_qyg.launch.py.
cp -a "$QYG_DIR/src/rm_bringup/config/node_params/." "$CTX/config/"

log "docker build -t $IMAGE ($QYG_DIR)"
docker build "${DOCKER_BUILD_ARGS[@]}" -t "$IMAGE" "$CTX"

log "done: $IMAGE"
echo "run the simulator (term 1): docker/run.sh sim"
echo "run the QYG stack    (term 2): docker/run.sh qyg"
