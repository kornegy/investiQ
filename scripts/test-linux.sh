#!/usr/bin/env bash
# Runs the InvestiQKit package build/tests inside the Linux Docker image (Swift 6.2).
# Usage: scripts/test-linux.sh [build|test] [extra swift arguments...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${INVESTIQ_LINUX_IMAGE:-investiq-linux:6.2}"
COMMAND="${1:-test}"; shift || true

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -t "$IMAGE" -f "$ROOT/ci/Dockerfile.linux" "$ROOT/ci"
fi

docker run --rm --network host \
  -e HTTPS_PROXY -e https_proxy -e NO_PROXY -e no_proxy \
  -v "$ROOT/InvestiQKit:/work" -w /work "$IMAGE" \
  swift "$COMMAND" --build-path /work/.build-linux "$@"
