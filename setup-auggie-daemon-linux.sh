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
HARDENING="${HARDENING:-strict}"   # strict | full | off
UNIT="/etc/systemd/system/auggie-daemon.service"
SVCNAME="auggie-daemon"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }
info() { echo "==> $1"; }
die()  { echo "ERROR: $1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"
command -v systemctl >/dev/null || die "systemd not found. On WSL2, enable it in /etc/wsl.conf ([boot] systemd=true) and restart WSL."

if [[ "${1:-}" == "--uninstall" ]]; then
  info "Uninstalling..."
  systemctl disable --now "${SVCNAME}" 2>/dev/null || true
  rm -f "${UNIT}"; systemctl daemon-reload
  id "${SVC_USER}" &>/dev/null && userdel "${SVC_USER}" 2>/dev/null || true
  read -r -p "Delete ${SVC_HOME} (workspace + credential)? [y/N] " yn
  [[ "${yn}" == "y" ]] && rm -rf "${SVC_HOME}"
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
# Normalize: Cosmos pool IDs carry a 'pool-' prefix; auto-add it for bare UUIDs.
if [[ "${POOL_ID}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  POOL_ID="pool-${POOL_ID}"
  warn "pool ID had no 'pool-' prefix; using ${POOL_ID}"
fi

SESSION_TMP="$(mktemp)"; trap 'rm -f "${SESSION_TMP}"' EXIT
if [[ -n "${SESSION_JSON_PATH:-}" ]]; then
  cp "${SESSION_JSON_PATH}" "${SESSION_TMP}"
else
  echo "Service Account credential (session.json downloaded from"
  echo "app.augmentcode.com/settings/service-accounts)."
  read -r -p "Path to session.json (blank to paste JSON instead): " SJ_PATH
  if [[ -n "${SJ_PATH}" ]]; then
    SJ_PATH="${SJ_PATH/#\~/$HOME}"
    [[ -f "${SJ_PATH}" ]] || die "File not found: ${SJ_PATH}"
    cp "${SJ_PATH}" "${SESSION_TMP}"
  else
    echo "Paste the session JSON on one line (input hidden), then Enter:"
    read -r -s SJ_INLINE; printf '%s' "${SJ_INLINE}" > "${SESSION_TMP}"; unset SJ_INLINE
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
  console.log("  credential OK (tenant: " + s.tenantURL + ")");
' "${SESSION_TMP}" || die "Credential validation failed."

# Max agents: Enter = keep daemon's own default (100)
if [[ -z "${MAX_AGENTS+x}" ]]; then
  read -r -p "Max concurrent agent sessions [Enter = daemon default (100); 4-5 recommended on 8-16GB hosts]: " MAX_AGENTS
fi
if [[ -n "${MAX_AGENTS}" ]]; then
  [[ "${MAX_AGENTS}" =~ ^[0-9]+$ ]] || die "Max agents must be a number or blank."
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
  warn "user exists; reusing"
else
  useradd --system --create-home --home-dir "${SVC_HOME}" --shell /usr/sbin/nologin "${SVC_USER}"
  ok "created (system account, nologin shell, home outside /home)"
fi
mkdir -p "${WORKSPACE}" "${SVC_HOME}/.augment" "${SVC_HOME}/.npm-global"
chown -R "${SVC_USER}:${SVC_USER}" "${SVC_HOME}"
chmod 750 "${SVC_HOME}"
# Move into a directory the service account can read so sudo-spawned shells
# don't emit getcwd warnings when the installer runs from a 700 home dir.
cd "${SVC_HOME}"

# ---------- auggie ----------
# NOTE: commands run as ${SVC_USER} must cd into its own home first; the
# admin's cwd may be inside a 700 home dir, and npm fails on unreadable cwd.
info "Installing @augmentcode/auggie under ${SVC_USER}'s npm prefix"
sudo -u "${SVC_USER}" -H bash -c "
  cd '${SVC_HOME}'
  export HOME='${SVC_HOME}'
  npm config set prefix '${SVC_HOME}/.npm-global' --location=user
  npm install -g @augmentcode/auggie --loglevel=error
" || die "auggie install failed."
AUGGIE_BIN="${SVC_HOME}/.npm-global/bin/auggie"
[[ -x "${AUGGIE_BIN}" ]] || die "auggie not found at ${AUGGIE_BIN}"
ok "auggie installed"

# ---------- materialize workspaces ----------
materialize_ws() {  # $1 = source; echoes destination
  local src="$1" name dest
  if [[ -d "${src}" ]]; then
    name=$(basename "${src}"); dest="${WORKSPACE}/${name}"
    if [[ ! -d "${dest}" ]]; then
      echo "    copying local path ${src} -> ${dest}" >&2
      cp -R "${src}" "${dest}"
      chown -R "${SVC_USER}:${SVC_USER}" "${dest}"
      if [[ ! -d "${dest}/.git" ]]; then
        sudo -u "${SVC_USER}" -H bash -c "
          cd '${dest}' && git init -q && git config user.email 'svc@localhost' &&
          git config user.name '${SVC_USER}' && git add -A && git commit -qm import"
      fi
    fi
  else
    name=$(basename "${src}" .git); dest="${WORKSPACE}/${name}"
    if [[ ! -d "${dest}" ]]; then
      echo "    cloning ${src} -> ${dest}" >&2
      sudo -u "${SVC_USER}" -H bash -c "cd '${SVC_HOME}' && git clone '${src}' '${dest}'" \
        || die "git clone failed for ${src}"
    fi
  fi
  echo "${dest}"
}

WS_DIRS=()
if [[ ${#WS_SOURCES[@]} -eq 0 ]]; then
  REPO_DIR="${WORKSPACE}/sandbox"
  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    sudo -u "${SVC_USER}" -H bash -c "
      cd '${SVC_HOME}' &&
      git init -q '${REPO_DIR}' && cd '${REPO_DIR}' &&
      git config user.email 'svc@localhost' && git config user.name 'svc-augment' &&
      echo '# sandbox' > README.md && git add . && git commit -qm init"
    warn "no workspace given; created empty sandbox repo"
  fi
  WS_DIRS+=("${REPO_DIR}")
else
  for src in "${WS_SOURCES[@]}"; do WS_DIRS+=("$(materialize_ws "${src}")"); done
fi
REPO_DIR="${WS_DIRS[0]}"

# ---------- credential ----------
info "Installing credential (0600)"
install -o "${SVC_USER}" -g "${SVC_USER}" -m 600 "${SESSION_TMP}" "${SVC_HOME}/.augment/session.json"

# ---------- systemd unit ----------
ADD_WS_ARGS=""
for ((i=1; i<${#WS_DIRS[@]}; i++)); do ADD_WS_ARGS+=" --add-workspace ${WS_DIRS[$i]}"; done
MAX_AGENTS_ARG=""
[[ -n "${MAX_AGENTS}" ]] && MAX_AGENTS_ARG=" --max-agents ${MAX_AGENTS}"

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
ExecStart=${AUGGIE_BIN} daemon --pool-id ${POOL_ID} --workspace ${REPO_DIR}${ADD_WS_ARGS}${MAX_AGENTS_ARG} --allow-indexing --name ${DAEMON_NAME}
Restart=always
RestartSec=5
${HARDEN_BLOCK}

[Install]
WantedBy=multi-user.target
UNITEOF
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
groups "${SVC_USER}" | grep -qE '\b(sudo|wheel|admin)\b' \
  && bad "in a sudo/wheel group" || ok "not in sudo/wheel/admin groups"
getent passwd "${SVC_USER}" | grep -qE '(nologin|false)$' \
  && ok "no interactive shell" || bad "has an interactive shell"

HOMES_BLOCKED=1
for h in /home/* /root; do
  [[ -d "$h" ]] || continue
  if sudo -u "${SVC_USER}" ls "$h" >/dev/null 2>&1; then
    bad "can list $h  ->  chmod 750 $h"; HOMES_BLOCKED=0
  fi
done
[[ ${HOMES_BLOCKED} -eq 1 ]] && ok "cannot read /root or any /home/* directory"

sudo -u "${SVC_USER}" -H bash -c "cd / && touch /usr/local/.boundary-test" 2>/dev/null \
  && { bad "can write to /usr/local"; rm -f /usr/local/.boundary-test; } \
  || ok "cannot write outside its tree"
sudo -u "${SVC_USER}" -H bash -c "cd '${SVC_HOME}' && touch '${WORKSPACE}/.boundary-ok'" 2>/dev/null \
  && { ok "can write inside workspace"; rm -f "${WORKSPACE}/.boundary-ok"; } \
  || bad "cannot write inside workspace"

if [[ "${HARDENING}" == "strict" ]]; then
  # Prove the sandbox: the *daemon's own* mount namespace must not see /home
  MAINPID=$(systemctl show -p MainPID --value "${SVCNAME}")
  if [[ -n "${MAINPID}" && "${MAINPID}" != "0" ]]; then
    if nsenter -t "${MAINPID}" -m ls /home 2>/dev/null | grep -q .; then
      warn "systemd ProtectHome not hiding /home in the service namespace"
    else
      ok "systemd sandbox active: /home invisible inside the service"
    fi
  fi
fi

echo; info "VALIDATION: process, credential, network"
systemctl is-active --quiet "${SVCNAME}" && ok "service active" || bad "service not active"
MAINPID=$(systemctl show -p MainPID --value "${SVCNAME}")
if [[ -n "${MAINPID}" && "${MAINPID}" != "0" ]]; then
  PUSER=$(ps -o user= -p "${MAINPID}" | tr -d ' ')
  [[ "${PUSER}" == "${SVC_USER}" ]] && ok "daemon runs as ${SVC_USER}" || bad "daemon runs as ${PUSER}"
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
PERMS=$(stat -c "%a" "${SVC_HOME}/.augment/session.json")
[[ "${PERMS}" == "600" ]] && ok "credential is 0600" || bad "credential perms ${PERMS}, expected 600"

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