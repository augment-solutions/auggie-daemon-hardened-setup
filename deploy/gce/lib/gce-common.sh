#!/usr/bin/env bash
# Shared GCE metadata and Secret Manager helpers. This file must not print secrets.

set -euo pipefail

METADATA_ROOT="http://metadata.google.internal/computeMetadata/v1"
RUNTIME_DIR="${RUNTIME_DIR:-/run/augment-gce}"
CONFIG_FILE="${CONFIG_FILE:-/etc/augment-gce/config.env}"
declare -a GCE_TEMP_FILES=()
ACCESS_TOKEN_FILE=''

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null 2>&1 || die "Required command not found: ${command_name}"
  done
}

prepare_runtime_dir() {
  umask 077
  install -d -o root -g root -m 0700 "${RUNTIME_DIR}"
}

cleanup_gce_temp_files() {
  local path
  for path in "${GCE_TEMP_FILES[@]:-}"; do
    [[ -n "${path}" ]] && rm -f -- "${path}"
  done
}

metadata_get() {
  local attribute="$1"
  [[ "${attribute}" =~ ^[a-z0-9-]+$ ]] || die "Invalid metadata attribute name"
  curl --fail --silent --show-error --connect-timeout 3 --max-time 15 \
    -H 'Metadata-Flavor: Google' \
    "${METADATA_ROOT}/instance/attributes/${attribute}"
}

verify_config_file() {
  local owner mode
  [[ -f "${CONFIG_FILE}" && ! -L "${CONFIG_FILE}" ]] || die "Config must be a regular, non-symlink file"
  owner=$(stat -c '%U' "${CONFIG_FILE}")
  mode=$(stat -c '%a' "${CONFIG_FILE}")
  [[ "${owner}" == "root" ]] || die "Config must be owned by root"
  (( (8#${mode} & 8#022) == 0 )) || die "Config must not be group/world writable"
  awk '
    BEGIN {
      split("POOL_ID SECRET_PROJECT_ID SESSION_SECRET_ID SESSION_SECRET_VERSION MAX_AGENTS DAEMON_NAME AUGGIE_VERSION RUNTIME_IMAGE BOOTSTRAP_IMAGE MEMORY_LIMIT CPU_LIMIT PIDS_LIMIT", allowed_keys)
      for (i in allowed_keys) allowed[allowed_keys[i]] = 1
    }
    /^[[:space:]]*(#|$)/ { next }
    /^[A-Z][A-Z0-9_]*=[^\r\n]*$/ {
      key = $0
      sub(/=.*/, "", key)
      if (allowed[key]) next
    }
    { exit 1 }
  ' "${CONFIG_FILE}" || die "Config contains an invalid line"
}

config_get() {
  local variable_name="$1" attribute="$2" default_value="${3-}" value count
  if [[ -e "${CONFIG_FILE}" ]]; then
    verify_config_file
    count=$(awk -F= -v key="${variable_name}" '$1 == key { count++ } END { print count + 0 }' "${CONFIG_FILE}")
    (( count <= 1 )) || die "Config contains duplicate ${variable_name} entries"
    if (( count == 1 )); then
      value=$(awk -F= -v key="${variable_name}" '$1 == key { sub(/^[^=]*=/, ""); print }' "${CONFIG_FILE}")
    else
      value="${default_value}"
    fi
  else
    value=$(metadata_get "${attribute}" 2>/dev/null || printf '%s' "${default_value}")
  fi
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || die "${variable_name} contains a newline"
  printf -v "${variable_name}" '%s' "${value}"
}

fetch_access_token() {
  local token_json="${RUNTIME_DIR}/metadata-token.json"
  curl --fail --silent --show-error --connect-timeout 3 --max-time 15 \
    -H 'Metadata-Flavor: Google' \
    "${METADATA_ROOT}/instance/service-accounts/default/token" > "${token_json}"
  chmod 0600 "${token_json}"
  GCE_TEMP_FILES+=("${token_json}")
  jq -e '(.access_token | type == "string" and length > 0) and
    (.token_type == "Bearer") and (.expires_in | type == "number" and . > 0)' \
    "${token_json}" >/dev/null || die "Metadata server returned an invalid OAuth response"
  ACCESS_TOKEN_FILE="${token_json}"
}

fetch_session_secret() {
  local project_id="$1" secret_id="$2" version="$3" destination="$4"
  local token_json curl_config response token
  [[ "${project_id}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "Invalid Secret Manager project ID"
  [[ "${secret_id}" =~ ^[A-Za-z0-9_-]{1,255}$ ]] || die "Invalid Secret Manager secret ID"
  [[ "${version}" == "latest" || "${version}" =~ ^[1-9][0-9]*$ ]] || die "Invalid secret version"

  fetch_access_token
  token_json="${ACCESS_TOKEN_FILE}"
  curl_config="${RUNTIME_DIR}/secret-curl.conf"
  response="${RUNTIME_DIR}/secret-response.json"
  token=$(jq -r '.access_token' "${token_json}")
  printf 'header = "Authorization: Bearer %s"\n' "${token}" > "${curl_config}"
  chmod 0600 "${curl_config}"
  unset token
  GCE_TEMP_FILES+=("${curl_config}" "${response}" "${destination}")

  curl --config "${curl_config}" --fail --silent --show-error \
    --connect-timeout 5 --max-time 30 --output "${response}" \
    "https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${secret_id}/versions/${version}:access"
  chmod 0600 "${response}"
  jq -e '.payload.data | type == "string" and length > 0' "${response}" >/dev/null \
    || die "Secret Manager returned an invalid response"
  jq -r '.payload.data' "${response}" | base64 --decode > "${destination}" \
    || die "Secret Manager payload is not valid base64"
  chmod 0600 "${destination}"
  (( $(stat -c '%s' "${destination}") <= 1048576 )) || die "session.json exceeds 1 MiB"
  jq -e 'type == "object" and
    (.accessToken | type == "string" and length > 0) and
    (.tenantURL | type == "string" and test("^https://[^[:space:]]+$")) and
    (.scopes | type == "array") and all(.scopes[]; type == "string")' \
    "${destination}" >/dev/null \
    || die "Secret payload is not a valid Augment session.json"
}

validate_pool_id() {
  [[ "$1" =~ ^pool-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || die "POOL_ID must be pool- followed by a UUID"
}

validate_daemon_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die "DAEMON_NAME contains unsupported characters"
}