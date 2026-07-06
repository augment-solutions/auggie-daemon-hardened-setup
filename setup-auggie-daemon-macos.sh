#!/usr/bin/env bash
#
# setup-auggie-daemon-macos.sh  (v2.0)
# Creates a locked-down macOS service account, installs the Auggie CLI under it,
# links an Augment (Cosmos) Service Account credential, installs a LaunchDaemon,
# and validates the OS-level security boundary end to end.
#
# Onboarding (v2.0):
#   - Max agents: press Enter to keep the daemon's own default (100); enter a
#     number to cap it (4-5 recommended on 8-16 GB laptops).
#   - Workspaces: each prompt accepts a git URL (cloned), an existing local
#     path (COPIED into the service account's workspace), or blank.
#   - Multiple workspaces supported; extras become --add-workspace flags.
#
# Usage:   sudo ./setup-auggie-daemon-macos.sh
#          sudo ./setup-auggie-daemon-macos.sh --uninstall
#
# Non-interactive env vars:
#   POOL_ID, SESSION_JSON_PATH, WORKSPACE_SRC (URL|path|blank),
#   EXTRA_WORKSPACES (comma-separated URLs/paths), MAX_AGENTS ("" = default),
#   SVC_USER, DAEMON_NAME
#
set -euo pipefail

