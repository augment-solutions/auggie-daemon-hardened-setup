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
AUGGIE_VERSION="${AUGGIE_VERSION:-0.32.0}"
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

validate_static_inputs() {
  [[ "${SVC_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "SVC_USER contains unsupported characters."
  case "${SVC_USER}" in root|nobody|daemon|bin|sys) die "Refusing reserved SVC_USER '${SVC_USER}'." ;; esac
  [[ "${DAEMON_NAME}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die "DAEMON_NAME must use only letters, numbers, dot, underscore, and hyphen."
  [[ "${AUGGIE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die "AUGGIE_VERSION must be an exact version (for example 0.32.0)."
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
  home=$(dscl . -read "/Users/${caller}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [[ -n "${home}" ]] || home="${HOME:-/var/root}"
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

xml_escape() {
  node -e 'process.stdout.write(process.argv[1].replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/\x27/g,"&apos;"))' "$1"
}

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"
validate_static_inputs
[[ ! -L "${SVC_HOME}" ]] || die "Refusing symlinked service home: ${SVC_HOME}"

if [[ "${1:-}" == "--uninstall" ]]; then
  info "Uninstalling..."
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  rm -f "${PLIST}"
  if id "${SVC_USER}" &>/dev/null; then
    SVC_UID=$(id -u "${SVC_USER}")
    ACCOUNT_HOME=$(dscl . -read "/Users/${SVC_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    if [[ "${SVC_UID}" != "0" && "${ACCOUNT_HOME}" == "${SVC_HOME}" ]]; then
      sysadminctl -deleteUser "${SVC_USER}" 2>/dev/null || dscl . -delete "/Users/${SVC_USER}"
    else
      warn "not deleting unexpected account ${SVC_USER} (uid=${SVC_UID}, home=${ACCOUNT_HOME})"
    fi
  fi
  dseditgroup -o delete -q "${SVC_USER}" 2>/dev/null || true
  read -r -p "Type DELETE to remove ${SVC_HOME} (workspace + credential), or press Enter to keep it: " confirm
  [[ "${confirm}" == "DELETE" ]] && rm -rf "${SVC_HOME}"
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
validate_pool_id

# Max agents: Enter = keep daemon's own default (100)
if [[ -z "${MAX_AGENTS+x}" ]]; then
  read -r -p "Max concurrent agent sessions [Enter = daemon default (100); 4-5 recommended on 8-16GB hosts]: " MAX_AGENTS
fi
if [[ -n "${MAX_AGENTS}" ]]; then
  [[ "${MAX_AGENTS}" =~ ^[0-9]+$ ]] || die "Max agents must be a number or blank."
  (( 10#${MAX_AGENTS} > 0 )) || die "Max agents must be greater than zero."
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
    # shellcheck disable=SC2088 # Match a literal tilde before expanding the invoking user's home.
    case "${SJ_PATH}" in "~"|"~/"*) SJ_PATH="$(invoking_user_home)${SJ_PATH:1}" ;; esac
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
launchctl bootout "system/${LABEL}" 2>/dev/null || true
sleep 2
if id "${SVC_USER}" &>/dev/null; then
  SVC_UID=$(id -u "${SVC_USER}")
  ACCOUNT_HOME=$(dscl . -read "/Users/${SVC_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  ACCOUNT_SHELL=$(dscl . -read "/Users/${SVC_USER}" UserShell 2>/dev/null | awk '{print $2}')
  [[ "${SVC_UID}" != "0" ]] || die "Refusing to reuse uid 0 account ${SVC_USER}."
  [[ "${ACCOUNT_HOME}" == "${SVC_HOME}" ]] || die "Existing ${SVC_USER} home is ${ACCOUNT_HOME}, expected ${SVC_HOME}."
  [[ "${ACCOUNT_SHELL}" == "/usr/bin/false" || "${ACCOUNT_SHELL}" == */nologin ]] || die "Existing ${SVC_USER} has an interactive shell (${ACCOUNT_SHELL})."
  dsmemberutil checkmembership -U "${SVC_USER}" -G admin 2>/dev/null | grep -q "is not a member" \
    || die "Existing ${SVC_USER} is an administrator."
  warn "verified existing locked-down account; reusing"
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
for protected_path in "${WORKSPACE}" "${SVC_HOME}/.augment" "${SVC_HOME}/.npm-global"; do
  [[ ! -L "${protected_path}" ]] || die "Refusing symlinked managed path: ${protected_path}"
done
mkdir -p "${WORKSPACE}" "${SVC_HOME}/.augment" "${SVC_HOME}/.npm-global"
chown -R "${SVC_USER}:${SVC_USER}" "${SVC_HOME}"
chmod 750 "${SVC_HOME}"
cd "${SVC_HOME}"   # neutral cwd for all sudo-spawned shells

# ---------- install auggie ----------
info "Installing @augmentcode/auggie@${AUGGIE_VERSION} under ${SVC_USER}'s npm prefix (may take a minute)"
chown -R "${SVC_USER}:${SVC_USER}" "${SVC_HOME}/.npm-global"
sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" npm config set prefix "${SVC_HOME}/.npm-global" --location=user
sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" npm install -g "@augmentcode/auggie@${AUGGIE_VERSION}" --loglevel=error \
  || die "auggie install failed."
AUGGIE_BIN="${SVC_HOME}/.npm-global/bin/auggie"
[[ -x "${AUGGIE_BIN}" ]] || die "auggie binary not found at ${AUGGIE_BIN}"
AUGGIE_VER=$(sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" "${AUGGIE_BIN}" --version 2>/dev/null | head -1 || true)
chown -R "root:${SVC_USER}" "${SVC_HOME}/.npm-global"
chmod -R u=rwX,g=rX,o= "${SVC_HOME}/.npm-global"
ok "auggie ${AUGGIE_VER:-installed} at ${AUGGIE_BIN}"

# ---------- materialize workspaces ----------
# Each source becomes a directory under ${WORKSPACE}, owned by the service
# account. Local paths are COPIED (the boundary requires the working tree to
# live where the service account can reach it and your 700 home cannot leak).
materialize_ws() {  # $1 = source, echoes the destination path
  local src="$1" name dest
  # shellcheck disable=SC2088 # Match a literal tilde before expanding the invoking user's home.
  case "${src}" in "~"|"~/"*) src="$(invoking_user_home)${src:1}" ;; esac
  if [[ -d "${src}" ]]; then
    name=$(basename "${src}")
    dest="${WORKSPACE}/${name}"
    safe_workspace_name "${name}"
    [[ ! -L "${dest}" ]] || die "Refusing symlinked workspace destination: ${dest}"
    if [[ -d "${dest}" ]]; then echo "${dest}"; return 0; fi
    echo "    copying local path ${src} -> ${dest}" >&2
    cp -R "${src}" "${dest}"
    chown -R "${SVC_USER}:${SVC_USER}" "${dest}"
    if [[ ! -d "${dest}/.git" ]]; then
      echo "    (not a git repo - initializing one so worktrees function)" >&2
        sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${dest}" init -q
        sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${dest}" config user.email svc@localhost
        sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${dest}" config user.name "${SVC_USER}"
        sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${dest}" add -A
        sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${dest}" commit -qm import
    fi
  else
    name=$(basename "${src}" .git)
    dest="${WORKSPACE}/${name}"
    safe_workspace_name "${name}"
    [[ ! -L "${dest}" ]] || die "Refusing symlinked workspace destination: ${dest}"
    if [[ -d "${dest}" ]]; then echo "${dest}"; return 0; fi
    echo "    cloning ${src} -> ${dest}" >&2
    sudo -u "${SVC_USER}" -H env -u GIT_SSH -u GIT_SSH_COMMAND HOME="${SVC_HOME}" \
      git -C "${SVC_HOME}" clone -- "${src}" "${dest}" \
      || die "git clone failed for ${src}"
  fi
  echo "${dest}"
}

info "Preparing workspace(s)"
WS_DIRS=()
if [[ ${#WS_SOURCES[@]} -eq 0 ]]; then
  DEST="${WORKSPACE}/sandbox"
  if [[ ! -d "${DEST}/.git" ]]; then
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git init -q "${DEST}"
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${DEST}" config user.email svc@localhost
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${DEST}" config user.name "${SVC_USER}"
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" sh -c 'printf "%s\n" "# sandbox" > "$1"' _ "${DEST}/README.md"
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${DEST}" add README.md
    sudo -u "${SVC_USER}" -H env HOME="${SVC_HOME}" git -C "${DEST}" commit -qm init
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
[[ ! -L "${SVC_HOME}/.augment/session.json" ]] || die "Refusing symlinked credential destination."
install -o "${SVC_USER}" -g "${SVC_USER}" -m 600 "${SESSION_TMP}" "${SVC_HOME}/.augment/session.json"

# ---------- LaunchDaemon ----------
info "Writing LaunchDaemon ${PLIST}"
AUGGIE_BIN_XML=$(xml_escape "${AUGGIE_BIN}")
POOL_ID_XML=$(xml_escape "${POOL_ID}")
PRIMARY_WS_XML=$(xml_escape "${PRIMARY_WS}")
DAEMON_NAME_XML=$(xml_escape "${DAEMON_NAME}")
ARGS_XML="    <string>${AUGGIE_BIN_XML}</string>
    <string>daemon</string>
    <string>--pool-id</string><string>${POOL_ID_XML}</string>
    <string>--workspace</string><string>${PRIMARY_WS_XML}</string>"
for ((i=1; i<${#WS_DIRS[@]}; i++)); do
  WS_XML=$(xml_escape "${WS_DIRS[$i]}")
  ARGS_XML+="
    <string>--add-workspace</string><string>${WS_XML}</string>"
done
if [[ -n "${MAX_AGENTS}" ]]; then
  ARGS_XML+="
    <string>--max-agents</string><string>${MAX_AGENTS}</string>"
fi
ARGS_XML+="
    <string>--allow-indexing</string>
    <string>--name</string><string>${DAEMON_NAME_XML}</string>"

SVC_USER_XML=$(xml_escape "${SVC_USER}")
SVC_HOME_XML=$(xml_escape "${SVC_HOME}")
LOG_OUT_XML=$(xml_escape "${LOG_OUT}")
LOG_ERR_XML=$(xml_escape "${LOG_ERR}")

cat > "${PLIST}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>UserName</key><string>${SVC_USER_XML}</string>
  <key>GroupName</key><string>${SVC_USER_XML}</string>
  <key>WorkingDirectory</key><string>${PRIMARY_WS_XML}</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>${SVC_HOME_XML}</string>
    <key>PATH</key><string>${SVC_HOME_XML}/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
  <key>ProgramArguments</key><array>
${ARGS_XML}
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG_OUT_XML}</string>
  <key>StandardErrorPath</key><string>${LOG_ERR_XML}</string>
</dict></plist>
PLISTEOF
chown root:wheel "${PLIST}"; chmod 644 "${PLIST}"
plutil -lint "${PLIST}" >/dev/null || die "Generated LaunchDaemon plist failed validation."
install -o "${SVC_USER}" -g "${SVC_USER}" -m 600 /dev/null "${LOG_OUT}"
install -o "${SVC_USER}" -g "${SVC_USER}" -m 600 /dev/null "${LOG_ERR}"
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
if dsmemberutil checkmembership -U "${SVC_USER}" -G admin 2>/dev/null | grep -q "is not a member"; then ok "not in admin group"; else bad "IS in admin group"; fi
if id -Gn "${SVC_USER}" | tr ' ' '\n' | grep -qx staff; then bad "in 'staff' group (can read 750 home dirs)"; else ok "not in 'staff' group"; fi
if [[ "$(dscl . -read "/Users/${SVC_USER}" UserShell 2>/dev/null | awk '{print $2}')" == "/usr/bin/false" ]]; then ok "no interactive shell"; else bad "has an interactive shell"; fi
if dscl . -read "/Users/${SVC_USER}" IsHidden 2>/dev/null | grep -q 1; then ok "hidden from login window"; else warn "not hidden"; fi

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

if sudo -u "${SVC_USER}" -H touch /usr/local/.boundary-test 2>/dev/null; then
  bad "can write to /usr/local"; rm -f /usr/local/.boundary-test
else ok "cannot write outside its tree (/usr/local denied)"; fi
if sudo -u "${SVC_USER}" -H touch "${WORKSPACE}/.boundary-ok" 2>/dev/null; then
  ok "can write inside workspace"; rm -f "${WORKSPACE}/.boundary-ok"
else bad "cannot write inside workspace"; fi

echo; info "VALIDATION: process, credential, network"
DPID=$(launchctl print "system/${LABEL}" 2>/dev/null | awk '/pid =/{print $3; exit}' || true)
if [[ -n "${DPID}" ]]; then
  PUSER=$(ps -o user= -p "${DPID}" | tr -d ' ')
  if [[ "${PUSER}" == "${SVC_USER}" ]]; then ok "daemon runs as ${SVC_USER} (pid ${DPID})"; else bad "daemon runs as ${PUSER}"; fi
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
PERMS=$(stat -f "%Lp" "${SVC_HOME}/.augment/session.json" 2>/dev/null || true)
if [[ "${PERMS}" == "600" ]]; then ok "credential is 0600 owner-only"; else bad "credential perms are ${PERMS:-unavailable}, expected 600"; fi

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