#!/usr/bin/env bash
#
# setup-auggie-daemon-linux.sh
# Creates a locked-down Linux system account, installs the Auggie CLI under it,
# links an Augment (Cosmos) Service Account credential, installs a hardened
# systemd service, and validates the OS-level security boundary end to end.
#
# Also works inside Windows WSL2 with systemd enabled (/etc/wsl.conf: [boot] systemd=true).
#
# Usage:   sudo ./setup-auggie-daemon-linux.sh
#          sudo ./setup-auggie-daemon-linux.sh --uninstall
#
# Non-interactive: set env vars before running (POOL_ID, SESSION_JSON_PATH,
# REPO_URL, SVC_USER, MAX_AGENTS, DAEMON_NAME, HARDENING=strict|full|off).
#
set -euo pipefail

SVC_USER="${SVC_USER:-svc-augment}"
SVC_HOME="/srv/augment"
WORKSPACE="${WORKSPACE:-${SVC_HOME}/workspace}"
# MAX_AGENTS: blank = daemon default (100); set a number to cap
DAEMON_NAME="${DAEMON_NAME:-$(hostname -s)-bridge-01}"
AUGGIE_VERSION="${AUGGIE_VERSION:-0.32.0}"
HARDENING="${HARDENING:-strict}"   # strict | full | off
UNIT="/etc/systemd/system/auggie-daemon.service"
SVCNAME="auggie-daemon"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }
info() { echo "==> $1"; }
die()  { echo "ERROR: $1" >&2; exit 1; }

