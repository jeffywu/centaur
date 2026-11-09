#!/usr/bin/env bash
set -euo pipefail
source contrib/scripts/image-config.sh
centaur_image_config
if [[ -n "${CENTAUR_BUILD_PLATFORMS:-}" ]]; then
  if ! jq -e 'type == "array" and length > 0 and (unique | length) == length and all(.[]; . == "linux/amd64" or . == "linux/arm64")' <<< "$CENTAUR_BUILD_PLATFORMS" >/dev/null; then
    echo 'Build platforms must be a nonempty JSON array of unique linux/amd64 or linux/arm64 entries' >&2
    exit 2
  fi
fi
case "$BUILD_BACKEND" in depot|buildx) ;; *) echo 'Unknown build backend' >&2; exit 2 ;; esac
case "$RUST_BUILD_PROFILE" in debug|release) ;; *) echo 'Unknown Rust build profile' >&2; exit 2 ;; esac
{
  echo "REGISTRY=$CENTAUR_REGISTRY"
  echo "IMAGE_NAMESPACE=$CENTAUR_IMAGE_NAMESPACE"
} >> "$GITHUB_ENV"
