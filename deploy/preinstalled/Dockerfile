# syntax=docker/dockerfile:1.7

ARG BOOTSTRAP_IMAGE
ARG ROCKY_BASE_IMAGE

FROM ${BOOTSTRAP_IMAGE} AS runtime

FROM ${ROCKY_BASE_IMAGE}

ARG BOOTSTRAP_IMAGE
ARG ROCKY_BASE_IMAGE

ENV HOME=/home/auggie \
    PATH=/opt/auggie-runtime/node/bin:/opt/auggie-runtime/npm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NODE_VERSION=22.23.1 \
    AUGGIE_VERSION=0.32.0

RUN set -eu; \
    for image in "${ROCKY_BASE_IMAGE}" "${BOOTSTRAP_IMAGE}"; do \
        digest=${image##*@sha256:}; \
        [ "${digest}" != "${image}" ] && [ "${#digest}" -eq 64 ] \
            || { echo "base images must be pinned by SHA256 digest" >&2; exit 1; }; \
        case "${digest}" in *[!0-9a-f]*) echo "invalid image digest" >&2; exit 1;; esac; \
    done; \
    microdnf install -y ca-certificates git openssh-clients shadow-utils; \
    microdnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum; \
    groupadd --gid 1000 auggie; \
    useradd --uid 1000 --gid 1000 --create-home \
        --home-dir /home/auggie --shell /sbin/nologin auggie

COPY --from=runtime --chown=1000:1000 /opt/auggie-runtime /opt/auggie-runtime
COPY --from=runtime /usr/local/bin/preflight-runtime /usr/local/bin/preflight-runtime

RUN set -eu; \
    chmod 0555 /usr/local/bin/preflight-runtime; \
    chmod -R a-w /opt/auggie-runtime; \
    command -v git >/dev/null; \
    test -f /etc/pki/tls/certs/ca-bundle.crt

USER 1000:1000
WORKDIR /workspace

RUN /usr/local/bin/preflight-runtime /opt/auggie-runtime

LABEL org.opencontainers.image.title="Preinstalled Auggie runtime" \
      org.opencontainers.image.description="Pinned Rocky 8, Node, and Auggie control runtime" \
      org.opencontainers.image.version="node-22.23.1-auggie-0.32.0"

ENTRYPOINT ["auggie"]
CMD ["--version"]