#!/usr/bin/env bash
# GCE startup script: direct Rocky Linux 8 host installation.

set -euo pipefail
umask 077
[[ ${EUID} -eq 0 ]] || { printf 'ERROR: startup-direct.sh must run as root\n' >&2; exit 1; }

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
require_commands curl jq base64 stat awk sed grep node npm git sudo systemctl

config_get POOL_ID augment-pool-id
config_get SECRET_PROJECT_ID augment-secret-project-id
config_get SESSION_SECRET_ID augment-session-secret-id
config_get SESSION_SECRET_VERSION augment-session-secret-version latest
config_get MAX_AGENTS augment-max-agents 4
config_get AUGGIE_VERSION augment-auggie-version 0.32.0
config_get DAEMON_NAME augment-daemon-name "$(hostname -s)-bridge-01"

validate_pool_id "${POOL_ID}"
validate_daemon_name "${DAEMON_NAME}"
[[ "${MAX_AGENTS}" =~ ^[1-9][0-9]*$ ]] || die "MAX_AGENTS must be a positive integer"
[[ "${AUGGIE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die "AUGGIE_VERSION must be exact"
(( $(node -p 'Number(process.versions.node.split(".")[0])') >= 22 )) || die "Node.js 22 or newer is required"

SESSION_TMP="${RUNTIME_DIR}/session.json"
fetch_session_secret "${SECRET_PROJECT_ID}" "${SESSION_SECRET_ID}" "${SESSION_SECRET_VERSION}" "${SESSION_TMP}"

INSTALLER="${RUNTIME_DIR}/setup-auggie-daemon-linux.sh"
if [[ -r "${SCRIPT_DIR}/../../setup-auggie-daemon-linux.sh" ]]; then
  cp -- "${SCRIPT_DIR}/../../setup-auggie-daemon-linux.sh" "${INSTALLER}"
else
  metadata_get augment-linux-installer > "${INSTALLER}"
fi
chmod 0700 "${INSTALLER}"
GCE_TEMP_FILES+=("${INSTALLER}")

grep -F -- "--augment-session-json \"\${SVC_HOME}/.augment/session.json\"" "${INSTALLER}" >/dev/null \
  || die "Installer must pass the explicit Augment credential path"

printf 'Installing Auggie daemon directly on the host. Secret content is not logged.\n'
POOL_ID="${POOL_ID}" \
SESSION_JSON_PATH="${SESSION_TMP}" \
WORKSPACE_SRC='' \
EXTRA_WORKSPACES='' \
SVC_USER='svc-augment' \
MAX_AGENTS="${MAX_AGENTS}" \
DAEMON_NAME="${DAEMON_NAME}" \
AUGGIE_VERSION="${AUGGIE_VERSION}" \
HARDENING='strict' \
TMPDIR="${RUNTIME_DIR}" \
  "${INSTALLER}"

grep -F -- '--augment-session-json' /etc/systemd/system/auggie-daemon.service >/dev/null \
  || die "Installed service is missing --augment-session-json"
printf 'Direct-host Auggie deployment completed.\n'