# Configurable image publishing and registries

## Goal

Allow forks to build, publish, test, and select Centaur images using their own
public image repositories without editing upstream workflow logic. With no new
overrides set, the repository must behave exactly as it does today: every existing hardcoded
value becomes the default for its corresponding configuration option.

## Compatibility requirement

Preserve existing registry destinations, repository namespaces, source metadata,
credentials, Depot project and runners, platform selection, image names and tags,
local build/push behavior, Helm override precedence, and notification behavior.
Existing commands and workflows must continue to work without new configuration.
Fork-specific behavior, alternative builders, and notification disabling must be
explicit overrides, not new defaults. Additive options must not change existing
environment-variable meanings or trust boundaries.

## Scope

- Image registry, repository namespace, authentication, and source metadata.
- Configurable builders, runners, and target platforms for image publication.
- Matching image destinations in local build/push helpers, Helm selection, and E2E.
- Anonymous pulls from the selected public repositories, including the agent pre-pull.
- An optional publication notification hook.

Production Kubernetes CD, chart publication destinations, documentation hosting,
image digest deployment manifests, tool/overlay source pinning, and private-image
pull support are deferred. No Rust runtime or Helm chart changes are required.

## Credentials for the finished feature

Configure publishing credentials through GitHub Actions secrets or a local
credential store. Do not put credential values in this document, source
control, or chat. New secret names below are proposed; preserve existing secret
names and defaults where already supported.

| Credential/access | Where to configure | Required scope and purpose |
| --- | --- | --- |
| Custom registry publishing identity | Actions secrets `CENTAUR_REGISTRY_USERNAME` and `CENTAUR_REGISTRY_PASSWORD` | Push and pull within the configured image namespace, including manifest publication. Supply the target registry's token directly to the existing login action; GHCR retains its default token. |
| GitHub Actions token for GHCR | Automatically provided `GITHUB_TOKEN`, with workflow `packages: write` and repository read permissions | Used for the existing GHCR authentication path. No manually supplied GitHub token is needed for this path; package access must allow the fork to publish to its configured namespace. |
| Depot identity and project access, if using Depot | Depot's supported GitHub OIDC integration and configured project/runner access, or an Actions secret if the chosen setup requires a token | Conditional: unnecessary for Buildx. A fork selecting Depot needs its own authorized project; do not assume access to upstream's project. |
| Dispatch credential, if notification is enabled | Existing dispatch secret or `CENTAUR_DISPATCH_TOKEN` | Permission to dispatch to the configured downstream repository. An explicitly disabled hook requires no credential. |

The user can configure Actions variables/secrets directly; repository admin
credentials do not need to be shared. Registry host, image namespace, runner
labels, Depot project ID, and Kubernetes context are configuration values rather
than credentials.

Public repositories still require authenticated push access. Configure anonymous
read access in the registry; this feature does not change repository visibility.
Kubernetes and E2E need no registry credentials. Existing image-pull-secret
behavior remains unchanged.

## Credentials for local testing and validation

1. **Static checks:** no external credentials. Docker, Helm, shell tooling, and
   repository dependencies must be available locally.
2. **Local registry:** no credentials. Use a disposable anonymous loopback
   registry for publishing, manifest assembly, and pull tests.
3. **Disposable Kubernetes cluster:** a local kubeconfig with an explicit test
   context, allowing test namespaces and workloads. No production cluster
   credentials, registry pull Secrets, CRDs, or Rust toolchain are needed for the
   public-image smoke.
4. **Optional remote workflow checks:** an authenticated GitHub session allowed
   to run workflows in the fork, plus publishing credentials for the selected
   registry. Depot and dispatch checks additionally need a test project and a
   controlled downstream repository when enabled. Report unrun checks.

Any branch push needed to exercise changed workflows requires separate
authorization. Local implementation and validation require no GitHub write
credential. Do not reuse production credentials for disposable tests.

## Implementation

1. **Define the publishing contract.** Add documented repository variables and
   reusable workflow inputs for registry, image namespace, platforms, builder,
   runner labels, and Depot project. Retain the current literal values as defaults,
   including the existing upstream namespace and OCI source URL; document how a
   fork overrides both. Normalize configured repository casing and validate inputs.
   Keep existing image names and tags.
