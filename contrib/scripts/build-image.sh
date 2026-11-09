#!/usr/bin/env bash
# Shared local build wrapper; callers retain their Dockerfile/context choices.
set -euo pipefail
# shellcheck source=contrib/scripts/image-config.sh
source "$(dirname "$0")/image-config.sh"
centaur_image_config
service="$1"
shift
docker build -t "$(centaur_image_ref "$service")" "$@"
