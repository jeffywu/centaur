set dotenv-load := true

namespace := env_var_or_default("CENTAUR_NAMESPACE", "centaur")
release := env_var_or_default("CENTAUR_RELEASE", "centaur")
source := env_var_or_default("CENTAUR_IMAGE_SOURCE", "local")
export CENTAUR_IMAGE_SOURCE := source
chart := "contrib/chart"
dev_values := "contrib/chart/values.dev.yaml"
# Command used to import images into k3s's containerd. Override for rootless or
# remote setups, e.g. CENTAUR_K3S_CTR="k3s ctr" or "ssh host sudo k3s ctr".
k3s_ctr := env_var_or_default("CENTAUR_K3S_CTR", "sudo k3s ctr")
# Local image registry `just up k3s` pushes to. Images are pushed under the
# `library/` namespace so k3s resolves the chart's bare `:latest` tags through a
# docker.io registry mirror — configure that on the node with:
#   /etc/rancher/k3s/registries.yaml
#     mirrors:
#       docker.io:
#         endpoint: ["http://localhost:5000"]
registry := env_var_or_default("CENTAUR_LOCAL_REGISTRY", "localhost:5000")
agent_dockerfile := env_var_or_default("CENTAUR_AGENT_DOCKERFILE", "services/sandbox/Dockerfile")
agent_build_target := env_var_or_default("CENTAUR_AGENT_BUILD_TARGET", "sandbox")
# An empty exported override keeps registry-derived naming and must also retain
# the local default when a recipe invokes another just process.
agent_image := if env_var_or_default("CENTAUR_AGENT_IMAGE", "") == "" { "centaur-agent:latest" } else { env_var("CENTAUR_AGENT_IMAGE") }
export CENTAUR_AGENT_IMAGE := if agent_image == "centaur-agent:latest" { env_var_or_default("CENTAUR_AGENT_IMAGE", "") } else { agent_image }

default:
    just --list

build:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "${JUST_BUILD_SEQUENTIAL:-0}" =~ ^(1|true|yes)$ ]]; then
      just _build-all-sequential
    else
      pids=()
      for recipe in _build-api-rs _build-company-context _build-proxy-sync _build-token-broker _build-iron-proxy _build-slackbotv2 _build-linearbot _build-discordbot _build-githubbot _build-teamsbot _build-agent _build-console; do
        just "$recipe" &
        pids+=("$!")
      done
      status=0
      for pid in "${pids[@]}"; do
        wait "$pid" || status=1
      done
      exit "$status"
    fi

_build-all-sequential:
    just _build-api-rs
    just _build-company-context
    just _build-proxy-sync
    just _build-token-broker
    just _build-iron-proxy
    just _build-slackbotv2
    just _build-linearbot
    just _build-discordbot
    just _build-githubbot
    just _build-teamsbot
    just _build-agent
    just _build-console

build-one service:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{service}}" in
      api-rs) just _build-api-rs ;;
      company-context) just _build-company-context ;;
      proxy-sync) just _build-proxy-sync ;;
      token-broker) just _build-token-broker ;;
      iron-proxy) just _build-iron-proxy ;;
      slackbotv2) just _build-slackbotv2 ;;
      linearbot) just _build-linearbot ;;
      discordbot) just _build-discordbot ;;
      githubbot) just _build-githubbot ;;
      teamsbot) just _build-teamsbot ;;
      agent|sandbox) just _build-agent ;;
      workflow-python) just _build-workflow-python ;;
      console) just _build-console ;;
      *) echo "unknown service: {{service}}" >&2; exit 2 ;;
    esac

_build-api-rs:
    bash contrib/scripts/build-image.sh api-rs -f services/api-rs/Dockerfile .

_build-company-context:
    bash contrib/scripts/build-image.sh company-context -f services/company-context/Dockerfile .

_build-proxy-sync:
    bash contrib/scripts/build-image.sh proxy-sync -f services/proxy-sync/Dockerfile .

_build-token-broker:
    bash contrib/scripts/build-image.sh token-broker -f services/token-broker/Dockerfile .

_build-iron-proxy:
    bash contrib/scripts/build-image.sh iron-proxy -f services/iron-proxy/Dockerfile .

_build-slackbotv2:
    bash contrib/scripts/build-image.sh slackbotv2 -f services/slackbotv2/Dockerfile .

_build-linearbot:
    bash contrib/scripts/build-image.sh linearbot -f services/linearbot/Dockerfile .

_build-discordbot:
    bash contrib/scripts/build-image.sh discordbot -f services/discordbot/Dockerfile .

_build-githubbot:
    bash contrib/scripts/build-image.sh githubbot -f services/githubbot/Dockerfile .

_build-teamsbot:
    bash contrib/scripts/build-image.sh teamsbot -f services/teamsbot/Dockerfile .

_build-agent:
    bash contrib/scripts/build-image.sh agent --target "{{agent_build_target}}" -f "{{agent_dockerfile}}" .

# The Python workflow host is embedded in both consumer images.
_build-workflow-python:
    just _build-api-rs
    just _build-agent

# The console builds from its own subdirectory context (services/console), unlike
# the other services which build from the repo root.
_build-console:
    bash contrib/scripts/build-image.sh console -f services/console/Dockerfile services/console