2. **Make publication portable.** Update
   `.github/workflows/publish-images.yml` to support standard Docker Buildx and
   Depot builds, retaining Depot as the default, multi-platform digest publication,
   and manifest assembly. Accept registry credentials as secrets; use
   `GITHUB_TOKEN` only for the GHCR default. Reuse the existing
   `docker/login-action` steps with configurable username/token inputs, without a
   custom action or authentication-mode abstraction. Automatic cloud-token
   issuance/refresh is deferred. Preserve the fork-PR trust boundary: untrusted PRs must not publish or receive secrets.
3. **Use the same destinations everywhere.** Update the root `Justfile`,
   `.github/workflows/e2e.yml`, and `e2e/stack.sh` to accept a consistent registry,
   namespace, and tag contract. Cover the agent pre-pull as well as service images.
   Preserve local image loading and the k3s mirror helper. Keep `ghcr` as a
   compatibility alias and add a generic registry path with documented override
   precedence, preserving precedence for existing commands. Honor the existing
   agent image override in build and push paths.
4. **Make notification configurable.** Parameterize the existing dispatch target,
   environment, event name, and credential reference while preserving current
   defaults and execution conditions. Add an explicit disable option so forks can
   skip notification successfully without changing workflow logic.
5. **Update user documentation.** Extend the existing production deployment and
   local setup guides with a publishing/registry configuration reference. For
   every option, list its exact name, existing default, purpose, scope (GitHub
   repository variable, workflow input, secret, shell variable, or Helm value),
   and precedence. Explain where to set GitHub Actions variables and secrets and
   how to supply local environment overrides. Include copyable GHCR fork and
   custom-registry examples covering credentials, builders/runners/platforms,
   matching public E2E and Helm image selection, repository visibility, and
   disabling the notification hook. State that no overrides preserve current behavior. Keep
   cluster credentials out of the publishing workflow.
6. **Verify compatibility and delivery.** Add focused configuration-resolution,
   workflow, Helm rendering, and anonymous public-image pull checks. Leave Rust
   runtime code, Helm templates/values, and chart versions unchanged. Run the
   acceptance checks below and report unavailable integration checks. Deliver local changes without opening
   a PR, committing, or pushing.

## Complete override inventory

These are the proposed public options for this feature. All are optional for
existing users; a fork overrides only the values that differ from its target
setup. Defaults described as "current" mean the exact checked-in value or
event-dependent behavior, not a value derived from the fork. Resolve workflow
inputs before repository variables, then fall back to current defaults. Pass
resolved values explicitly to reusable workflows and E2E jobs.

### Publishing workflow inputs and repository variables

Expose each numbered option as a `workflow_call` input (lowercase name without
the `CENTAUR_` prefix) and a GitHub repository variable using the name shown.
Keep authentication material in the separate secret interface below.

| # | Repository variable | Default and purpose |
| --- | --- | --- |
| 1 | `CENTAUR_REGISTRY` | Current GHCR hostname; publication registry host, including optional port. |
| 2 | `CENTAUR_IMAGE_NAMESPACE` | Current upstream namespace; repository path below the registry, supporting nested namespaces. |
| 3 | `CENTAUR_IMAGE_SOURCE_URL` | Current upstream OCI source URL; override to identify the fork. |
| 4 | `CENTAUR_BUILD_BACKEND` | `depot`; allow `buildx` without requiring Depot credentials or project access. |
| 5 | `CENTAUR_DEPOT_PROJECT` | Current Depot project ID; used only by the Depot backend. |
| 6 | `CENTAUR_BUILD_PLATFORMS` | Current event-based matrix: amd64 and arm64 on publishing pushes, amd64 otherwise; allow a validated JSON platform array. |
| 7 | `CENTAUR_BUILD_RUNNER_AMD64` | Current amd64 Depot runner; accept one runner label. |
| 8 | `CENTAUR_BUILD_RUNNER_ARM64` | Current arm64 Depot runner; accept one runner label. |
| 9 | `CENTAUR_MANIFEST_RUNNER` | Current merge-job Depot runner. |
| 10 | `CENTAUR_E2E_RUNNER` | Current E2E Depot runner; affects the reusable E2E workflow. |
| 11 | `CENTAUR_RUST_BUILD_PROFILE` | Current event-dependent debug/release selection; allow an explicit profile. |
| 12 | `CENTAUR_DISPATCH_ENABLED` | Enabled under the existing event conditions; `false` skips the job entirely. |
| 13 | `CENTAUR_DISPATCH_REPOSITORY` | Current downstream repository; allow a fork-owned destination. |
| 14 | `CENTAUR_DISPATCH_EVENT_TYPE` | Current dispatch event type. |
| 15 | `CENTAUR_DISPATCH_ENVIRONMENT` | Current notification job's GitHub environment. |
| 16 | `CENTAUR_DISPATCH_RUNNER` | Current notification job's runner. |

