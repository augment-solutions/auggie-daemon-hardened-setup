# Auggie daemon Helm chart

Production Helm v3 chart for Auggie daemon `0.32.0`. It runs the daemon in a
private, customer-supplied Rocky Linux 8-compatible OCI image. The chart does
not publish, select, or assume access to a hosted workload or bootstrap image.

## Security model

- Direct `command`/`args` arrays invoke Auggie; no shell or `eval` is used.
- Non-root UID/GID `1000` by default (configurable), read-only root filesystem,
  `RuntimeDefault` seccomp, all capabilities dropped, and privilege escalation
  disabled.
- Writable paths are explicit `emptyDir` or PVC mounts only.
- Main and init container resources include CPU, memory, and ephemeral storage.
- Service account token automounting is disabled by default.
- Values accept secret references only. Secret content has no values field.

The main process receives these arguments as separate entries:

`auggie daemon --pool-id VALUE --augment-session-json PATH --workspace PATH`
`[--add-workspace PATH ...] [--max-agents N] --allow-indexing`
`--name PREFIX-PODNAME`

Kubernetes expands `$(POD_NAME)` from the downward API without a shell.

## Prerequisites

- Kubernetes 1.25+ and Helm 3.
- A private Rocky Linux 8-compatible image accessible to the cluster.
- For GKE Secret Manager: enable the Secret Manager managed add-on and grant
  the KSA principal access to the referenced secret versions.
- For `runtimeNpm`: the customer image contains compatible `node` and `npm`,
  and can reach the configured npm registry during pod initialization.
- For `bootstrapImage`, build and mirror `deploy/bootstrap`; the customer image
  only needs Rocky 8-compatible glibc, `/usr/bin/env`, Git, and trusted CA roots.

## Install

Copy the example, replace every placeholder, and select one platform profile:

```bash
helm upgrade --install auggie ./deploy/helm/auggie-daemon \
  --namespace auggie --create-namespace \
  -f deploy/helm/auggie-daemon/values-gke-autopilot.yaml \
  -f my-values.yaml
```

Use `values-gke-standard.yaml` for GKE Standard. Its WIF metadata-server node
selector is optional: set
`platform.gkeStandard.workloadIdentityNodeSelector.enabled=false` when the
selected node pool does not require it. The selector is forcibly omitted when
`platform.mode=gkeAutopilot`.

Optional overlays:

- `values-standard.yaml`: two replicas, per-replica PVCs, and PDB.
- `values-hardened.yaml`: the standard settings plus default-deny ingress and
  DNS/HTTPS-only egress. Add explicit egress rules if private registries,
  proxies, or other services require them.
- `values-gke-standard.yaml`: GKE Standard and optional WIF node selection.
- `values-gke-autopilot.yaml`: no Standard selector and explicit Autopilot
  resources.

## Credentials

### GKE Secret Manager (preferred)

Set `credentials.mode=secretProviderClass`. The chart can create a
`SecretProviderClass` with provider `gke`, then mounts it through
`secrets-store-gke.csi.k8s.io`. Each entry contains only a Secret Manager
resource name and mounted file name. One `path` must match `sessionFile`.

To use an existing object, set `secretProviderClass.create=false` and
`secretProviderClass.existingName`. The object must be in the release namespace.

For WIF, use the chart-created KSA or set `serviceAccount.create=false` and
provide `serviceAccount.name`. KSA annotations are supported for environments
that map a KSA to a Google service account.

If application code uses ADC directly, allow egress to the GKE metadata server
through `networkPolicy.additionalEgress`. GKE Dataplane V2 uses
`169.254.169.254/32` on TCP 80 and 8080; other GKE dataplanes use documented
metadata endpoints and ports. Keep the rule scoped to the required `/32` so
general HTTP egress remains denied. Secret Manager CSI access does not validate
that in-pod ADC can reach the metadata server.

### Existing Kubernetes Secret (discouraged)

This fallback is intentionally gated. Set `credentials.mode=kubernetesSecret`,
provide `existingSecret` and `key`, and explicitly set `acknowledgeRisk=true`.
The chart never creates the Secret and never accepts its content in values.

## Bootstrap modes

| Mode | Behavior | Customer image contract |
|---|---|---|
| `runtimeNpm` | Installs `@augmentcode/auggie@0.32.0` into an `emptyDir` | Workload image includes Node, npm, and required OS libraries |
| `bootstrapImage` | Its verified copy entrypoint places pinned Node and Auggie trees into an `emptyDir` | Supply a private image built from `deploy/bootstrap`; customer image needs Rocky 8-compatible glibc and normal CLI prerequisites such as Git/CA roots |
| `preinstalled` | Runs `auggie` from the workload image `PATH` | Workload image already contains Auggie `0.32.0` |

`bootstrapImage.repository` is mandatory in that mode. Build and scan this image
inside the customer supply chain; there is no chart default.

## Workspace modes

- `persistent`: one `ReadWriteOnce` PVC per StatefulSet replica, preserving
  stable identity and workspace data.
- `ephemeral`: an empty writable `emptyDir` per pod.
- `image`: copies `workspace.image.sourcePath` from the workload image into a
  writable `emptyDir`; image contents remain immutable.

Additional workspace arguments must be absolute paths available within the
container, normally subdirectories of the mounted primary workspace.

## Scaling and availability

The optional HPA targets the StatefulSet and omits fixed `replicas` when active.
An optional PDB accepts either `minAvailable` or `maxUnavailable`, never both.
Set the unused PDB field to `null` when switching between those controls.
Every pod receives a stable StatefulSet name, and configuration changes alter a
pod-template checksum to trigger a controlled rollout.

## Validation and operations

The schema and templates reject unpinned images, missing pool IDs, invalid
bootstrap/workspace modes, incomplete SecretProviderClass configuration, and
unacknowledged Kubernetes Secret fallback. Validate before deploying:

```bash
helm lint ./deploy/helm/auggie-daemon -f my-values.yaml
helm template auggie ./deploy/helm/auggie-daemon -f my-values.yaml
```

The NetworkPolicy is deliberately optional because DNS, registries, proxies,
and private endpoints vary by customer. Test it in the target cluster before
enabling it in production.
