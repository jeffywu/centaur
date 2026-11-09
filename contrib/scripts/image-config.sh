#!/usr/bin/env bash
# Shared image naming for build, push, deployment, and published-image E2E.
# Source this file; no Docker/Kubernetes operations happen while sourcing it.
centaur_image_config() {
  CENTAUR_REGISTRY="${CENTAUR_REGISTRY:-ghcr.io}"
  CENTAUR_IMAGE_NAMESPACE="${CENTAUR_IMAGE_NAMESPACE:-paradigmxyz/centaur}"
  CENTAUR_IMAGE_TAG="${CENTAUR_IMAGE_TAG:-latest}"
  CENTAUR_REGISTRY="$(printf '%s' "$CENTAUR_REGISTRY" | tr '[:upper:]' '[:lower:]')"
  CENTAUR_IMAGE_NAMESPACE="$(printf '%s' "$CENTAUR_IMAGE_NAMESPACE" | tr '[:upper:]' '[:lower:]')"
  if [[ ! "$CENTAUR_REGISTRY" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?$ ]] ||
     [[ ! "$CENTAUR_IMAGE_NAMESPACE" =~ ^[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)*$ ]] ||
     [[ ! "$CENTAUR_IMAGE_TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
    echo 'Invalid registry host, image namespace, or image tag' >&2
    return 2
  fi
}

# service:Helm-key pairs. workflow-python is embedded in api-rs and agent.
centaur_images() {
  printf '%s\n' api-rs:apiRs company-context:experimentalCompanyContext \
    proxy-sync:proxySync token-broker:tokenBroker iron-proxy:ironProxy \
    slackbotv2:slackbotv2 linearbot:linearbot discordbot:discordbot \
    githubbot:githubbot teamsbot:teamsbot agent:sandbox console:console
}

centaur_image_ref() {
  local service="$1"
  if [[ "$service" == agent && -n "${CENTAUR_AGENT_IMAGE:-}" ]]; then
    printf '%s\n' "$CENTAUR_AGENT_IMAGE"
  elif [[ "${CENTAUR_IMAGE_SOURCE:-local}" == registry ]]; then
    printf '%s/%s/centaur-%s:%s\n' "$CENTAUR_REGISTRY" "$CENTAUR_IMAGE_NAMESPACE" "$service" "$CENTAUR_IMAGE_TAG"
  else
    printf 'centaur-%s:latest\n' "$service"
  fi
}

# One argument per line for safe Bash array construction (no eval).
centaur_image_values() {
  local entry service key
  while IFS= read -r entry; do
    service="${entry%%:*}" key="${entry#*:}"
    printf '%s\n' --set-string "${key}.image.repository=${CENTAUR_REGISTRY}/${CENTAUR_IMAGE_NAMESPACE}/centaur-${service}"
    if [[ "${CENTAUR_IMAGE_SOURCE:-local}" == registry ]]; then
      printf '%s\n' --set-string "${key}.image.tag=${CENTAUR_IMAGE_TAG}"
    fi
  done < <(centaur_images)
}
