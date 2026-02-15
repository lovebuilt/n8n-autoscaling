#!/bin/bash
# custom/build.sh — Wrapper for build.py
# Generates Dockerfile.build, Dockerfile.runner.build, n8n-task-runners.build.json
# from upstream Dockerfiles + your custom/config.json additions.
#
# Usage: ./custom/build.sh
# Called automatically by: upstream-sync.sh, update.sh, quick-update.sh

set -e
cd "$(dirname "$0")/.."

python3 custom/build.py
