# Customer-hosted GCP deployment bundle

This bundle runs an Auggie daemon inside a customer's GCP boundary using the
customer's private Rocky Linux 8 images. Images, source, GCP identities, and the
Augment session credential remain in the customer project. The daemon makes an
outbound connection to the configured Augment daemon pool.

## Choose a deployment

| Customer environment | Artifact | Recommended use |
|---|---|---|
| GKE Autopilot | `helm/auggie-daemon` plus `values-gke-autopilot.yaml` | Lowest cluster operations; no privileged or host access required |
| GKE Standard | `helm/auggie-daemon` plus `values-gke-standard.yaml` | Custom node pools, sizing, or networking controls |
| Rocky 8 GCE VM | `gce/startup-direct.sh` | Install directly under a locked system account |
| Rocky 8 GCE VM with private container | `gce/startup-container.sh` | Rootless Podman and an immutable customer runtime image |
| Regional GCE fleet | `gce/terraform` | Instance-template/MIG example for either GCE mode |

## Shared security model

- Store the complete Augment `session.json` value in Google Secret Manager.
- Never place the value in Helm values, Terraform, instance metadata, Git,
  image layers, startup-script arguments, or logs.
- GKE uses Workload Identity Federation and the managed Secret Manager CSI
  add-on. GCE uses the VM's attached user-managed service account.
- Image pulls use customer GCP identity and `roles/artifactregistry.reader`.
- Pin workload and bootstrap images by digest for production.
- The credential is necessarily readable by Auggie at runtime. It is mounted or
  installed with a narrow service identity and is not distributed in deployment
  configuration.

## Rocky Linux 8 image contract

The recommended `bootstrapImage` mode supplies pinned Node 22 and Auggie 0.32.0
without changing the customer's image. The customer container needs compatible
Rocky 8 glibc, `/usr/bin/env`, trusted CA roots, Git, and any tools its sessions
use. It must allow the configured numeric non-root UID to read the image and
write only the mounted home, temporary, and workspace paths.

Build `bootstrap/` in the customer's supply chain from an approved digest-pinned
Rocky base, scan it, publish it to the customer registry, and deploy it by digest.
The alternatives are Helm `runtimeNpm` mode, which requires Node/npm and npm
egress in the customer image, or `preinstalled`, which requires the exact Auggie
version already in that image.

## GKE preparation

1. Enable Workload Identity Federation on Standard clusters; it is enabled by
   default on Autopilot.
2. Enable the GKE Secret Manager add-on. The chart uses provider `gke` and driver
   `secrets-store-gke.csi.k8s.io` on both cluster modes.
3. Grant `roles/secretmanager.secretAccessor` on only the session secret to the
   chart KSA principal for the release namespace.
4. Give the GKE node service account repository-level Artifact Registry Reader
   access. Cross-project repositories require an explicit grant.
5. Copy the Helm example, replace identifiers/image references, select one GKE
   profile and one security profile, render it, then install it.

The chart can reference a global or regional Secret Manager secret. It contains
references only. The Kubernetes Secret fallback is disabled unless the customer
explicitly acknowledges its weaker persistence model.

## GCE preparation

Attach a dedicated user-managed VM service account with secret-level
`roles/secretmanager.secretAccessor`. Container mode also needs repository-level
`roles/artifactregistry.reader`. The startup scripts accept non-secret resource
identifiers through instance metadata or a root-owned config file and retrieve
short-lived tokens from the metadata server without putting them in process
arguments. See `gce/README.md` for prerequisites and MIG guidance.

## Registry names

Legacy Container Registry stopped accepting writes in 2025. Existing `gcr.io`
names are supported only when backed by migrated Artifact Registry repositories.
Prefer `LOCATION-docker.pkg.dev` for new deployments, while accepting migrated
`gcr.io` image references for existing customer estates.

## Validation status

Run `./deploy/validate.sh` before packaging changes. It performs ShellCheck,
shell parsing, Helm schema/lint/render tests for all runtime and GKE modes,
negative security tests, optional kubeconform validation, JSON parsing, Terraform
format checks, and cross-artifact runtime assertions.

The GKE Autopilot path completed a sanitized live canary on 2026-07-12, including
preinstalled control registration, corrected bootstrap initialization, forced
pod replacement, NetworkPolicy allow/deny checks, Secret Manager rotation, and a
real pool-routed session. See `VALIDATION.md` for repeatable gates, evidence, and
the bootstrap defects found by the live test.

This qualification does not replace customer-specific testing. Before production
rollout, build from the customer's approved image digests, canary in each selected
platform/network, verify a routed session and rotation, then expand replicas or
the MIG.