Runner overrides accept a single label. Use direct input/variable/default
fallbacks without JSON parsing or string construction; the build job selects the
label for its architecture.

Selecting Buildx does not silently change runner defaults: document the runner
overrides needed for a fork without Depot. Existing tag rules, trigger branches,
job conditions, and image basenames remain unchanged. Trigger policy can be
selected in the thin caller workflow; arbitrary tag templates and per-service
Dockerfile overrides are outside this feature.

### Authentication secrets

| # | Secret | Default and purpose |
| --- | --- | --- |
| 17 | `CENTAUR_REGISTRY_USERNAME` | Unset; overrides the existing `github.actor` username default. |
| 18 | `CENTAUR_REGISTRY_PASSWORD` | Unset; password or access token for publishing. Falls back to `GITHUB_TOKEN` only for GHCR. |
| 19 | `CENTAUR_DISPATCH_TOKEN` | Fall back to the existing dispatch secret; replacement token for a configured destination. |

Preserve the automatically supplied `GITHUB_TOKEN` path for GHCR only. Other
registries supply their token through the same login input. Provider-specific
token generation/refresh and credential helpers are outside this MVP; Depot
retains its existing authentication. Do not add a custom login action or shell
command override.

### Local build, push, Helm selection, and E2E

| # | Shell variable or workflow input | Default and purpose |
| --- | --- | --- |
| 20 | `CENTAUR_REGISTRY`, `CENTAUR_IMAGE_NAMESPACE` | For the generic registry path, current published-image destination; passed from CI to E2E explicitly. Do not alter local bare-image defaults or the existing k3s mirror path. |
| 21 | `CENTAUR_IMAGE_TAG` | `latest`; tag for the new generic build/push/deploy path. Existing CI tag generation and E2E tag selection remain intact. |
| 22 | `CENTAUR_IMAGE_SOURCE` | Existing `local` default and `ghcr` behavior; add `registry` for explicitly configured destinations. |
| 23 | `CENTAUR_LOCAL_REGISTRY` | Existing local registry default; retains the k3s `/library/` mirror convention. |
| 24 | `CENTAUR_AGENT_IMAGE`, `CENTAUR_AGENT_DOCKERFILE`, `CENTAUR_AGENT_BUILD_TARGET` | Preserve their existing defaults and honor the image override through local build/push operations. |
| 25 | `CENTAUR_E2E_IMAGE_TAG` / E2E `image_tag` input | Existing local-build and published-tag behavior; publication callers pass their selected tag explicitly. |
| 26 | E2E `registry` and `image_namespace` inputs | Current published destination; populate from the publishing workflow, including the agent pre-pull. |
| 27 | `CENTAUR_EXTRA_VALUES` | Existing optional values-file behavior; document how to select per-service images without changing existing Helm precedence. |

New explicit generic image settings take precedence over inferred generic
defaults; existing `local` and `ghcr` commands retain their current resolution.
Avoid silently reinterpreting `CENTAUR_LOCAL_REGISTRY` as a production registry.

### Helm values

