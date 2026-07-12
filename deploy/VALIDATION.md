# GCP deployment validation

This runbook qualifies an Auggie daemon deployment without placing credentials,
pool IDs, tenant URLs, or customer resource names in source control or logs.
Static rendering is necessary but does not replace a live routed-session test.

## Evidence rules

- Keep `session.json`, pool IDs, and generated values outside the repository with
  mode `0600`.
- Record secret names and image digests only in ephemeral deployment inputs.
- Classify daemon logs with allowlisted registration and rejection patterns; do
  not publish raw logs.
- Never record access tokens, tenant URLs, pool IDs, or credential hashes.
- Use a disposable namespace and remove any routed-session marker afterward.

## Local gate

Run `./deploy/validate.sh`. It performs ShellCheck, shell parsing, Helm
schema/lint/render tests, negative image-pin tests, optional kubeconform checks,
JSON validation, Terraform formatting, and cross-artifact assertions.

Build the bootstrap image from `deploy/bootstrap` with digest-pinned Rocky Linux
and verified Node checksums. Run `deploy/bootstrap/tests/smoke.sh IMAGE` in a
Linux Docker environment before publishing. The suite covers:

- Fresh copy and repeated idempotent copy.
- Final runtime preflight.
- UID 1000 with a read-only image root.
- User-owned and root-owned/fsGroup-writable runtime volumes.
- Unknown content, symlink destination, and relative-path rejection.

## Live GKE gate

Use one replica and an isolated namespace. The target cluster must provide:

- Private nodes with controlled HTTPS egress, normally Cloud NAT.
- Workload Identity Federation for GKE.
- The managed Secret Manager CSI driver.
- A private Artifact Registry repository.
- A default-deny NetworkPolicy implementation.

Grant `roles/secretmanager.secretAccessor` on only the session secret to the
release namespace and Kubernetes service account principal. Do not create a
Kubernetes Secret containing the Augment credential.

### 1. Preinstalled control

Build `deploy/preinstalled` from the pinned bootstrap and Rocky images. Deploy
Helm `preinstalled` mode by digest with the same service account, CSI mount,
workspace, and NetworkPolicy intended for the final deployment.

Pass when the pod is Ready with zero restarts and logs contain one of:

- `registered with poseidon`
- `daemon registered`
- `registered daemon`

Fail on `unknown daemon pool`, `not the daemon pool connector`, authentication
errors, or a WebSocket close/reconnect loop. A transport connection alone is not
registration success.

### 2. Bootstrap mode

Deploy `bootstrapImage` with workload and bootstrap images pinned by digest.
Verify the init container exits zero, reports successful runtime preflight, and
the main container reaches Ready and registers. Delete the pod and require the
replacement to repeat initialization, reuse the workspace PVC, and register
without restarts.

### 3. Security controls

Verify the live pod and cloud resources, not only rendered YAML:

- Numeric non-root UID/GID and `RuntimeDefault` seccomp.
- Read-only root filesystem, no privilege escalation, and all capabilities
  dropped for main and init containers.
- Service-account token automount disabled.
- Credential supplied by `secrets-store-gke.csi.k8s.io` on a read-only mount.
- No credential-named Kubernetes Secret.
- Private, immutable Artifact Registry images used by digest.
- Default-deny ingress; DNS and TCP 443 allowed; TCP 80 denied.
- Native ADC requires narrowly scoped egress to the documented GKE metadata
  server. CSI secret mounting alone does not prove application ADC works.
- No exact session or pool-file content in tracked repository files.

### 4. Secret rotation

Add a valid temporary session version carrying a non-secret validation marker,
recreate the pod, and verify the marker and registration without printing other
fields. Restore the original session as the latest version, recreate and verify
again, then disable the temporary marked version.

### 5. Routed session

From the Augment control plane, route a new session to the pool and have it write
a non-secret agreed marker under `/workspace`. Verify the exact marker from the
pod and remove it. This proves the complete control-plane-to-workspace path;
daemon registration alone is insufficient.

## Sanitized live run: 2026-07-12

