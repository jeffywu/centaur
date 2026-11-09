#!/usr/bin/env bash
# Disposable public-registry smoke test; never uses the ambient kubeconfig.
# Requires Docker/Buildx, kind, kubectl, jq, and curl.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
cluster="centaur-registry-${RANDOM}"
registry_container="${cluster}-registry"
cluster_created=0
registry_created=0
builder_created=0
cleanup() {
  if [[ "$builder_created" == 1 ]]; then docker buildx rm "$cluster" >/dev/null; fi
  if [[ "$cluster_created" == 1 ]]; then kind delete cluster --name "$cluster" >/dev/null; fi
  if [[ "$registry_created" == 1 ]]; then docker rm -f "$registry_container" >/dev/null; fi
  rm -rf "$work"
}
trap cleanup EXIT
buildx_plugin="$(docker info --format '{{range .ClientInfo.Plugins}}{{if eq .Name "buildx"}}{{.Path}}{{end}}{{end}}')"
export KUBECONFIG="$work/kubeconfig" DOCKER_CONFIG="$work/docker"
mkdir -p "$DOCKER_CONFIG" "$work/image"
jq -n --arg directory "$(dirname "$buildx_plugin")" '{cliPluginsExtraDirs: [$directory]}' > "$DOCKER_CONFIG/config.json"
docker run -d --name "$registry_container" -p "127.0.0.1:${CENTAUR_REGISTRY_SMOKE_PORT:-5051}:5000" \
  registry:2 >/dev/null
registry_created=1
port="$(docker port "$registry_container" 5000/tcp | cut -d: -f2)"
export CENTAUR_REGISTRY="localhost:${port}" CENTAUR_IMAGE_NAMESPACE=example/nested CENTAUR_IMAGE_TAG=smoke
for _ in {1..30}; do
  if curl -s -o /dev/null "http://${CENTAUR_REGISTRY}/v2/"; then break; fi
  sleep 1
done
printf 'FROM busybox:1.37\n' > "$work/image/Dockerfile"
image="${CENTAUR_REGISTRY}/${CENTAUR_IMAGE_NAMESPACE}/centaur-agent:${CENTAUR_IMAGE_TAG}"
cat > "$work/buildkitd.toml" <<BUILDKIT
[registry."${CENTAUR_REGISTRY}"]
  http = true
BUILDKIT
docker buildx create --name "$cluster" --driver docker-container --driver-opt network=host \
  --buildkitd-config "$work/buildkitd.toml" --use >/dev/null
builder_created=1
mkdir -p "$work/digests"
repository="${image%:*}"
for platform in linux/amd64 linux/arm64; do
  docker buildx build --platform "$platform" \
    --output "type=image,name=${repository},push-by-digest=true,name-canonical=true,push=true" \
    --metadata-file "$work/metadata.json" "$work/image"
  digest="$(jq -er '."containerimage.digest"' "$work/metadata.json")"
  touch "$work/digests/${digest#sha256:}"
done
merge_script="$PWD/.github/scripts/merge-images.sh"
(
  cd "$work/digests"
  REGISTRY="$CENTAUR_REGISTRY" IMAGE_NAMESPACE="$CENTAUR_IMAGE_NAMESPACE" IMAGE=centaur-agent \
    DOCKER_METADATA_OUTPUT_JSON="$(jq -cn --arg tag "$image" '{tags: [$tag]}')" \
    bash "$merge_script"
)
docker buildx imagetools inspect --raw "$image" > "$work/manifest.json"
jq -e '[.manifests[].platform | select(.os == "linux") | .architecture] | index("amd64") != null and index("arm64") != null' "$work/manifest.json" >/dev/null

cat > "$work/kind.yaml" <<'KIND'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
KIND
kind create cluster --name "$cluster" --image kindest/node:v1.34.0 --config "$work/kind.yaml" --kubeconfig "$KUBECONFIG" --wait 120s
cluster_created=1
kubectl config current-context
kubectl config view --minify -o 'jsonpath={.contexts[0].context.namespace}'
docker network connect kind "$registry_container"
# The nodes resolve the host-side image reference through the test registry's
# Docker network endpoint. HTTP is restricted to this disposable local fixture.
mkdir -p "$work/hosts"
cat > "$work/hosts/hosts.toml" <<HOSTS
[host."http://${registry_container}:5000"]
  capabilities = ["pull", "resolve"]
HOSTS
docker exec "${cluster}-control-plane" mkdir -p "/etc/containerd/certs.d/${CENTAUR_REGISTRY}"
docker cp "$work/hosts/hosts.toml" "${cluster}-control-plane:/etc/containerd/certs.d/${CENTAUR_REGISTRY}/hosts.toml"

# Match the anonymous published-agent pre-pull used by e2e/stack.sh.
docker exec "${cluster}-control-plane" crictl pull "$image"
kubectl create namespace centaur-registry-test >/dev/null
kubectl -n centaur-registry-test run public-image-check --restart=Never \
  --image="$image" --image-pull-policy=Always --command -- /bin/sh -c 'exit 0'
kubectl -n centaur-registry-test wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/public-image-check --timeout=120s
printf 'Public multi-platform publishing, manifest assembly, agent pre-pull, and anonymous Pod pull passed.\n'
