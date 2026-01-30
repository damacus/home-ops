#!/usr/bin/env bash
set -euo pipefail

# flux-local-container.sh - Run flux-local in a container
# This script wraps flux-local execution in a Docker container to ensure
# consistent behavior between local development and CI/CD pipelines.
# Uses the official pre-built image from ghcr.io/allenporter/flux-local

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Run flux-local with all arguments passed through
docker compose -f "${REPO_ROOT}/docker-compose.flux-local.yml" run --rm flux-local "$@"
