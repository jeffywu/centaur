#!/usr/bin/env bash
# Run in the downloaded digests directory, using docker/metadata-action's JSON.
set -euo pipefail
args=()
while IFS= read -r tag; do args+=(-t "$tag"); done < <(jq -er '.tags[]' <<< "$DOCKER_METADATA_OUTPUT_JSON")
if [[ ${#args[@]} == 0 ]]; then echo 'No image tags supplied' >&2; exit 2; fi
for digest in *; do
  if [[ ! -f "$digest" || ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'Expected sha256 digest artifact filenames' >&2
    exit 2
  fi
  args+=("${REGISTRY}/${IMAGE_NAMESPACE}/${IMAGE}@sha256:${digest}")
done
docker buildx imagetools create "${args[@]}"
