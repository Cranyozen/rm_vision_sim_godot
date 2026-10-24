#!/usr/bin/env bash
# Build the rmvision-rclgd:humble image.
#
#   docker/build.sh                 # normal build (proxy http://localhost:7000)
#   PROXY= docker/build.sh          # no proxy
#   RCLGD_BUILD_CACHE=/tmp/x docker/build.sh
#   docker/build.sh --no-cache      # force a full rebuild
#
# Source checkouts and the Godot 4.7.2 engine archive are fetched on the HOST
# (through the proxy) into a cache, then staged into a docker build context.
# Only the apt layer of the docker build needs the network, and it uses the
# daemon's direct connection: the local proxy listens on the host loopback and
# is not reachable from the build network, so passing http_proxy as a build arg
# would make apt fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROXY="${PROXY-http://localhost:7000}"

# Pinned upstream revisions (checked out by fetch_pinned below).
RCLGD_REPO="${RCLGD_REPO:-https://github.com/Ozuba/rclgd.git}"
RCLGD_REF="${RCLGD_REF:-rolling}"
RCLGD_SHA="${RCLGD_SHA:-4d0a8b3ff98cc6b13d3c46725576644f5bc89440}"

RBF_REPO="${RBF_REPO:-https://github.com/LOEWE-emergenCITY/ros_babel_fish.git}"
RBF_REF="${RBF_REF:-humble}"
RBF_SHA="${RBF_SHA:-c76d4ef565cc0340e2c8193a6bad3fcdba591fb7}"

GODOT_CPP_REPO="${GODOT_CPP_REPO:-https://github.com/godotengine/godot-cpp.git}"
GODOT_CPP_REF="${GODOT_CPP_REF:-master}"
GODOT_CPP_SHA="${GODOT_CPP_SHA:-8070599885b6df675fcad033dd032ce44be2b850}"

GODOT_VERSION="${GODOT_VERSION:-4.7.2}"
GODOT_SLUG="linux.x86_64"
GODOT_ZIP="Godot_v${GODOT_VERSION}-stable_${GODOT_SLUG}.zip"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/${GODOT_ZIP}"
GODOT_SHA512="${GODOT_SHA512:-9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65}"

RM_INTERFACES_DIR="${RM_INTERFACES_DIR:-$REPO_ROOT/../QYG_QDVision2026/src/rm_interfaces}"

IMAGE="${IMAGE:-rmvision-rclgd:humble}"
CACHE="${RCLGD_BUILD_CACHE:-/tmp/rmvision-rclgd-cache}"
CTX="${RCLGD_BUILD_CTX:-/tmp/rmvision-rclgd-ctx}"
DOCKER_BUILD_ARGS=()
[ "${1:-}" = "--no-cache" ] && DOCKER_BUILD_ARGS+=(--no-cache)

export http_proxy="$PROXY" https_proxy="$PROXY"

log() { printf '\n=== %s\n' "$*"; }

fetch_pinned() {
    # fetch_pinned <name> <repo> <ref> <sha> <cache-dir>
    local name="$1" repo="$2" ref="$3" sha="$4" dir="$5"
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ]; then
        log "$name: cache hit ($sha)"
        return
    fi
    log "$name: fetching $repo @ $ref ($sha)"
    rm -rf "$dir"
    git clone --quiet --depth 1 --branch "$ref" "$repo" "$dir" 2>/dev/null \
        || { git init -q "$dir"; git -C "$dir" remote add origin "$repo"; }
    if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" != "$sha" ]; then
        git -C "$dir" fetch --quiet --depth 1 origin "$sha"
        git -C "$dir" checkout --quiet FETCH_HEAD
    fi
    local got
    got="$(git -C "$dir" rev-parse HEAD)"
    [ "$got" = "$sha" ] || { echo "$name: expected $sha, got $got" >&2; exit 1; }
}

fetch_godot() {
    local zip="$CACHE/$GODOT_ZIP"
    if [ -f "$zip" ] && echo "$GODOT_SHA512  $zip" | sha512sum -c --status -; then
        log "godot: cache hit ($zip)"
        return
    fi
    log "godot: downloading $GODOT_URL"
    mkdir -p "$CACHE"
    curl -fSL --retry 5 --retry-all-errors -o "$zip.part" "$GODOT_URL"
    mv "$zip.part" "$zip"
    echo "$GODOT_SHA512  $zip" | sha512sum -c -
}

mkdir -p "$CACHE" "$CTX"
fetch_pinned rclgd          "$RCLGD_REPO"     "$RCLGD_REF"     "$RCLGD_SHA"     "$CACHE/rclgd"
fetch_pinned ros_babel_fish "$RBF_REPO"       "$RBF_REF"       "$RBF_SHA"       "$CACHE/ros_babel_fish"
fetch_pinned godot-cpp      "$GODOT_CPP_REPO" "$GODOT_CPP_REF" "$GODOT_CPP_SHA" "$CACHE/godot-cpp"
fetch_godot

if [ ! -d "$RM_INTERFACES_DIR" ]; then
    echo "rm_interfaces not found at $RM_INTERFACES_DIR (set RM_INTERFACES_DIR=...)" >&2
    exit 2
fi

log "staging docker build context in $CTX"
rm -rf "$CTX"
mkdir -p "$CTX/src" "$CTX/godot" "$CTX/patches" "$CTX/test"
cp "$SCRIPT_DIR/Dockerfile" "$CTX/Dockerfile"
cp "$SCRIPT_DIR/entrypoint.sh" "$CTX/entrypoint.sh"
cp "$SCRIPT_DIR"/patches/*.patch "$CTX/patches/"
cp "$SCRIPT_DIR"/test/project.godot "$SCRIPT_DIR"/test/rclgd_smoke.gd \
   "$SCRIPT_DIR"/test/run_smoke.sh "$SCRIPT_DIR"/test/prepare_sim_project.sh "$CTX/test/"

rsync -a --exclude .git "$CACHE/rclgd/rclgd/" "$CTX/src/rclgd/"
mkdir -p "$CTX/src/rclgd_cli" "$CTX/src/colcon_rclgd"
rsync -a --exclude .git "$CACHE/rclgd/rclgd_cli/" "$CTX/src/rclgd_cli/"
rsync -a --exclude .git "$CACHE/rclgd/colcon_rclgd/" "$CTX/src/colcon_rclgd/"
rsync -a --exclude .git "$CACHE/ros_babel_fish/ros_babel_fish/" "$CTX/src/ros_babel_fish/"
rsync -a --exclude .git "$CACHE/godot-cpp/" "$CTX/src/godot-cpp/"
rsync -a --exclude .git "$RM_INTERFACES_DIR/" "$CTX/src/rm_interfaces/"
cp "$CACHE/$GODOT_ZIP" "$CTX/godot/"

log "docker build -t $IMAGE"
docker build "${DOCKER_BUILD_ARGS[@]}" \
    --build-arg GODOT_VERSION="$GODOT_VERSION" \
    --build-arg GODOT_SLUG="$GODOT_SLUG" \
    -t "$IMAGE" "$CTX"

log "done: $IMAGE"
echo "verify with: $SCRIPT_DIR/run.sh verify"
