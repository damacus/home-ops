#!/usr/bin/env bash
set -euo pipefail

# flux-local-container.sh - Run flux-local in a container
# This script wraps flux-local execution in a Docker container to ensure
# consistent behavior between local development and CI/CD pipelines.
# Uses the official pre-built image from ghcr.io/allenporter/flux-local

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE="ghcr.io/allenporter/flux-local:v8.2.0"

docker_args=(
  --rm
  -e PYTHONUNBUFFERED=1
  -e HOME=/tmp
  -e XDG_CACHE_HOME=/tmp/.cache
  -e XDG_CONFIG_HOME=/tmp/.config
  -v "${REPO_ROOT}:/workspace"
  -w /workspace
)

git_dir="$(git -C "${REPO_ROOT}" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
git_common_dir="$(git -C "${REPO_ROOT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"

if [[ -n "${git_common_dir}" && "${git_common_dir}" != "${REPO_ROOT}/.git" ]]; then
  docker_args+=(-v "${git_common_dir}:${git_common_dir}:ro")
fi

if [[ -n "${git_dir}" && "${git_dir}" != "${REPO_ROOT}/.git" && "${git_dir}" != "${git_common_dir}" ]]; then
  docker_args+=(-v "${git_dir}:${git_dir}:ro")
fi

# Run flux-local with all arguments passed through
docker run "${docker_args[@]}" "${IMAGE}" "$@"