| # | Value | Default and purpose |
| --- | --- | --- |
| 28 | `<component>.image.repository`, `.tag`, `.pullPolicy` | Existing per-component values; retain independent image selection for `apiRs`, `experimentalCompanyContext`, `proxySync`, `tokenBroker`, `ironProxy`, `slackbotv2`, `linearbot`, `discordbot`, `githubbot`, `teamsbot`, `sandbox`, and `console`. |
| 29 | `toolServer.runnerImage.repository`, `.tag`, `.pullPolicy` | Existing sandbox-image fallback; preserve consistent resolution for tool init containers. |
| 30 | `repoCache.image.repository`, `.tag`, `.pullPolicy` | Existing sandbox-image fallback; preserve repository-cache image selection. |
| 31 | `agentSandbox.image.repository`, `.tag`, `.pullPolicy` | Existing controller image defaults; allow a mirrored controller image. |
| 32 | `postgres.image.repository`, `.tag`, `.pullPolicy` | Existing database image defaults, also used by database init containers; allow a mirrored database image. |

Third-party subchart image settings remain owned by their existing values
interfaces. This feature does not rewrite Dockerfile base-image sources or add
an air-gapped dependency mirror system. No new release name, cluster target,
namespace, storage, ingress, or production deployment overrides are introduced.

## Validation and acceptance

- Run configuration regression tests, actionlint, shell checks, and Helm
  lint/render checks. Confirm no Rust runtime or Helm chart diff remains.
- With all new options unset, verify existing workflow destinations, metadata,
   authentication, builders/runners/platforms, tags, notification behavior, and
   local build/deploy commands are unchanged.
- Check documented override examples against the implemented option names,
   defaults, and precedence, including a fork using only documented configuration.
- Publish and test images in a controlled registry, including a hostname with a
   port and a nested namespace; verify each requested platform manifest exists.
- Confirm E2E consumes the selected published images rather than upstream images.
- Exercise anonymous pulls from the local public registry through the E2E-style
  agent pre-pull and a Kubernetes Pod with no image-pull Secrets.
- Confirm missing custom-registry credentials fail clearly, an explicitly disabled
   notification hook is skipped, and fork PRs cannot publish or access publishing
   secrets.

## Implementation artifacts

- Shared image naming and local builds: `contrib/scripts/image-config.sh`,
  `contrib/scripts/build-image.sh`, and the root `Justfile`.
- Publishing inputs and direct reuse of the existing `docker/login-action`:
  `.github/workflows/publish-images.yml`, with image configuration/manifest helpers
  under `.github/scripts/`. No new login `action.yml` is added.
- Published-image E2E destinations: `.github/workflows/e2e.yml` and
  `e2e/stack.sh`. No E2E registry-authentication inputs or helper are added.
- User reference: `docs/pages/reference/image-publishing.mdx`, linked from the
  production and local setup guides and documentation navigation.
- Validation: `scripts/test_image_config.py`, image-configuration CI job,
  public-image checks, and `scripts/smoke_image_registry.sh`. The smoke's optional
  `CENTAUR_REGISTRY_SMOKE_PORT` override defaults to `5051` and affects testing only.

The local smoke uses an anonymous registry and small fixture images; it proves
public image publication, shared manifest assembly, and kubelet pulls rather than
a full application/chat rollout. Remote GitHub Actions, Depot, and dispatch checks
remain separate and require the credentials and branch publication above.

## Validation results

- All 12 public image configuration/Helm regression tests pass.
- Actionlint, ShellCheck, Helm lint, and `git diff --check` pass.
- Rust sources, Cargo manifests/lockfile, and Helm chart files match the original
  checkout exactly; no runtime or chart version change remains.
- The anonymous local registry smoke passes: amd64/arm64 publication by digest,
  shared manifest assembly, E2E-style agent pre-pull, and a Pod pulling and running
  the selected image without image-pull Secrets. Test resources were cleaned up.
- Full chat E2E and remote GitHub Actions, Depot, and dispatch integrations remain
  unverified. The earlier full API image build hit Docker Desktop's disk limit;
  no API rebuild is required for this revised feature.

## Proposed PR

`feat: support configurable image publishing and registry destinations`

Deliver the implementation, documentation, validation results, and any remaining
validation limitations. Stop before opening a PR. Committing or pushing changes
is not part of this plan unless separately requested; report any CI validation
that cannot run without publishing a branch.

Keep deployment-specific values in fork-owned configuration so future upstream
merges do not require maintaining a separate copy of the publishing machinery.
