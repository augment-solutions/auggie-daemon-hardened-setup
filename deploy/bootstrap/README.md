# Auggie bootstrap OCI image

This build produces a Rocky Linux 8-compatible bootstrap image containing:

- Node.js `22.23.1` from the official Linux binary distribution.
- Exactly `@augmentcode/auggie@0.32.0` in an isolated npm prefix.
- A non-root entrypoint that copies the immutable runtime into a shared volume.

The target customer container does not need Node or npm preinstalled. It still needs the normal Rocky 8 runtime libraries, CA certificates, and any external tools Auggie uses for the workload (notably `git`). No credentials, Augment session, npm token, or registry credential belongs in this image or its build arguments.

## Supply-chain inputs

Build from this directory. `ROCKY_BASE_IMAGE`, `NODE_SHA256_AMD64`, and `NODE_SHA256_ARM64` are mandatory. Both Node checksums are required even for a single-platform build so the same invocation can safely become a multi-platform build.

Resolve and review the current Rocky 8 minimal multi-platform manifest, then pin the approved index digest. The value below is deliberately a placeholder; do not replace it with an invented digest.

```sh
docker buildx imagetools inspect docker.io/library/rockylinux:8-minimal
export ROCKY_BASE_IMAGE='docker.io/library/rockylinux:8-minimal@sha256:<verified-multi-arch-index-digest>'
```

Verify Node's signed release checksum document according to the Node.js release-team instructions before trusting its contents:

- `https://nodejs.org/download/release/v22.23.1/SHASUMS256.txt`
- `https://nodejs.org/download/release/v22.23.1/SHASUMS256.txt.sig`

For this pinned release, the official document lists:

```sh
export NODE_SHA256_AMD64='9749e988f437343b7fa832c69ded82a312e41a03116d766797ac14f6f9eee578'
export NODE_SHA256_ARM64='0294e8b915ab75f92c7513d2fcb830ae06e10684e6c603e99a87dbf8835389c1'
```

The Dockerfile rejects a base reference without a valid lowercase SHA-256 digest. It downloads a platform-specific Node `.tar.xz`, validates the selected SHA-256 before extraction, and rejects missing, uppercase, malformed, or unsupported architecture inputs. It never pipes downloaded content into a shell. npm installation, including any native optional-dependency build steps, runs as UID/GID `10001`, and the npm cache is removed before the final stage.

## Build locally

Create a single-platform image for the local host. Change the platform explicitly when testing the other architecture; emulation must be configured if it differs from the host.

```sh
docker buildx build \
  --platform linux/amd64 \
  --build-arg "ROCKY_BASE_IMAGE=${ROCKY_BASE_IMAGE}" \
  --build-arg "NODE_SHA256_AMD64=${NODE_SHA256_AMD64}" \
  --build-arg "NODE_SHA256_ARM64=${NODE_SHA256_ARM64}" \
  --tag auggie-bootstrap:node-22.23.1-auggie-0.32.0 \
  --load .
```

The build executes Node and `auggie --version` inside Rocky 8. Multi-platform output is supported for `linux/amd64` and `linux/arm64`; publish it directly because Docker cannot `--load` a multi-platform index into the classic local image store.

## Publish to Artifact Registry

Create a Docker-format Artifact Registry repository and configure Docker authentication outside the build. Use least-privilege writer permissions for the publishing principal.

```sh
export PROJECT_ID='<customer-project-id>'
export LOCATION='<artifact-registry-location>'
export REPOSITORY='<docker-repository>'
export IMAGE="${LOCATION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/auggie-bootstrap:node-22.23.1-auggie-0.32.0"

gcloud services enable artifactregistry.googleapis.com --project "${PROJECT_ID}"
gcloud artifacts repositories create "${REPOSITORY}" \
  --project "${PROJECT_ID}" --location "${LOCATION}" \
  --repository-format docker
gcloud auth configure-docker "${LOCATION}-docker.pkg.dev"

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg "ROCKY_BASE_IMAGE=${ROCKY_BASE_IMAGE}" \
  --build-arg "NODE_SHA256_AMD64=${NODE_SHA256_AMD64}" \
  --build-arg "NODE_SHA256_ARM64=${NODE_SHA256_ARM64}" \
  --tag "${IMAGE}" --push .
docker buildx imagetools inspect "${IMAGE}"
```

