# syntax=docker/dockerfile:1.7

ARG ROCKY_BASE_IMAGE

FROM ${ROCKY_BASE_IMAGE} AS builder

ARG ROCKY_BASE_IMAGE
ARG TARGETARCH
ARG NODE_SHA256_AMD64
ARG NODE_SHA256_ARM64

ENV HOME=/home/bootstrap \
    NODE_VERSION=22.23.1 \
    AUGGIE_VERSION=0.32.0

RUN set -eu; \
    case "${ROCKY_BASE_IMAGE}" in \
        *@sha256:*) rocky_digest=${ROCKY_BASE_IMAGE##*@sha256:} ;; \
        *) echo "ROCKY_BASE_IMAGE must be pinned by SHA256 digest" >&2; exit 1 ;; \
    esac; \
    [ "${#rocky_digest}" -eq 64 ] \
        || { echo "Rocky base digest must be 64 lowercase hex characters" >&2; exit 1; }; \
    case "${rocky_digest}" in \
        *[!0-9a-f]*) echo "Invalid Rocky base digest" >&2; exit 1 ;; \
    esac

RUN set -eu; \
    packages='ca-certificates curl gcc-c++ make python3 shadow-utils tar xz'; \
    if command -v microdnf >/dev/null 2>&1; then \
        microdnf install -y ${packages}; \
        microdnf clean all; \
    elif command -v dnf >/dev/null 2>&1; then \
        dnf install -y ${packages}; \
        dnf clean all; \
    else \
        echo "Rocky builder image must contain dnf or microdnf" >&2; exit 1; \
    fi; \
    rm -rf /var/cache/dnf /var/cache/yum

RUN groupadd --gid 10001 bootstrap \
    && useradd --uid 10001 --gid 10001 --create-home \
        --home-dir /home/bootstrap --shell /sbin/nologin bootstrap \
    && install -d -o bootstrap -g bootstrap /work

USER 10001:10001
WORKDIR /work

RUN set -eu; \
    for checksum in "${NODE_SHA256_AMD64}" "${NODE_SHA256_ARM64}"; do \
        [ "${#checksum}" -eq 64 ] || { echo "Node SHA256 build args must be 64 lowercase hex characters" >&2; exit 1; }; \
        case "${checksum}" in *[!0-9a-f]*) echo "Invalid Node SHA256 build arg" >&2; exit 1;; esac; \
    done; \
    case "${TARGETARCH}" in \
        amd64) node_arch=x64; node_sha256="${NODE_SHA256_AMD64}" ;; \
        arm64) node_arch=arm64; node_sha256="${NODE_SHA256_ARM64}" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH:-unset}" >&2; exit 1 ;; \
    esac; \
    archive="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    url="https://nodejs.org/download/release/v${NODE_VERSION}/${archive}"; \
    curl --proto '=https' --tlsv1.2 --fail --show-error --location \
        --retry 3 --output "${archive}" "${url}"; \
    printf '%s  %s\n' "${node_sha256}" "${archive}" | sha256sum --check --strict -; \
    mkdir -p runtime/node runtime/npm; \
    tar -xJf "${archive}" -C runtime/node --strip-components=1; \
    rm -f "${archive}"; \
    export PATH="/work/runtime/node/bin:${PATH}"; \
    npm_config_nodedir=/work/runtime/node \
        npm install --global --prefix /work/runtime/npm --omit=dev \
        --no-audit --no-fund --loglevel=warn "@augmentcode/auggie@${AUGGIE_VERSION}"; \
    npm cache clean --force; \
    rm -rf "${HOME}/.npm" "${HOME}/.cache"; \
    [ "$(runtime/node/bin/node --version)" = "v${NODE_VERSION}" ]; \
    runtime/node/bin/node -e 'const p=require("/work/runtime/npm/lib/node_modules/@augmentcode/auggie/package.json");if(p.name!=="@augmentcode/auggie"||p.version!==process.argv[1])process.exit(1)' "${AUGGIE_VERSION}"; \
    PATH="/work/runtime/node/bin:/work/runtime/npm/bin:/usr/bin:/bin" \
        runtime/npm/bin/auggie --version >/dev/null; \
    printf 'NODE_VERSION=%s\nAUGGIE_VERSION=%s\nTARGETARCH=%s\n' \
        "${NODE_VERSION}" "${AUGGIE_VERSION}" "${TARGETARCH}" > runtime/manifest.env; \
    chmod -R a-w runtime

FROM ${ROCKY_BASE_IMAGE} AS bootstrap

ENV HOME=/tmp \
    NODE_VERSION=22.23.1 \
    AUGGIE_VERSION=0.32.0

COPY --from=builder --chown=65532:65532 /work/runtime /opt/auggie-runtime
COPY scripts/preflight.sh /usr/local/bin/preflight-runtime
COPY scripts/copy-runtime.sh /usr/local/bin/copy-runtime

RUN set -eu; \
    for utility in cat chmod cp env mkdir mv readlink rm rmdir uname; do \
        command -v "${utility}" >/dev/null; \
    done; \
    chmod 0555 /usr/local/bin/preflight-runtime /usr/local/bin/copy-runtime; \
    /usr/local/bin/preflight-runtime /opt/auggie-runtime

LABEL org.opencontainers.image.title="Auggie bootstrap runtime" \
      org.opencontainers.image.description="Copies pinned Node 22 and Auggie into a shared volume" \
      org.opencontainers.image.version="node-22.23.1-auggie-0.32.0"

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/copy-runtime"]
CMD ["/runtime"]