validate_static_inputs() {
  [[ "${SVC_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "SVC_USER contains unsupported characters."
  case "${SVC_USER}" in root|nobody|daemon|bin|sys|sync|shutdown|halt) die "Refusing reserved SVC_USER '${SVC_USER}'." ;; esac
  [[ "${DAEMON_NAME}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die "DAEMON_NAME must use only letters, numbers, dot, underscore, and hyphen."
  [[ "${AUGGIE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die "AUGGIE_VERSION must be an exact version (for example 0.32.0)."
  case "${WORKSPACE}" in
    "${SVC_HOME}"/*) ;;
    *) die "WORKSPACE must remain below ${SVC_HOME}." ;;
  esac
  [[ "${WORKSPACE}" != *$'\n'* && "${WORKSPACE}" != *'/../'* && "${WORKSPACE}" != */.. ]] || die "WORKSPACE contains an unsafe path component."
}

validate_pool_id() {
  if [[ "${POOL_ID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    POOL_ID="pool-${POOL_ID}"
    warn "pool ID had no 'pool-' prefix; using ${POOL_ID}"
  fi
  [[ "${POOL_ID}" =~ ^pool-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || die "Pool ID must be pool- followed by a UUID."
}

invoking_user_home() {
  local caller="${SUDO_USER:-root}" home
  home=$(getent passwd "${caller}" | cut -d: -f6)
  [[ -n "${home}" ]] || home="${HOME:-/root}"
  printf '%s' "${home}"
}

read_session_json() {
  local target="$1" line
  : > "${target}"
  echo "Paste the pretty-printed session JSON (input hidden). Capture ends when valid JSON is complete:"
  while IFS= read -r -s line; do
    printf '%s\n' "${line}" >> "${target}"
    if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "${target}" 2>/dev/null; then
      echo
      return 0
    fi
    [[ $(wc -c < "${target}") -le 1048576 ]] || die "Pasted credential exceeds 1 MiB."
  done
  die "Credential paste ended before valid JSON was complete."
}

safe_workspace_name() {
  local name="$1"
  [[ -n "${name}" && "${name}" != "." && "${name}" != ".." && "${name}" != "/" && "${name}" != *$'\n'* ]] \
    || die "Workspace source has an unsafe destination name."
}

systemd_quote() {
  local value="$1"
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || die "A systemd argument contains a newline."
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//%/%%}
  printf '"%s"' "${value}"
}

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"
command -v systemctl >/dev/null || die "systemd not found. On WSL2, enable it in /etc/wsl.conf ([boot] systemd=true) and restart WSL."
validate_static_inputs
[[ ! -L "${SVC_HOME}" ]] || die "Refusing symlinked service home: ${SVC_HOME}"
WORKSPACE_REAL=$(realpath -m -- "${WORKSPACE}")
[[ "${WORKSPACE_REAL}" == "${SVC_HOME}/"* ]] || die "WORKSPACE resolves outside ${SVC_HOME}."
WORKSPACE="${WORKSPACE_REAL}"

if [[ "${1:-}" == "--uninstall" ]]; then
  info "Uninstalling..."
  systemctl disable --now "${SVCNAME}" 2>/dev/null || true
  rm -f "${UNIT}"; systemctl daemon-reload
  if id "${SVC_USER}" &>/dev/null; then
    SVC_UID=$(id -u "${SVC_USER}")
    ACCOUNT_HOME=$(getent passwd "${SVC_USER}" | cut -d: -f6)
    if [[ "${SVC_UID}" != "0" && "${ACCOUNT_HOME}" == "${SVC_HOME}" ]]; then
      userdel "${SVC_USER}" 2>/dev/null || true
    else
      warn "not deleting unexpected account ${SVC_USER} (uid=${SVC_UID}, home=${ACCOUNT_HOME})"
    fi
  fi
  read -r -p "Type DELETE to remove ${SVC_HOME} (workspace + credential), or press Enter to keep it: " confirm
  [[ "${confirm}" == "DELETE" ]] && rm -rf --one-file-system "${SVC_HOME}"
  echo "Uninstalled."; exit 0
fi

# ---------- preflight ----------
info "Preflight checks"
command -v node >/dev/null || die "Node.js not found. Install Node 22+ first."
command -v git  >/dev/null || die "git not found. Install it (apt/dnf install git)."
command -v npm  >/dev/null || die "npm not found."
NODE_MAJOR=$(node -e 'console.log(process.versions.node.split(".")[0])')
if   (( NODE_MAJOR < 20 )); then die "Node ${NODE_MAJOR} too old. Node 22+ required."
elif (( NODE_MAJOR < 22 )); then warn "Node ${NODE_MAJOR}; Node 22+ recommended."
else ok "Node ${NODE_MAJOR}"; fi

# ---------- inputs ----------
if [[ -z "${POOL_ID:-}" ]]; then
  read -r -p "Daemon pool ID (from Cosmos > Environments > your Daemon Pool): " POOL_ID
fi
[[ -n "${POOL_ID}" ]] || die "Pool ID is required."
validate_pool_id

SESSION_TMP="$(mktemp)"; trap 'rm -f "${SESSION_TMP}"' EXIT
if [[ -n "${SESSION_JSON_PATH:-}" ]]; then
  cp "${SESSION_JSON_PATH}" "${SESSION_TMP}"
else
  echo "Service Account credential (session.json downloaded from"
  echo "app.augmentcode.com/settings/service-accounts)."
  read -r -p "Path to session.json (blank to paste JSON instead): " SJ_PATH
  if [[ -n "${SJ_PATH}" ]]; then
    case "${SJ_PATH}" in \~|\~/*) SJ_PATH="$(invoking_user_home)${SJ_PATH:1}" ;; esac
    [[ -f "${SJ_PATH}" ]] || die "File not found: ${SJ_PATH}"
    cp "${SJ_PATH}" "${SESSION_TMP}"
  else
    read_session_json "${SESSION_TMP}"
  fi
fi

info "Validating credential format"
node -e '
  const fs = require("fs");
  let s;
  try { s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
  catch (e) { console.error("Not valid JSON: " + e.message); process.exit(1); }
  const p = [];
  if (!s.accessToken) p.push("missing accessToken");
  if (!s.tenantURL)   p.push("missing tenantURL");
  if (!Array.isArray(s.scopes)) p.push("scopes must be an array (e.g. [\"email\"]) - the CLI rejects the session without it");
  if (p.length) { console.error("Invalid session.json: " + p.join("; ")); process.exit(1); }
  console.log("  credential OK");
' "${SESSION_TMP}" || die "Credential validation failed."

# Max agents: Enter = keep daemon's own default (100)
if [[ -z "${MAX_AGENTS+x}" ]]; then
  read -r -p "Max concurrent agent sessions [Enter = daemon default (100); 4-5 recommended on 8-16GB hosts]: " MAX_AGENTS
fi
if [[ -n "${MAX_AGENTS}" ]]; then
  [[ "${MAX_AGENTS}" =~ ^[0-9]+$ ]] || die "Max agents must be a number or blank."
  (( 10#${MAX_AGENTS} > 0 )) || die "Max agents must be greater than zero."
else
  warn "using daemon default (100 slots); consider a cap on small hosts"
fi

# Workspaces: git URL (cloned) or existing local path (COPIED) or blank sandbox
WS_SOURCES=()
if [[ -n "${WORKSPACE_SRC+x}" ]]; then
  [[ -n "${WORKSPACE_SRC}" ]] && WS_SOURCES+=("${WORKSPACE_SRC}")
  if [[ -n "${EXTRA_WORKSPACES:-}" ]]; then
    IFS=',' read -r -a _extra <<< "${EXTRA_WORKSPACES}"
    for e in "${_extra[@]}"; do [[ -n "${e}" ]] && WS_SOURCES+=("${e}"); done
  fi
else
  echo
  echo "Workspaces: enter a git URL (cloned) OR an existing local path (COPIED"
  echo "into the service account's workspace; the original is not touched)."
  read -r -p "Primary workspace (git URL / local path / blank for sandbox): " FIRST
  [[ -n "${FIRST}" ]] && WS_SOURCES+=("${FIRST}")
  while true; do
    read -r -p "Add another workspace? (git URL / local path / blank to finish): " MORE
    [[ -z "${MORE}" ]] && break
    WS_SOURCES+=("${MORE}")
  done
fi

# ---------- service account ----------
info "Creating system account '${SVC_USER}' (home ${SVC_HOME})"
if id "${SVC_USER}" &>/dev/null; then
  SVC_UID=$(id -u "${SVC_USER}")
  ACCOUNT_HOME=$(getent passwd "${SVC_USER}" | cut -d: -f6)
  ACCOUNT_SHELL=$(getent passwd "${SVC_USER}" | cut -d: -f7)
  [[ "${SVC_UID}" != "0" ]] || die "Refusing to reuse uid 0 account ${SVC_USER}."
  [[ "${ACCOUNT_HOME}" == "${SVC_HOME}" ]] || die "Existing ${SVC_USER} home is ${ACCOUNT_HOME}, expected ${SVC_HOME}."
  [[ "${ACCOUNT_SHELL}" == */nologin || "${ACCOUNT_SHELL}" == */false ]] || die "Existing ${SVC_USER} has an interactive shell (${ACCOUNT_SHELL})."
  warn "verified existing locked-down account; reusing"
else
  useradd --system --create-home --home-dir "${SVC_HOME}" --shell /usr/sbin/nologin "${SVC_USER}"
  ok "created (system account, nologin shell, home outside /home)"
fi
systemctl stop "${SVCNAME}" 2>/dev/null || true
for protected_path in "${WORKSPACE}" "${SVC_HOME}/.augment" "${SVC_HOME}/.npm-global"; do
  [[ ! -L "${protected_path}" ]] || die "Refusing symlinked managed path: ${protected_path}"
done
mkdir -p "${WORKSPACE}" "${SVC_HOME}/.augment" "${SVC_HOME}/.npm-global"
chown -R "${SVC_USER}:${SVC_USER}" "${SVC_HOME}"
chmod 750 "${SVC_HOME}"
# Move into a directory the service account can read so sudo-spawned shells
# don't emit getcwd warnings when the installer runs from a 700 home dir.
cd "${SVC_HOME}"

# ---------- auggie ----------
# NOTE: commands run as ${SVC_USER} must cd into its own home first; the
# admin's cwd may be inside a 700 home dir, and npm fails on unreadable cwd.
info "Installing @augmentcode/auggie@${AUGGIE_VERSION} under ${SVC_USER}'s npm prefix"
chown -R "${SVC_USER}:${SVC_USER}" "${SVC_HOME}/.npm-global"
sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" npm config set prefix "${SVC_HOME}/.npm-global" --location=user
sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" npm install -g "@augmentcode/auggie@${AUGGIE_VERSION}" --loglevel=error \
  || die "auggie install failed."
AUGGIE_BIN="${SVC_HOME}/.npm-global/bin/auggie"
[[ -x "${AUGGIE_BIN}" ]] || die "auggie not found at ${AUGGIE_BIN}"
chown -R "root:${SVC_USER}" "${SVC_HOME}/.npm-global"
chmod -R u=rwX,g=rX,o= "${SVC_HOME}/.npm-global"
ok "auggie installed"

# ---------- materialize workspaces ----------
materialize_ws() {  # $1 = source; echoes destination
  local src="$1" name dest
  if [[ -d "${src}" ]]; then
    name=$(basename "${src}"); dest="${WORKSPACE}/${name}"
    safe_workspace_name "${name}"
    [[ ! -L "${dest}" ]] || die "Refusing symlinked workspace destination: ${dest}"
    if [[ ! -d "${dest}" ]]; then
      echo "    copying local path ${src} -> ${dest}" >&2
      cp -R "${src}" "${dest}"
      chown -R "${SVC_USER}:${SVC_USER}" "${dest}"
      if [[ ! -d "${dest}/.git" ]]; then
        sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${dest}" init -q
        sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${dest}" config user.email svc@localhost
        sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${dest}" config user.name "${SVC_USER}"
        sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${dest}" add -A
        sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${dest}" commit -qm import
      fi
    fi
  else
    name=$(basename "${src}" .git); dest="${WORKSPACE}/${name}"
    safe_workspace_name "${name}"
    [[ ! -L "${dest}" ]] || die "Refusing symlinked workspace destination: ${dest}"
    if [[ ! -d "${dest}" ]]; then
      echo "    cloning ${src} -> ${dest}" >&2
      sudo -u "${SVC_USER}" -H env -u GIT_SSH -u GIT_SSH_COMMAND HOME="${SVC_HOME}" \
        git -C "${SVC_HOME}" clone -- "${src}" "${dest}" \
        || die "git clone failed for ${src}"
    fi
  fi
  echo "${dest}"
}

WS_DIRS=()
if [[ ${#WS_SOURCES[@]} -eq 0 ]]; then
  REPO_DIR="${WORKSPACE}/sandbox"
  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git init -q "${REPO_DIR}"
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${REPO_DIR}" config user.email svc@localhost
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${REPO_DIR}" config user.name "${SVC_USER}"
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" sh -c 'printf "%s\n" "# sandbox" > "$1"' _ "${REPO_DIR}/README.md"
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${REPO_DIR}" add README.md
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${REPO_DIR}" commit -qm init
    warn "no workspace given; created empty sandbox repo"
  fi
  WS_DIRS+=("${REPO_DIR}")
else
  for src in "${WS_SOURCES[@]}"; do WS_DIRS+=("$(materialize_ws "${src}")"); done
fi
REPO_DIR="${WS_DIRS[0]}"

# ---------- credential ----------
info "Installing credential (0600)"
[[ ! -L "${SVC_HOME}/.augment/session.json" ]] || die "Refusing symlinked credential destination."
install -o "${SVC_USER}" -g "${SVC_USER}" -m 600 "${SESSION_TMP}" "${SVC_HOME}/.augment/session.json"

# ---------- systemd unit ----------
EXEC_ARGS=("${AUGGIE_BIN}" daemon --pool-id "${POOL_ID}" --augment-session-json "${SVC_HOME}/.augment/session.json" --workspace "${REPO_DIR}")
for ((i=1; i<${#WS_DIRS[@]}; i++)); do EXEC_ARGS+=(--add-workspace "${WS_DIRS[$i]}"); done
[[ -n "${MAX_AGENTS}" ]] && EXEC_ARGS+=(--max-agents "${MAX_AGENTS}")
EXEC_ARGS+=(--allow-indexing --name "${DAEMON_NAME}")
EXEC_START=""
for arg in "${EXEC_ARGS[@]}"; do EXEC_START+=" $(systemd_quote "${arg}")"; done
EXEC_START=${EXEC_START# }

info "Writing systemd unit (${HARDENING} hardening)"
HARDEN_BLOCK=""
case "${HARDENING}" in
  strict) HARDEN_BLOCK=$'NoNewPrivileges=yes\nProtectHome=yes\nProtectSystem=strict\nReadWritePaths='"${SVC_HOME}"$'\nPrivateTmp=yes\nRestrictSUIDSGID=yes' ;;
  full)   HARDEN_BLOCK=$'NoNewPrivileges=yes\nProtectHome=yes\nProtectSystem=full\nPrivateTmp=yes' ;;
  off)    HARDEN_BLOCK='' ;;
  *) die "HARDENING must be strict|full|off" ;;
esac

cat > "${UNIT}" <<UNITEOF
[Unit]
Description=Auggie Daemon (Cosmos, service account)
After=network-online.target
Wants=network-online.target

[Service]
User=${SVC_USER}
Group=${SVC_USER}
Environment=HOME=${SVC_HOME}
Environment=PATH=${SVC_HOME}/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=${REPO_DIR}
ExecStart=${EXEC_START}
Restart=always
RestartSec=5
UMask=0077
${HARDEN_BLOCK}

[Install]
WantedBy=multi-user.target
UNITEOF
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "${UNIT}" || die "Generated systemd unit failed validation."
fi
systemctl daemon-reload
systemctl enable --now "${SVCNAME}"

info "Waiting up to 90s for the daemon to register with Cosmos"
CONNECTED=0; REJECTED=""
for _ in $(seq 1 45); do
  LOGS=$(journalctl -u "${SVCNAME}" --no-pager -n 200 2>/dev/null || true)
  # 'WebSocket connected' is only the transport - do NOT treat it as success.
  if grep -qiE "unknown daemon pool" <<< "${LOGS}"; then
    REJECTED="pool not found: wrong pool ID, or the pool lives in a different tenant than the service account."
    break
  fi
  if grep -qiE "not the daemon pool connector" <<< "${LOGS}"; then
    REJECTED="identity rejected: the pool's connector is not this service account."
    break
  fi
  if grep -qiE "registered with poseidon|daemon registered|registered daemon" <<< "${LOGS}"; then
    CONNECTED=1; break
  fi
  sleep 2
done
if   [[ -n "${REJECTED}" ]]; then bad "daemon REJECTED by Cosmos - ${REJECTED}"
elif [[ ${CONNECTED} -eq 1 ]]; then ok "daemon REGISTERED with pool ${POOL_ID}"
else
  sleep 8
  LAST=$(journalctl -u "${SVCNAME}" --no-pager -n 5 2>/dev/null | grep -cE "WebSocket closed|Reconnecting" || true)
  if [[ "${LAST}" -gt 0 ]]; then
    bad "daemon is in a connect/close loop - check: journalctl -u ${SVCNAME} -n 30"
  else
    warn "no explicit registration line found but connection appears stable - verify the pool shows 1 daemon online in Cosmos"
  fi
fi

# ---------- validation ----------
echo; info "VALIDATION: OS boundary"
if groups "${SVC_USER}" | grep -qE '\b(sudo|wheel|admin)\b'; then bad "in a sudo/wheel group"; else ok "not in sudo/wheel/admin groups"; fi
if getent passwd "${SVC_USER}" | grep -qE '(nologin|false)$'; then ok "no interactive shell"; else bad "has an interactive shell"; fi

HOMES_BLOCKED=1
for h in /home/* /root; do
  [[ -d "$h" ]] || continue
  if sudo -u "${SVC_USER}" ls "$h" >/dev/null 2>&1; then
    bad "can list $h  ->  chmod 750 $h"; HOMES_BLOCKED=0
  fi
done
[[ ${HOMES_BLOCKED} -eq 1 ]] && ok "cannot read /root or any /home/* directory"

if sudo -u "${SVC_USER}" -H touch /usr/local/.boundary-test 2>/dev/null; then
  bad "can write to /usr/local"; rm -f /usr/local/.boundary-test
else ok "cannot write outside its tree"; fi
if sudo -u "${SVC_USER}" -H touch "${WORKSPACE}/.boundary-ok" 2>/dev/null; then
  ok "can write inside workspace"; rm -f "${WORKSPACE}/.boundary-ok"
else bad "cannot write inside workspace"; fi

if [[ "${HARDENING}" == "strict" ]]; then
  PROTECT_HOME=$(systemctl show -p ProtectHome --value "${SVCNAME}" 2>/dev/null || true)
  if [[ "${PROTECT_HOME}" == "yes" ]]; then ok "systemd ProtectHome=yes is active"; else bad "systemd ProtectHome is '${PROTECT_HOME:-unknown}', expected yes"; fi
fi

echo; info "VALIDATION: process, credential, network"
if systemctl is-active --quiet "${SVCNAME}"; then ok "service active"; else bad "service not active"; fi
MAINPID=$(systemctl show -p MainPID --value "${SVCNAME}")
if [[ -n "${MAINPID}" && "${MAINPID}" != "0" ]]; then
  PUSER=$(ps -o user= -p "${MAINPID}" | tr -d ' ')
  if [[ "${PUSER}" == "${SVC_USER}" ]]; then ok "daemon runs as ${SVC_USER}"; else bad "daemon runs as ${PUSER}"; fi
  # Only NON-loopback listeners are a network exposure; local 127.0.0.1/::1
  # listeners (Node IPC etc.) are unreachable from the network.
  ALL_LISTEN=$(ss -ltnp 2>/dev/null | grep "pid=${MAINPID}" | awk '{print $4}' || true)
  EXT_LISTEN=$(printf '%s\n' "${ALL_LISTEN}" | grep -vE '^(127\.0\.0\.1|\[::1\]):' | grep -v '^$' || true)
  if [[ -n "${EXT_LISTEN}" ]]; then
    bad "daemon listening on a NON-loopback address: $(echo "${EXT_LISTEN}" | tr '\n' ' ')"
  elif [[ -n "${ALL_LISTEN}" ]]; then
    ok "listeners are loopback-only ($(echo "${ALL_LISTEN}" | head -3 | tr '\n' ' ')) - not network-reachable"
  else
    ok "no listening ports at all (outbound-only)"
  fi
fi
PERMS=$(stat -c "%a" "${SVC_HOME}/.augment/session.json" 2>/dev/null || true)
if [[ "${PERMS}" == "600" ]]; then ok "credential is 0600"; else bad "credential perms ${PERMS:-unavailable}, expected 600"; fi

echo
echo "================================================================"
echo " RESULT: ${PASS} passed / ${FAIL} failed / ${WARN} warnings"
echo "================================================================"
cat <<NEXT

MANUAL CHECKS (require Cosmos):
 1. Pool page should show '1 daemon online' named '${DAEMON_NAME}'.
 2. Route a test session to the pool; ask it to run: ls /home
    Expected: empty or permission denied (with strict hardening: invisible).
 3. Session attribution should show the SERVICE ACCOUNT, not a person.
 4. From YOUR login: auggie daemon --pool-id ${POOL_ID} --name imposter-test
    Expected: "daemon user is not the daemon pool connector".

If agents fail with EROFS/EACCES writing outside ${SVC_HOME}: add
ReadWritePaths= entries to ${UNIT}, or rerun with HARDENING=full.

Ops:
  logs:      journalctl -u ${SVCNAME} -f
  restart:   sudo systemctl restart ${SVCNAME}
  uninstall: sudo $0 --uninstall
NEXT
[[ ${FAIL} -eq 0 ]] || exit 1