Environment: GKE Autopilot 1.35, private nodes, dedicated VPC/subnet/NAT,
Workload Identity, managed Secret Manager CSI, private Artifact Registry, one
replica, Rocky Linux 8, Node 22.23.1, and Auggie 0.32.0.

| Check | Result |
|---|---|
| Local deployment validation | PASS |
| Preinstalled image read-only/non-root smoke test | PASS |
| Preinstalled control registration | PASS |
| Original bootstrap initialization | FAIL; defects below |
| Corrected container owner/fsGroup regression tests | PASS |
| Corrected exact GKE init smoke test | PASS |
| Hardened Helm rollout and registration | PASS |
| Forced pod replacement and PVC reuse | PASS |
| DNS/TCP 443 allow and TCP 80 denial | PASS |
| Expected-only secret accessor and private registry | PASS |
| Secret rotation, restoration, and registration | PASS |
| Real routed session workspace marker | PASS |
| Credential/pool-content repository scan | PASS |

## Reference-only runtime GSM pilot: 2026-07-12

This follow-up distinguished the daemon's Augment session credential from an
application secret. Two random non-production GSM canaries were created without
printing or persisting their values. Cosmos received only full GSM resource
references. The routed process used the official Google Secret Manager Node.js
client through GKE Workload Identity and held the allowed payload in memory.

`pcln/secrets` was treated as Priceline's internal GSM convention, not a public
package. No public npm package or source repository with that name was found.

| Control | Result |
|---|---|
| Application references absent from pod configuration | PASS |
| Authorized runtime resolution under team KSA | PASS |
| Unrelated canary access denied | PASS |
| Cosmos-routed allowed/denied operations | PASS |
| Exact payload absent from workspace, home, tmp, and logs | PASS |
| Data-read audit attributed to exact namespace/KSA | PASS |
| Live IAM revocation stopped access | PASS after 72-second propagation |
| Namespace, PVC, IAM, canaries, and audit override cleanup | PASS |

GKE Dataplane V2 required `169.254.169.254/32` on TCP ports 80 and
8080 for the metadata server. General external TCP 80 remained denied. The
disposable image could not be deleted because immutable tags were enabled; the
non-secret digest was retained rather than weakening repository policy.

### Scope not proved by this pilot

- The routed test used a cooperative one-shot client. An agent process authorized
  to resolve a value can also print, write, or send that value over an allowed
  destination. This repository does not provide a secret broker, content filter,
  DLP control, or destination-level HTTPS allowlist that prevents exfiltration.
- No real Priceline application endpoint or private Priceline resolution helper
  was tested. The pilot proved native GSM/ADC plumbing with Google's official
  client in the sandbox project.
- Repository-to-host-group mapping, fail-closed routing, review-session access,
  tool permissions, audit retention, and coordinated team offboarding are Cosmos
  or Priceline operational controls outside this repository.
- Swap, crash-dump, node-memory, and backup handling depend on the customer host
  or cluster baseline and were not qualified by the pod-level persistence scan.
- Production `DATA_READ` audit logging must be enabled and retained by the
  customer. The sandbox override was temporary and restored after evidence was
  collected.

### Defects discovered and corrected

1. Copying an immutable source root propagated a non-writable mode to the stage;
   directory-tree rename and cleanup then failed as UID 1000.
2. GKE `emptyDir` was root-owned but fsGroup-writable. Requiring the non-root
   process to chmod the mount root failed even though it was already writable.
3. The bootstrap init container lacked the chart's writable `/tmp` mount,
   causing an avoidable read-only-filesystem warning during Auggie preflight.

The corrected flow holds the lock, copies trusted runtime content directly,
changes destination mode only when it is not already writable, preflights the
final runtime, and writes the completion marker last. Graceful failure cleanup
is limited to known partial paths; unknown content remains fail-closed.

## Cleanup and release gate

After qualification, remove diagnostic pods, marker files, temporary values,
temporary secret versions, unused images, PVCs, and canary infrastructure unless
retention is intentional. Revoke temporary secret IAM and credentials.

Do not move an existing immutable release tag. Ship bootstrap/chart corrections
as a follow-up patch release after review, CI, and a clean-tree validation run.