SVC_USER="${SVC_USER:-svc-augment}"
SVC_HOME="/var/${SVC_USER}"
WORKSPACE="${SVC_HOME}/workspace"
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
if [[ "${POOL_ID}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  POOL_ID="pool-${POOL_ID}"
  warn "pool ID had no 'pool-' prefix; using ${POOL_ID}"
fi

# Max agents: Enter = keep daemon's own default (100)
if [[ -z "${MAX_AGENTS+x}" ]]; then
  read -r -p "Max concurrent agent sessions [Enter = daemon default (100); 4-5 recommended on 8-16GB hosts]: " MAX_AGENTS
fi
if [[ -n "${MAX_AGENTS}" ]]; then
  [[ "${MAX_AGENTS}" =~ ^[0-9]+$ ]] || die "Max agents must be a number or blank."
  info "Capping at ${MAX_AGENTS} concurrent sessions (each active session can use 0.5-2 GB RAM)"
else
  warn "using daemon default (100 slots). On laptops/small hosts this can exhaust RAM under load; consider a cap."
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

# Workspace sources: collected now, materialized after the account exists.
WS_SOURCES=()
if [[ -n "${WORKSPACE_SRC+x}" ]]; then
  [[ -n "${WORKSPACE_SRC}" ]] && WS_SOURCES+=("${WORKSPACE_SRC}")
  if [[ -n "${EXTRA_WORKSPACES:-}" ]]; then
    IFS=',' read -r -a _extra <<< "${EXTRA_WORKSPACES}"
    for e in "${_extra[@]}"; do [[ -n "${e}" ]] && WS_SOURCES+=("${e}"); done
  fi
else
  echo
  echo "Workspaces: enter a git URL (will be cloned) OR an existing local path"
  echo "(will be COPIED into the service account's workspace - the original is"
  echo "not touched and later changes to it won't sync). Blank = empty sandbox."
  read -r -p "Primary workspace (git URL / local path / blank): " FIRST
  [[ -n "${FIRST}" ]] && WS_SOURCES+=("${FIRST}")
  while true; do
    read -r -p "Add another workspace? (git URL / local path / blank to finish): " MORE
    [[ -z "${MORE}" ]] && break
    WS_SOURCES+=("${MORE}")
  done
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
cd "${SVC_HOME}"   # neutral cwd for all sudo-spawned shells

# ---------- install auggie ----------
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

# ---------- materialize workspaces ----------
# Each source becomes a directory under ${WORKSPACE}, owned by the service
# account. Local paths are COPIED (the boundary requires the working tree to
# live where the service account can reach it and your 700 home cannot leak).
materialize_ws() {  # $1 = source, echoes the destination path
  local src="$1" name dest
  if [[ -d "${src/#\~/$HOME}" ]]; then
    src="${src/#\~/$HOME}"
    name=$(basename "${src}")
    dest="${WORKSPACE}/${name}"
    if [[ -d "${dest}" ]]; then echo "${dest}"; return 0; fi
    echo "    copying local path ${src} -> ${dest}" >&2
    cp -R "${src}" "${dest}"
    chown -R "${SVC_USER}:${SVC_USER}" "${dest}"
    if [[ ! -d "${dest}/.git" ]]; then
      echo "    (not a git repo - initializing one so worktrees function)" >&2
      sudo -u "${SVC_USER}" -H bash -c "
        cd '${dest}' &&
        git init -q && git config user.email 'svc@localhost' &&
        git config user.name '${SVC_USER}' && git add -A && git commit -qm 'import'"
    fi
  else
    name=$(basename "${src}" .git)
    dest="${WORKSPACE}/${name}"
    if [[ -d "${dest}" ]]; then echo "${dest}"; return 0; fi
    echo "    cloning ${src} -> ${dest}" >&2
    sudo -u "${SVC_USER}" -H bash -c "cd '${SVC_HOME}' && git clone '${src}' '${dest}'" \
      || die "git clone failed for ${src}"
  fi
  echo "${dest}"
}

info "Preparing workspace(s)"
WS_DIRS=()
if [[ ${#WS_SOURCES[@]} -eq 0 ]]; then
  DEST="${WORKSPACE}/sandbox"
  if [[ ! -d "${DEST}/.git" ]]; then
    sudo -u "${SVC_USER}" -H bash -c "
      cd '${SVC_HOME}' &&
      git init -q '${DEST}' && cd '${DEST}' &&
      git config user.email 'svc@localhost' && git config user.name '${SVC_USER}' &&
      echo '# sandbox' > README.md && git add . && git commit -qm init"
  fi
  warn "no workspace given; created empty sandbox repo (worktrees need a git repo)"
  WS_DIRS+=("${DEST}")
else
  for src in "${WS_SOURCES[@]}"; do
    WS_DIRS+=("$(materialize_ws "${src}")")
  done
fi
PRIMARY_WS="${WS_DIRS[0]}"
ok "primary workspace: ${PRIMARY_WS}"
for ((i=1; i<${#WS_DIRS[@]}; i++)); do ok "additional workspace: ${WS_DIRS[$i]}"; done

# ---------- credential ----------
info "Installing Service Account credential (owner-only 0600)"
install -o "${SVC_USER}" -g "${SVC_USER}" -m 600 "${SESSION_TMP}" "${SVC_HOME}/.augment/session.json"

# ---------- LaunchDaemon ----------
info "Writing LaunchDaemon ${PLIST}"
launchctl bootout "system/${LABEL}" 2>/dev/null || true
sleep 2   # let any prior instance finish shutting down (avoids Bootstrap I/O error)

ARGS_XML="    <string>${AUGGIE_BIN}</string>
    <string>daemon</string>
    <string>--pool-id</string><string>${POOL_ID}</string>
    <string>--workspace</string><string>${PRIMARY_WS}</string>"
for ((i=1; i<${#WS_DIRS[@]}; i++)); do
  ARGS_XML+="
    <string>--add-workspace</string><string>${WS_DIRS[$i]}</string>"
done
if [[ -n "${MAX_AGENTS}" ]]; then
  ARGS_XML+="
    <string>--max-agents</string><string>${MAX_AGENTS}</string>"
fi
ARGS_XML+="
    <string>--allow-indexing</string>
    <string>--name</string><string>${DAEMON_NAME}</string>"

cat > "${PLIST}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>UserName</key><string>${SVC_USER}</string>
  <key>GroupName</key><string>${SVC_USER}</string>
  <key>WorkingDirectory</key><string>${PRIMARY_WS}</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>${SVC_HOME}</string>
    <key>PATH</key><string>${SVC_HOME}/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
  <key>ProgramArguments</key><array>
${ARGS_XML}
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG_OUT}</string>
  <key>StandardErrorPath</key><string>${LOG_ERR}</string>
</dict></plist>
PLISTEOF
chown root:wheel "${PLIST}"; chmod 644 "${PLIST}"
launchctl bootstrap system "${PLIST}" || { sleep 3; launchctl bootstrap system "${PLIST}"; }

# ---------- wait for registration ----------
info "Waiting up to 90s for the daemon to register with Cosmos"
CONNECTED=0; REJECTED=""
for _ in $(seq 1 45); do
  if grep -qiE "unknown daemon pool" "${LOG_OUT}" "${LOG_ERR}" 2>/dev/null; then
    REJECTED="pool not found: the pool ID is wrong, or the pool lives in a different tenant than the service account."
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
  sleep 8
  LAST=$(tail -5 "${LOG_OUT}" 2>/dev/null | grep -cE "WebSocket closed|Reconnecting" || true)
  if [[ "${LAST}" -gt 0 ]]; then
    bad "daemon is in a connect/close loop - check: sudo tail -30 ${LOG_OUT}"
  else
    warn "no explicit registration line found but connection appears stable - verify the pool shows daemons online in Cosmos"
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
    bad "can list $h  ->  run: sudo chmod 700 $h"
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
  ALL_LISTEN=$(lsof -a -p "${DPID}" -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR>1 {print $9}' || true)
  EXT_LISTEN=$(printf '%s\n' "${ALL_LISTEN}" | grep -vE '^(127\.0\.0\.1|\[::1\]|localhost):' | grep -v '^$' || true)
  if [[ -n "${EXT_LISTEN}" ]]; then
    bad "daemon listening on a NON-loopback address: $(echo "${EXT_LISTEN}" | tr '\n' ' ')"
  elif [[ -n "${ALL_LISTEN}" ]]; then
    ok "listeners are loopback-only - not network-reachable"
  else
    ok "no listening ports at all (outbound-only)"
  fi
else
  warn "daemon process not found; skipping process/network checks"
fi
PERMS=$(stat -f "%Lp" "${SVC_HOME}/.augment/session.json")
[[ "${PERMS}" == "600" ]] && ok "credential is 0600 owner-only" || bad "credential perms are ${PERMS}, expected 600"

echo
echo "================================================================"
echo " RESULT: ${PASS} passed / ${FAIL} failed / ${WARN} warnings"
echo "================================================================"
cat <<NEXT

MANUAL CHECKS (require Cosmos):
 1. Pool page should show this daemon online: '${DAEMON_NAME}'.
 2. Route a test session to the pool and ask it to run:
      ls /Users/<your-username>/Desktop
    Expected: permission denied  <- proves the boundary against a live agent.
 3. Session attribution should show the SERVICE ACCOUNT, not a person.
 4. Connector enforcement: from YOUR account, run
      auggie daemon --pool-id ${POOL_ID} --name imposter-test
    Expected: "daemon user is not the daemon pool connector".

NOTE on local-path workspaces: they were COPIED into ${WORKSPACE}.
To refresh a copy later: sudo rsync -a --delete <original>/ ${WORKSPACE}/<name>/ \\
  && sudo chown -R ${SVC_USER}:${SVC_USER} ${WORKSPACE}/<name>

Ops:
  logs:      sudo tail -f ${LOG_OUT}
  restart:   sudo launchctl kickstart -k system/${LABEL}
  uninstall: sudo $0 --uninstall
NEXT
[[ ${FAIL} -eq 0 ]] || exit 1