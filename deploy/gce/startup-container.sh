#!/usr/bin/env bash
# GCE startup script: rootless Podman on a customer Rocky Linux 8 VM image.

set -euo pipefail
umask 077
[[ ${EUID} -eq 0 ]] || { printf 'ERROR: startup-container.sh must run as root\n' >&2; exit 1; }

RUNTIME_DIR=/run/augment-gce
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install -d -o root -g root -m 0700 "${RUNTIME_DIR}"

if [[ -r "${SCRIPT_DIR}/lib/gce-common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/gce-common.sh"
else
  COMMON="${RUNTIME_DIR}/gce-common.sh"
  curl --fail --silent --show-error --connect-timeout 3 --max-time 15 \
    -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/attributes/augment-common-script' > "${COMMON}"
  chmod 0700 "${COMMON}"
  # shellcheck source=/dev/null
  source "${COMMON}"
  GCE_TEMP_FILES+=("${COMMON}")
fi
trap cleanup_gce_temp_files EXIT
prepare_runtime_dir
require_commands curl jq base64 stat awk grep getent cut podman runuser systemctl systemd-analyze install useradd passwd

config_get POOL_ID augment-pool-id
config_get SECRET_PROJECT_ID augment-secret-project-id
config_get SESSION_SECRET_ID augment-session-secret-id
config_get SESSION_SECRET_VERSION augment-session-secret-version latest
config_get RUNTIME_IMAGE augment-runtime-image
config_get BOOTSTRAP_IMAGE augment-bootstrap-image
config_get MAX_AGENTS augment-max-agents 4
config_get DAEMON_NAME augment-daemon-name "$(hostname -s)-bridge-01"
config_get MEMORY_LIMIT augment-memory-limit 6g
config_get CPU_LIMIT augment-cpu-limit 2
config_get PIDS_LIMIT augment-pids-limit 512

validate_pool_id "${POOL_ID}"
validate_daemon_name "${DAEMON_NAME}"
[[ "${MAX_AGENTS}" =~ ^[1-9][0-9]*$ ]] || die "MAX_AGENTS must be a positive integer"
[[ "${MEMORY_LIMIT}" =~ ^[1-9][0-9]*[mMgG]$ ]] || die "MEMORY_LIMIT must look like 4096m or 6g"
[[ "${CPU_LIMIT}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "CPU_LIMIT must be numeric"
[[ "${PIDS_LIMIT}" =~ ^[1-9][0-9]*$ ]] || die "PIDS_LIMIT must be a positive integer"
IMAGE_PATTERN='^([a-z0-9-]+\.)?(pkg\.dev|gcr\.io)/[A-Za-z0-9._/@:-]+@sha256:[0-9a-f]{64}$'
[[ "${RUNTIME_IMAGE}" =~ ${IMAGE_PATTERN} ]] \
  || die "RUNTIME_IMAGE must be an Artifact Registry or gcr.io image pinned by sha256 digest"
[[ "${BOOTSTRAP_IMAGE}" =~ ${IMAGE_PATTERN} ]] \
  || die "BOOTSTRAP_IMAGE must be an Artifact Registry or gcr.io image pinned by sha256 digest"

SERVICE_USER=svc-auggie-container
SERVICE_HOME=/srv/augment-container
DATA_DIR=/var/lib/auggie-container
if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
  useradd --create-home --home-dir "${SERVICE_HOME}" --shell /usr/sbin/nologin "${SERVICE_USER}"
fi
passwd --lock "${SERVICE_USER}" >/dev/null
SERVICE_UID=$(id -u "${SERVICE_USER}")
SERVICE_GID=$(id -g "${SERVICE_USER}")
[[ "${SERVICE_UID}" != 0 ]] || die "Container service account must not be root"
[[ $(getent passwd "${SERVICE_USER}" | cut -d: -f6) == "${SERVICE_HOME}" ]] \
  || die "Container service account has an unexpected home"
[[ $(getent passwd "${SERVICE_USER}" | cut -d: -f7) == */nologin ]] \
  || die "Container service account must have a nologin shell"
! id -nG "${SERVICE_USER}" | grep -Eq '(^| )(wheel|sudo|admin)( |$)' \
  || die "Container service account belongs to a privileged group"
if ! grep -q "^${SERVICE_USER}:" /etc/subuid || ! grep -q "^${SERVICE_USER}:" /etc/subgid; then
  die "Rootless Podman requires subordinate UID and GID ranges"
fi
install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0750 \
  "${SERVICE_HOME}" "${DATA_DIR}" "${DATA_DIR}/workspace" "${DATA_DIR}/state" \
  "${DATA_DIR}/runtime"
install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0700 /run/augment-podman
SESSION_RUNTIME_DIR=/run/augment-session
install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0700 "${SESSION_RUNTIME_DIR}"

SESSION_TMP="${RUNTIME_DIR}/session.json"
fetch_session_secret "${SECRET_PROJECT_ID}" "${SESSION_SECRET_ID}" "${SESSION_SECRET_VERSION}" "${SESSION_TMP}"
install -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0600 \
  "${SESSION_TMP}" "${SESSION_RUNTIME_DIR}/session.json"

AUTH_FILE=/run/augment-podman/auth.json
fetch_access_token
TOKEN_JSON="${ACCESS_TOKEN_FILE}"
touch "${AUTH_FILE}"
chown "${SERVICE_USER}:${SERVICE_USER}" "${AUTH_FILE}"
chmod 0600 "${AUTH_FILE}"
GCE_TEMP_FILES+=("${AUTH_FILE}")
for IMAGE in "${RUNTIME_IMAGE}" "${BOOTSTRAP_IMAGE}"; do
  REGISTRY=${IMAGE%%/*}
  jq -r '.access_token' "${TOKEN_JSON}" | runuser -u "${SERVICE_USER}" -- env \
    HOME="${SERVICE_HOME}" XDG_RUNTIME_DIR=/run/augment-podman \
    REGISTRY_AUTH_FILE="${AUTH_FILE}" \
    podman login --tls-verify=true --username oauth2accesstoken --password-stdin "${REGISTRY}" >/dev/null
  runuser -u "${SERVICE_USER}" -- env HOME="${SERVICE_HOME}" XDG_RUNTIME_DIR=/run/augment-podman \
    REGISTRY_AUTH_FILE="${AUTH_FILE}" podman pull --quiet "${IMAGE}" >/dev/null
done

systemctl stop auggie-daemon-container.service 2>/dev/null || true
runuser -u "${SERVICE_USER}" -- env HOME="${SERVICE_HOME}" XDG_RUNTIME_DIR=/run/augment-podman \
  podman run --rm --pull=never --read-only --network=none \
  --security-opt=no-new-privileges --cap-drop=ALL --userns=keep-id \
  --user="${SERVICE_UID}:${SERVICE_GID}" --pids-limit=64 --memory=512m --cpus=1 \
  --tmpfs=/tmp:rw,noexec,nosuid,nodev,size=64m \
  --volume="${DATA_DIR}/runtime:/runtime:rw,Z" "${BOOTSTRAP_IMAGE}" >/dev/null
[[ -x "${DATA_DIR}/runtime/npm/bin/auggie" ]] || die "Shared runtime bootstrap failed"
[[ -x "${DATA_DIR}/runtime/node/bin/node" ]] || die "Shared Node runtime bootstrap failed"

UNIT=/etc/systemd/system/auggie-daemon-container.service
cat > "${UNIT}" <<EOF
[Unit]
Description=Auggie daemon in rootless Podman
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=${SERVICE_HOME}
Environment=XDG_RUNTIME_DIR=/run/augment-podman
RuntimeDirectory=augment-podman augment-session
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
WorkingDirectory=${DATA_DIR}/workspace
ExecStartPre=-/usr/bin/podman rm --force auggie-daemon
ExecStart=/usr/bin/podman run --name auggie-daemon --pull=never --read-only --security-opt=no-new-privileges --cap-drop=ALL --userns=keep-id --user=${SERVICE_UID}:${SERVICE_GID} --pids-limit=${PIDS_LIMIT} --memory=${MEMORY_LIMIT} --cpus=${CPU_LIMIT} --log-driver=journald --tmpfs=/tmp:rw,noexec,nosuid,nodev,size=256m --tmpfs=/run:rw,noexec,nosuid,nodev,size=64m --volume=${DATA_DIR}/runtime:/opt/auggie:ro,Z --volume=${DATA_DIR}/workspace:/workspace:rw,Z --volume=${DATA_DIR}/state:/home/auggie:rw,Z --volume=${SESSION_RUNTIME_DIR}/session.json:/run/augment-session.json:ro,Z --env=HOME=/home/auggie --env=PATH=/opt/auggie/node/bin:/opt/auggie/npm/bin:/usr/local/bin:/usr/bin:/bin --workdir=/workspace --entrypoint=/opt/auggie/npm/bin/auggie ${RUNTIME_IMAGE} daemon --pool-id ${POOL_ID} --workspace /workspace --max-agents ${MAX_AGENTS} --allow-indexing --name ${DAEMON_NAME} --augment-session-json /run/augment-session.json
ExecStop=-/usr/bin/podman stop --time 30 auggie-daemon
ExecStopPost=-/usr/bin/podman rm --force auggie-daemon
Restart=always
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=45
UMask=0077
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
LockPersonality=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=no
ReadWritePaths=${SERVICE_HOME} ${DATA_DIR} /run/augment-podman ${SESSION_RUNTIME_DIR}
Delegate=yes

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "${UNIT}"
systemd-analyze verify "${UNIT}"
systemctl daemon-reload
systemctl enable auggie-daemon-container.service
systemctl restart auggie-daemon-container.service
systemctl is-active --quiet auggie-daemon-container.service \
  || die "Container service did not become active"
printf 'Rootless Podman Auggie deployment completed. Secret content is not logged.\n'