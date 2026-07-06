#!/usr/bin/env bash
#
# setup-auggie-daemon-macos.sh  (v1.1)
# Creates a locked-down macOS service account, installs the Auggie CLI under it,
# links an Augment (Cosmos) Service Account credential, installs a LaunchDaemon,
# and validates the OS-level security boundary end to end.
#
# v1.1 field-test fixes:
#   - Service account now gets its OWN primary group instead of macOS default
#     'staff'. (All macOS home dirs are group 'staff'; a staff-member service
#     account could read any home dir set to 750. Dedicated group closes this.)
#   - Home-dir finding now recommends chmod 700 (owner-only), not 750.
#   - Network check only fails on NON-LOOPBACK listeners; local 127.0.0.1
#     listeners (Node IPC) are reported but not a network exposure.
#
# Usage:   sudo ./setup-auggie-daemon-macos.sh
#          sudo ./setup-auggie-daemon-macos.sh --uninstall
#
# Non-interactive: set env vars before running (POOL_ID, SESSION_JSON_PATH,
# REPO_URL, SVC_USER, MAX_AGENTS, DAEMON_NAME).
#
set -euo pipefail

# ---------- defaults (override via env) ----------
SVC_USER="${SVC_USER:-svc-augment}"
SVC_HOME="/var/${SVC_USER}"
WORKSPACE="${WORKSPACE:-${SVC_HOME}/workspace}"
MAX_AGENTS="${MAX_AGENTS:-4}"
DAEMON_NAME="${DAEMON_NAME:-$(hostname -s)-bridge-01}"
PLIST="/Library/LaunchDaemons/com.augment.auggie-daemon.plist"
LABEL="com.augment.auggie-daemon"
LOG_OUT="${SVC_HOME}/daemon.out.log"
LOG_ERR="${SVC_HOME}/daemon.err.log"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }
info() { echo "==> $1"; }
die()  { echo "ERROR: $1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"

# ---------- uninstall ----------
if [[ "${1:-}" == "--uninstall" ]]; then
  info "Uninstalling..."
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  rm -f "${PLIST}"
  if id "${SVC_USER}" &>/dev/null; then
    sysadminctl -deleteUser "${SVC_USER}" 2>/dev/null || dscl . -delete "/Users/${SVC_USER}"
  fi
  dseditgroup -o delete -q "${SVC_USER}" 2>/dev/null || true
  read -r -p "Delete ${SVC_HOME} (workspace + credential)? [y/N] " yn
  [[ "${yn}" == "y" ]] && rm -rf "${SVC_HOME}"
  echo "Uninstalled."
  exit 0
fi

# ---------- preflight ----------
info "Preflight checks"
command -v node >/dev/null || die "Node.js not found. Install Node 22+ first (https://nodejs.org)."
command -v git  >/dev/null || die "git not found. Install Xcode Command Line Tools: xcode-select --install"
NODE_MAJOR=$(node -e 'console.log(process.versions.node.split(".")[0])')
if   (( NODE_MAJOR < 20 )); then die "Node ${NODE_MAJOR} too old. Node 22+ required."
elif (( NODE_MAJOR < 22 )); then warn "Node ${NODE_MAJOR} detected; Node 22+ is recommended."
else ok "Node ${NODE_MAJOR}"; fi

# ---------- gather inputs ----------
if [[ -z "${POOL_ID:-}" ]]; then
  read -r -p "Daemon pool ID (from Cosmos > Environments > your Daemon Pool): " POOL_ID
fi
[[ -n "${POOL_ID}" ]] || die "Pool ID is required."
# Normalize: Cosmos pool IDs carry a 'pool-' prefix; auto-add it for bare UUIDs.
if [[ "${POOL_ID}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  POOL_ID="pool-${POOL_ID}"
  warn "pool ID had no 'pool-' prefix; using ${POOL_ID}"
fi

# Service Account credential: file path, or secure paste
SESSION_TMP="$(mktemp)"
trap 'rm -f "${SESSION_TMP}"' EXIT
if [[ -n "${SESSION_JSON_PATH:-}" ]]; then
  cp "${SESSION_JSON_PATH}" "${SESSION_TMP}"
else
  echo "Service Account credential (downloaded session.json from"
  echo "app.augmentcode.com/settings/service-accounts)."
  read -r -p "Path to session.json (leave blank to paste JSON instead): " SJ_PATH
  if [[ -n "${SJ_PATH}" ]]; then
    SJ_PATH="${SJ_PATH/#\~/$HOME}"
    [[ -f "${SJ_PATH}" ]] || die "File not found: ${SJ_PATH}"
    cp "${SJ_PATH}" "${SESSION_TMP}"
  else
    echo "Paste the session JSON on one line (input hidden), then press Enter:"
    read -r -s SJ_INLINE
    printf '%s' "${SJ_INLINE}" > "${SESSION_TMP}"
    unset SJ_INLINE
  fi
fi

# Validate JSON shape: accessToken + tenantURL + scopes[] are ALL required by the CLI.
info "Validating credential format"
node -e '
  const fs = require("fs");
  let s;
  try { s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
  catch (e) { console.error("Not valid JSON: " + e.message); process.exit(1); }
  const problems = [];
  if (!s.accessToken) problems.push("missing accessToken");
  if (!s.tenantURL)   problems.push("missing tenantURL");
  if (!Array.isArray(s.scopes)) problems.push("scopes must be an array (e.g. [\"email\"]) - the CLI rejects the session without it");
  if (problems.length) { console.error("Invalid session.json: " + problems.join("; ")); process.exit(1); }
  console.log("  credential OK (tenant: " + s.tenantURL + ")");
' "${SESSION_TMP}" || die "Credential validation failed. Re-download the token JSON and try again."

if [[ -z "${REPO_URL:-}" ]]; then
  read -r -p "Git repo URL to clone into the workspace (blank = create empty sandbox repo): " REPO_URL
fi

# ---------- create service account ----------
info "Creating service account '${SVC_USER}'"
if id "${SVC_USER}" &>/dev/null; then
  warn "User ${SVC_USER} already exists; reusing."
else
  sysadminctl -addUser "${SVC_USER}" -shell /usr/bin/false -home "${SVC_HOME}" >/dev/null 2>&1
  dscl . create "/Users/${SVC_USER}" IsHidden 1
  ok "created (hidden, non-admin, no login shell)"
fi

# Dedicated primary group: NOT 'staff'. Every macOS home dir is group 'staff',
# so a staff-member service account can read any home dir with 750 perms.
info "Assigning dedicated primary group '${SVC_USER}' (removing from 'staff')"
dseditgroup -o create -q "${SVC_USER}" 2>/dev/null || true
SVC_GID=$(dscl . -read "/Groups/${SVC_USER}" PrimaryGroupID | awk '{print $2}')
dscl . -create "/Users/${SVC_USER}" PrimaryGroupID "${SVC_GID}"
dseditgroup -o edit -d "${SVC_USER}" -t user staff 2>/dev/null || true
if id -Gn "${SVC_USER}" | tr ' ' '\n' | grep -qx staff; then
  warn "still shows membership in 'staff' - verify with: id ${SVC_USER}"
else
  ok "primary group ${SVC_USER} (gid ${SVC_GID}); not in 'staff'"
fi

info "Preparing directories"
mkdir -p "${WORKSPACE}" "${SVC_HOME}/.augment" "${SVC_HOME}/.npm-global"
chown -R "${SVC_USER}:${SVC_USER}" "${SVC_HOME}"
chmod 750 "${SVC_HOME}"
# Move the script itself into a directory the service account can read, so
# sudo-spawned shells don't emit "shell-init: getcwd" warnings when the
# installer is launched from inside a 700 home directory. (Credential was
# already copied to a temp file above, so no relative paths break.)
cd "${SVC_HOME}"

# ---------- install auggie under the service account ----------
# NOTE: every command run as ${SVC_USER} must cd into its own home first.
# The invoking admin's cwd may be inside a 700 home dir the service account
# cannot read, and npm/node hard-fail on an unreadable cwd (EACCES uv_cwd).
info "Installing @augmentcode/auggie under ${SVC_USER}'s npm prefix (may take a minute)"
sudo -u "${SVC_USER}" -H bash -c "
  cd '${SVC_HOME}'
  export HOME='${SVC_HOME}'
  npm config set prefix '${SVC_HOME}/.npm-global' --location=user
  npm install -g @augmentcode/auggie --loglevel=error
" || die "auggie install failed."
AUGGIE_BIN="${SVC_HOME}/.npm-global/bin/auggie"
[[ -x "${AUGGIE_BIN}" ]] || die "auggie binary not found at ${AUGGIE_BIN}"
AUGGIE_VER=$(sudo -u "${SVC_USER}" -H bash -c "cd '${SVC_HOME}' && HOME='${SVC_HOME}' '${AUGGIE_BIN}' --version" 2>/dev/null | head -1 || true)
ok "auggie ${AUGGIE_VER:-installed} at ${AUGGIE_BIN}"

# ---------- workspace repo ----------
info "Preparing workspace repo"
REPO_DIR="${WORKSPACE}/repo-a"
if [[ ! -d "${REPO_DIR}/.git" ]]; then
  if [[ -n "${REPO_URL}" ]]; then
    sudo -u "${SVC_USER}" -H bash -c "cd '${SVC_HOME}' && git clone '${REPO_URL}' '${REPO_DIR}'" || die "git clone failed."
  else
    sudo -u "${SVC_USER}" -H bash -c "
      cd '${SVC_HOME}' &&
      git init -q '${REPO_DIR}' && cd '${REPO_DIR}' &&
      git config user.email 'svc@localhost' && git config user.name 'svc-augment' &&
      echo '# sandbox' > README.md && git add . && git commit -qm init"
    warn "no repo URL given; created empty sandbox repo (worktrees need a git repo)"
  fi
fi

# ---------- credential ----------
info "Installing Service Account credential (owner-only 0600)"
install -o "${SVC_USER}" -g "${SVC_USER}" -m 600 "${SESSION_TMP}" "${SVC_HOME}/.augment/session.json"

# ---------- LaunchDaemon ----------
info "Writing LaunchDaemon ${PLIST}"
launchctl bootout "system/${LABEL}" 2>/dev/null || true
cat > "${PLIST}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>UserName</key><string>${SVC_USER}</string>
  <key>GroupName</key><string>${SVC_USER}</string>
  <key>WorkingDirectory</key><string>${REPO_DIR}</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>${SVC_HOME}</string>
    <key>PATH</key><string>${SVC_HOME}/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
  <key>ProgramArguments</key><array>
    <string>${AUGGIE_BIN}</string>
    <string>daemon</string>
    <string>--pool-id</string><string>${POOL_ID}</string>
    <string>--workspace</string><string>${REPO_DIR}</string>
    <string>--max-agents</string><string>${MAX_AGENTS}</string>
    <string>--allow-indexing</string>
    <string>--name</string><string>${DAEMON_NAME}</string>
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG_OUT}</string>
  <key>StandardErrorPath</key><string>${LOG_ERR}</string>
</dict></plist>
PLISTEOF
chown root:wheel "${PLIST}"; chmod 644 "${PLIST}"
launchctl bootstrap system "${PLIST}"

# ---------- wait for connection ----------
info "Waiting up to 90s for the daemon to register with Cosmos"
CONNECTED=0; REJECTED=""
for _ in $(seq 1 45); do
  # 'WebSocket connected' is only the transport - do NOT treat it as success.
  # Real success is pool registration; known rejections are surfaced as errors.
  if grep -qiE "unknown daemon pool" "${LOG_OUT}" "${LOG_ERR}" 2>/dev/null; then
    REJECTED="pool not found: the pool ID is wrong, or the pool lives in a different tenant than the service account. Check the pool detail page in Cosmos and that the SA is in the same org."
    break
  fi
  if grep -qiE "not the daemon pool connector" "${LOG_OUT}" "${LOG_ERR}" 2>/dev/null; then
    REJECTED="identity rejected: the pool's connector is not this service account. Set the pool connector to the SA in Cosmos."
    break
  fi
  if grep -qiE "registered with poseidon|daemon registered|registered daemon" "${LOG_OUT}" "${LOG_ERR}" 2>/dev/null; then
    CONNECTED=1; break
  fi
  sleep 2
done
if   [[ -n "${REJECTED}" ]]; then bad "daemon REJECTED by Cosmos - ${REJECTED}"
elif [[ ${CONNECTED} -eq 1 ]]; then ok "daemon REGISTERED with pool ${POOL_ID}"
else
  # No explicit registration line and no known error: verify liveness by
  # checking the socket stays open (a reject loop closes it within ~1s).
  sleep 8
  LAST=$(tail -5 "${LOG_OUT}" 2>/dev/null | grep -cE "WebSocket closed|Reconnecting" || true)
  if [[ "${LAST}" -gt 0 ]]; then
    bad "daemon is in a connect/close loop - check: sudo tail -30 ${LOG_OUT}"
  else
    warn "no explicit registration line found but connection appears stable - verify the pool shows 1 daemon online in Cosmos"
  fi
fi

# ---------- validation suite ----------
echo; info "VALIDATION: OS boundary"
dsmemberutil checkmembership -U "${SVC_USER}" -G admin 2>/dev/null | grep -q "is not a member" \
  && ok "not in admin group" || bad "IS in admin group"
id -Gn "${SVC_USER}" | tr ' ' '\n' | grep -qx staff \
  && bad "in 'staff' group (can read 750 home dirs)" || ok "not in 'staff' group"
[[ "$(dscl . -read /Users/${SVC_USER} UserShell 2>/dev/null | awk '{print $2}')" == "/usr/bin/false" ]] \
  && ok "no interactive shell" || bad "has an interactive shell"
dscl . -read "/Users/${SVC_USER}" IsHidden 2>/dev/null | grep -q 1 \
  && ok "hidden from login window" || warn "not hidden"

HOMES_BLOCKED=1
for h in /Users/*; do
  [[ "$h" == "/Users/Shared" || "$h" == "/Users/${SVC_USER}" ]] && continue
  [[ -d "$h" ]] || continue
  if sudo -u "${SVC_USER}" ls "$h" >/dev/null 2>&1; then
    bad "can list $h  ->  run: sudo chmod 700 $h   (750 is not enough if the dir's group is broad, e.g. 'staff')"
    HOMES_BLOCKED=0
  fi
done
[[ ${HOMES_BLOCKED} -eq 1 ]] && ok "cannot read any other user's home directory"

sudo -u "${SVC_USER}" -H bash -c "cd / && touch /usr/local/.boundary-test" 2>/dev/null \
  && { bad "can write to /usr/local"; rm -f /usr/local/.boundary-test; } \
  || ok "cannot write outside its tree (/usr/local denied)"
sudo -u "${SVC_USER}" -H bash -c "cd '${SVC_HOME}' && touch '${WORKSPACE}/.boundary-ok'" 2>/dev/null \
  && { ok "can write inside workspace"; rm -f "${WORKSPACE}/.boundary-ok"; } \
  || bad "cannot write inside workspace"

echo; info "VALIDATION: process, credential, network"
DPID=$(pgrep -f "auggie.*daemon.*${POOL_ID}" | head -1 || true)
if [[ -n "${DPID}" ]]; then
  PUSER=$(ps -o user= -p "${DPID}" | tr -d ' ')
  [[ "${PUSER}" == "${SVC_USER}" ]] && ok "daemon runs as ${SVC_USER} (pid ${DPID})" || bad "daemon runs as ${PUSER}"
  # Only NON-LOOPBACK listeners are a network exposure. Local 127.0.0.1/::1
  # listeners (Node IPC etc.) are unreachable from the network.
  # NOTE: lsof ORs selection filters by default; -a is required to AND them,
  # otherwise this returns every TCP listener on the machine + all daemon fds.
  ALL_LISTEN=$(lsof -a -p "${DPID}" -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR>1 {print $9}' || true)
  EXT_LISTEN=$(printf '%s\n' "${ALL_LISTEN}" | grep -vE '^(127\.0\.0\.1|\[::1\]|localhost):' | grep -v '^$' || true)
  if [[ -n "${EXT_LISTEN}" ]]; then
    bad "daemon listening on a NON-loopback address: $(echo "${EXT_LISTEN}" | tr '\n' ' ')"
  elif [[ -n "${ALL_LISTEN}" ]]; then
    ok "listeners are loopback-only ($(echo "${ALL_LISTEN}" | head -3 | tr '\n' ' ')) - not network-reachable"
  else
    ok "no listening ports at all (outbound-only)"
  fi
else
  warn "daemon process not found; skipping process/network checks"
fi
PERMS=$(stat -f "%Lp" "${SVC_HOME}/.augment/session.json")
[[ "${PERMS}" == "600" ]] && ok "credential is 0600 owner-only" || bad "credential perms are ${PERMS}, expected 600"

# ---------- summary ----------
echo
echo "================================================================"
echo " RESULT: ${PASS} passed / ${FAIL} failed / ${WARN} warnings"
echo "================================================================"
cat <<NEXT

MANUAL CHECKS (require Cosmos):
 1. Pool page in Cosmos should now show '1 daemon online' named '${DAEMON_NAME}'.
 2. Route a test session to the pool and ask it to run:
      ls /Users/<your-username>/Desktop
    Expected: permission denied  <- this proves the boundary against a live agent.
 3. Session attribution in Cosmos should show the SERVICE ACCOUNT, not a person.
 4. Connector enforcement: from YOUR account, run
      auggie daemon --pool-id ${POOL_ID} --name imposter-test
    Expected: "daemon user is not the daemon pool connector".

Ops:
  logs:      tail -f ${LOG_OUT}
  restart:   sudo launchctl kickstart -k system/${LABEL}
  uninstall: sudo $0 --uninstall
NEXT
[[ ${FAIL} -eq 0 ]] || exit 1