# Push locally-built images to the local registry under library/ so k3s pulls
# them via its docker.io mirror. Used by `just up k3s`. Only changed layers are
# pushed, so this is much faster than `_import-k3s` on repeat runs.
_push-registry:
    #!/usr/bin/env bash
    set -euo pipefail
    for img in centaur-api-rs centaur-company-context centaur-proxy-sync centaur-token-broker centaur-iron-proxy centaur-slackbotv2 centaur-linearbot centaur-discordbot centaur-githubbot centaur-teamsbot centaur-agent centaur-console; do
      target="{{registry}}/library/${img}:latest"
      echo "pushing ${img}:latest -> ${target}..."
      image="${img}:latest"
      if [[ "$img" == centaur-agent ]]; then image="{{agent_image}}"; fi
      docker tag "$image" "${target}"
      docker push "${target}"
    done

# Legacy: import locally-built images straight into k3s's containerd (no registry
# needed). Slower than `_push-registry`; kept as a fallback. Run manually with
# `just _import-k3s`.
_import-k3s:
    #!/usr/bin/env bash
    set -euo pipefail
    for img in centaur-api-rs centaur-company-context centaur-proxy-sync centaur-token-broker centaur-iron-proxy centaur-slackbotv2 centaur-linearbot centaur-discordbot centaur-githubbot centaur-teamsbot centaur-agent centaur-console; do
      echo "importing ${img}:latest into k3s containerd..."
      image="${img}:latest"
      if [[ "$img" == centaur-agent ]]; then image="{{agent_image}}"; fi
      docker save "$image" | {{k3s_ctr}} images import -
    done

# Publish images built with CENTAUR_IMAGE_SOURCE=registry. Authenticate with docker login first.
push:
    #!/usr/bin/env bash
    set -euo pipefail
    source contrib/scripts/image-config.sh
    centaur_image_config
    export CENTAUR_IMAGE_SOURCE=registry
    while IFS= read -r entry; do
      service="${entry%%:*}"
      image="$(centaur_image_ref "$service")"
      target="${CENTAUR_REGISTRY}/${CENTAUR_IMAGE_NAMESPACE}/centaur-${service}:${CENTAUR_IMAGE_TAG}"
      if [[ "$image" != "$target" ]]; then docker tag "$image" "$target"; fi
      docker push "$target"
    done < <(centaur_images)

bootstrap-secrets *args:
    contrib/scripts/bootstrap-k8s-secrets.sh --namespace {{namespace}} {{args}}

deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    helm dependency update {{chart}} >/dev/null
    extra_args=()
    case "{{source}}" in
      local) ;;
      ghcr|registry)
        source contrib/scripts/image-config.sh
        centaur_image_config
        export CENTAUR_IMAGE_SOURCE="{{source}}"
        while IFS= read -r arg; do extra_args+=("$arg"); done < <(centaur_image_values)
        ;;
      *) echo "unknown source: {{source}} (expected local, ghcr, or registry)" >&2; exit 2 ;;
    esac
    if [[ -n "${OP_CONNECT_CREDENTIALS_FILE:-}" ]]; then
      extra_args+=(
        --set ironProxy.secretSource=onepassword-connect
        --set onepasswordConnect.connect.create=true
      )
    fi
    if [[ -n "${CODEX_AUTH_MODE:-}" ]]; then
      extra_args+=(
        --set sandbox.codexAuthMode=${CODEX_AUTH_MODE}
      )
    fi
    if [[ -n "${CLAUDE_CODE_AUTH_MODE:-}" ]]; then
      extra_args+=(
        --set sandbox.claudeCodeAuthMode=${CLAUDE_CODE_AUTH_MODE}
      )
    fi
    # Layer an optional local-only values file (e.g. Tailscale Funnel ingress) on
    # top of values.dev.yaml. Kept out of the shared dev values so teammates'
    # `just up` is unaffected. Appended after -f {{dev_values}} so it wins
    # (helm applies -f files left-to-right).
    if [[ -n "${CENTAUR_EXTRA_VALUES:-}" ]]; then
      extra_args+=(-f "${CENTAUR_EXTRA_VALUES}")
    fi
    helm upgrade --install {{release}} {{chart}} -n {{namespace}} --create-namespace -f {{dev_values}} ${extra_args[@]+"${extra_args[@]}"}

# Bring up the dev stack; pass `k3s` (just up k3s) to push local images to the
# local registry (CENTAUR_LOCAL_REGISTRY, default localhost:5000) for k3s to pull.
up import="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "{{import}}" && "{{import}}" != "k3s" ]]; then
      echo "unknown argument: {{import}} (expected nothing or 'k3s')" >&2; exit 2
    fi
    just bootstrap-secrets
    case "{{source}}" in
      local)
        just build
        if [[ "{{import}}" == "k3s" ]]; then
          just _push-registry
        fi
        ;;
      ghcr|registry) ;;
      *) echo "unknown source: {{source}} (expected local, ghcr, or registry)" >&2; exit 2 ;;
    esac
    just source={{source}} deploy

down:
    kubectl delete namespace {{namespace}} --ignore-not-found --wait

reinstall:
    just down
    just up

status:
    kubectl get all -n {{namespace}}

logs component:
    kubectl logs -n {{namespace}} deploy/{{release}}-centaur-{{component}} --tail=200 -f

shell component:
    kubectl exec -it -n {{namespace}} deploy/{{release}}-centaur-{{component}} -- sh