Deploy the resulting image by its pushed digest, not only its mutable tag.

### GCR-backed Artifact Registry migration

Google Container Registry is legacy. Prefer a regional Artifact Registry name (`LOCATION-docker.pkg.dev`) for new deployments. If the customer must preserve `gcr.io/PROJECT/IMAGE` names:

1. Complete Google's Container Registry-to-Artifact Registry migration for that project before publishing. A `gcr.io` hostname alone does not prove the backing repository was migrated.
2. Review repository location, IAM, retention/cleanup policies, vulnerability scanning, and service-agent access. Cloud Storage ACLs and Container Registry roles do not map one-for-one to Artifact Registry roles.
3. Authenticate Docker for the actual hostname (`gcr.io` or `LOCATION-docker.pkg.dev`), retag or copy by digest, and verify the destination digest before changing deployments.
4. Do not assume a regional Artifact Registry repository and a GCR-backed repository share images merely because they are in the same project.

Follow the current Google migration guide and use `gcloud artifacts docker upgrade migrate` only after reviewing its proposed IAM and repository changes. Do not pass service-account keys or access tokens as Docker build arguments.

## Image contract

The image runs as numeric UID/GID `65532:65532`. Its entrypoint is `/usr/local/bin/copy-runtime`, with `/runtime` as the default destination. One absolute destination argument or `RUNTIME_DEST` may override it.

The destination must:

- Use only letters, digits, `_`, `.`, `/`, and `-`, with no traversal or redundant path components.
- Have an existing, canonical, non-symlink parent.
- Be writable by the image's effective runtime UID/GID and empty on first
  initialization. The image default is `65532:65532`; Helm and Podman may safely
  override it when the shared volume is owned for that configured non-root user.
- Be dedicated to this runtime. Partial, foreign-version, symlinked, and concurrently initialized destinations are rejected.

The completion marker is written last. A repeated invocation with the same version is idempotent and reruns the preflight checks.

After a successful copy, the shared volume contains:

```text
/runtime/node/bin/node
/runtime/npm/bin/auggie -> ../lib/node_modules/@augmentcode/auggie/augment.mjs
/runtime/npm/lib/node_modules/@augmentcode/auggie/
/runtime/manifest.env
/runtime/.bootstrap-complete
```

The hardened customer container should mount the initialized volume read-only and set:

```sh
export PATH='/runtime/node/bin:/runtime/npm/bin:/usr/local/bin:/usr/bin:/bin'
exec /runtime/npm/bin/auggie --version
```

For Kubernetes `emptyDir`, use a pod-level `fsGroup` matching the configured
non-root runtime group (the supplied Helm chart defaults to `1000`). Give the
application container a read-only mount of the same volume. Do not run the
bootstrap image as root merely to work around an incorrectly owned volume.

## Smoke tests

The following Linux Docker test exercises the default non-root user, copy, preflight, PATH resolution, and CLI startup using a UID/GID-owned tmpfs:

```sh
IMAGE='auggie-bootstrap:node-22.23.1-auggie-0.32.0'
docker run --rm \
  --tmpfs /runtime:rw,uid=65532,gid=65532,mode=0755 \
  --entrypoint /bin/sh "${IMAGE}" -c \
  '/usr/local/bin/copy-runtime /runtime &&
   /usr/local/bin/preflight-runtime /runtime &&
   PATH=/runtime/node/bin:/runtime/npm/bin:/usr/bin:/bin auggie --version'
```

Confirm unsafe destinations fail closed:

```sh
if docker run --rm "${IMAGE}" '../runtime'; then
  echo 'ERROR: unsafe relative destination was accepted' >&2
  exit 1
fi
```

Finally, smoke-test the copied runtime inside the actual hardened Rocky 8 customer image with the shared volume mounted read-only. Verify `node --version` is exactly `v22.23.1`, `auggie --version` succeeds through the PATH above, and the application user cannot modify `/runtime`.