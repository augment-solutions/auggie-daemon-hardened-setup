# Secure Rocky Linux 8 deployment on Google Compute Engine

This directory provides two GCE deployment choices. Neither choice downloads a
service-account key. Both use the VM's attached user-managed service account and
retrieve Augment `session.json` from Secret Manager at boot.

## Decision matrix

| Consideration | Direct host | Rootless Podman on VM |
|---|---|---|
| Existing installer | Reuses `../../setup-auggie-daemon-linux.sh` noninteractively | Bootstrap image populates a shared runtime used by the private Rocky 8 image |
| Isolation | Locked system user plus hardened systemd | Locked host user, rootless Podman, read-only container root, dropped capabilities |
| Image prerequisites | Rocky 8 with Node 22+, npm, git, curl, jq, sudo | Rocky 8 VM with Podman/curl/jq; private container with Rocky 8-compatible glibc, `/usr/bin/env`, Git, and CA roots |
| Upgrade model | Replace the instance template after changing exact CLI version | Build, scan, and pin a new bootstrap image digest |
| Runtime persistence | `/srv/augment` on each VM boot disk | Workspace/state under `/var/lib`; session credential only under `/run` |
| Best fit | Smallest operational change from the existing installer | Stronger packaging, immutability, and supply-chain control |

MIG replacement deletes the boot disk by design. Use an approved external source
or separately managed persistent disk if workspace state must survive replacement.

## Security model and prerequisites

1. Use a customer-owned Rocky Linux 8 image. Do not rely on a public image name in
   Terraform; `source_image` is required.
2. Attach a dedicated user-managed VM service account. The Terraform example grants:
   - `roles/secretmanager.secretAccessor` on only the selected secret.
   - `roles/artifactregistry.reader` in container mode.
3. Grant the VM no broader IAM roles. The `cloud-platform` OAuth scope is only an
   upper bound; IAM remains authoritative.
4. Use private Google access or another controlled egress path. The template does
   not create an external IP or firewall rule.
5. Store the complete Augment `session.json` as a Secret Manager secret value.
   Secret values, OAuth tokens, bearer tokens, registry passwords, and service
   account keys must never be placed in Terraform, instance metadata, command-line
   arguments, image layers, or logs.
6. Pin customer VM/container images according to policy. Container mode enforces an
   Artifact Registry or `gcr.io` image URI with an `@sha256:` digest.

Both startup scripts validate the Secret Manager envelope and required session
fields without printing their values. REST bearer authentication is written only
to a mode `0600` temporary curl config under `/run/augment-gce`; registry login uses
`--password-stdin` and a temporary auth file under `/run`. Traps remove temporary
OAuth, response, curl, installer, session, and registry-auth files.

## Configuration

The Terraform example uses non-secret instance metadata attributes. The startup
scripts may instead read `/etc/augment-gce/config.env`, which is useful for baked
images. Install one of `config/*.env.example` at that path, keep it root-owned and
not group/world writable, and include identifiers/tuning values only. If the file
exists, it takes precedence over metadata. A malformed, symlinked, non-root-owned,
unknown-key, or writable config is rejected.

Supported common settings are `POOL_ID`, `SECRET_PROJECT_ID`,
`SESSION_SECRET_ID`, `SESSION_SECRET_VERSION`, `MAX_AGENTS`, and optional
`DAEMON_NAME`. Direct mode also accepts exact `AUGGIE_VERSION`. Container mode
requires `RUNTIME_IMAGE` and `BOOTSTRAP_IMAGE`, and accepts `MEMORY_LIMIT`, `CPU_LIMIT`, and
`PIDS_LIMIT`.

The final daemon command in both modes includes all security-relevant arguments:
`daemon`, `--pool-id`, `--workspace`, `--max-agents`, `--allow-indexing`, `--name`,
and explicit `--augment-session-json`. Secret data itself is never an argument.

## Direct-host mode

The direct startup script stages the repository installer under `/run`, forces its
temporary directory to `/run/augment-gce`, and verifies that the generated unit
uses explicit `--augment-session-json` handling.
It intentionally creates the installer's sandbox workspace; seed work through an
approved post-provisioning process rather than credential-bearing Git URLs.

The customer Rocky 8 image must already provide Node.js 22+, npm, git, curl, jq,
GNU coreutils, sudo, and systemd. Keeping runtime prerequisites in the approved VM
image avoids executing third-party repository bootstrap scripts as root at boot.

## Container mode

Build `../bootstrap/Dockerfile` in the customer build system, scan it, and push it
to Artifact Registry. Configure both the private Rocky runtime image digest and
bootstrap image digest. Host both in the Artifact Registry project receiving
`roles/artifactregistry.reader`. The Rocky runtime image does not need Node or npm;
the mounted bootstrap runtime supplies them. It must provide compatible glibc,
`/usr/bin/env`, Git, and trusted CA roots. Never pass credentials as build arguments.

Container mode runs Podman as locked `svc-auggie-container`, not root. The systemd
unit first runs the bootstrap image without networking to populate the explicit
shared runtime volume. It then runs the private Rocky image with that runtime
mounted read-only, a read-only image root, container `no-new-privileges`,
`cap-drop=ALL`, explicit writable volumes/tmpfs mounts, PID/memory/CPU limits, and restart policy. The VM
image must provide Podman with rootless support, curl, jq, GNU coreutils, and
systemd. It must also allocate subordinate UID/GID ranges for newly created users.
Validate rootless Podman, `fuse-overlayfs`, SELinux, and cgroup-v2 compatibility in
image qualification.

Secret rotation is applied on replacement/restartup provisioning. To rotate in
place, rerun the appropriate startup script through an approved administrative
mechanism; do not copy the secret through SSH or metadata.

## Terraform regional MIG example

The `terraform/` example creates a regional instance template and regional MIG,
adds the least-privilege IAM bindings above, references startup artifacts with
Terraform `file()`, enables Shielded VM controls, and creates no inbound exposure.
It deliberately has no defaults for customer project, region, zones, VM image,
machine type, network, subnetwork, or service-account identity.

Copy `terraform/terraform.tfvars.example`, populate only non-secret identifiers,
then run `terraform init`, `terraform plan`, and an approved `terraform apply`.
Use separate state/configurations for direct and container groups. Terraform state
contains metadata identifiers but never the Secret Manager secret value.

## Operations and validation

- Direct logs: `journalctl -u auggie-daemon`
- Container logs: `journalctl -u auggie-daemon-container`
- Confirm the generated unit contains `--augment-session-json` without displaying
  the session file.
- Confirm session permissions are `0600`; do not run `cat`, `jq`, shell tracing, or
  diagnostic commands that print the file or environment.
- Verify the pool reports the expected daemon instances and exercise a test session.
- Review serial-console/startup logs for errors before enabling broad rollout.

Do not enable `set -x` in these scripts. Treat `/srv/augment/.augment/session.json`
and `/run/augment-session/session.json` as live credentials even though
their permissions and service boundaries are restricted.