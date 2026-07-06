# Auggie Daemon: Locked-Down Service Account Installers

One script per OS that provisions everything needed to run the [Auggie daemon](https://docs.augmentcode.com) under a **dedicated, least-privileged local service account** linked to an **Augment Service Account** (Cosmos identity), then **validates the security boundary** automatically.

Why: by default the daemon runs with the full OS permissions of whoever launches it. These installers make the daemon run as a locked-down account instead, so Cosmos agents can only reach the workspace you assign, never user files, SSH keys, or system resources.

| OS | Script | Runs the daemon via |
|---|---|---|
| macOS | `setup-auggie-daemon-macos.sh` | LaunchDaemon (hidden service user) |
| Linux / WSL2 | `setup-auggie-daemon-linux.sh` | Hardened systemd unit (`ProtectHome`, `ProtectSystem=strict`) |
| Windows (native) | `setup-auggie-daemon-windows.ps1` | Scheduled Task as a local service account |

On Windows, **WSL2 + the Linux script is the recommended path** (WSL is the officially supported Windows platform for the CLI, and the systemd sandboxing is the strongest boundary). The native PowerShell script is for hosts where WSL isn't an option.

## Before you run anything (Cosmos side, done once by an Enterprise admin)

1. **Create the Service Account + token:** app.augmentcode.com/settings/service-accounts → Add Service Account → Add API token → **download `session.json`**. Tokens don't expire; rotate by issuing a new one and deleting the old.
2. **Create a connector-backed Daemon Pool:** Cosmos → Environments → Create → Daemon Pool. Set the **connector to the service account** (only daemons authenticating as it can join) and visibility to **Shared/Tenant**. Copy the **pool ID**.

## Getting the credential onto the daemon host (do this safely)

The `session.json` downloads via browser on the admin's machine. It is a bearer credential; treat it like a password:

- **Preferred:** copy it over an authenticated channel: `scp session.json admin@daemonhost:/tmp/` then run the installer pointing at that path. The installer moves it into place with owner-only permissions and you should **delete the original** afterward (`rm` / secure-delete on both the download folder and `/tmp`).
- **Alternative:** run the installer and choose the **paste option**. Input is hidden, written straight to the final location with `0600`/restricted ACL, and never stored elsewhere.
- **Never** email it, put it in chat, commit it, or place it in a shared drive. If it may have been exposed, revoke the token in the Service Accounts page and issue a new one.

The scripts validate the JSON before installing: it must contain `accessToken`, `tenantURL`, **and** `scopes` as an array. A missing `scopes` array is silently rejected by the CLI and is the single most common cause of "auth worked yesterday" failures.

## Usage

### macOS
```bash
chmod +x setup-auggie-daemon-macos.sh
sudo ./setup-auggie-daemon-macos.sh
# non-interactive:
sudo POOL_ID=pool-xxxx SESSION_JSON_PATH=/tmp/session.json REPO_URL=git@github.com:org/repo.git \
  ./setup-auggie-daemon-macos.sh
```

### Linux / WSL2
```bash
chmod +x setup-auggie-daemon-linux.sh
sudo ./setup-auggie-daemon-linux.sh
# hardening levels: HARDENING=strict (default) | full | off
sudo POOL_ID=pool-xxxx SESSION_JSON_PATH=/tmp/session.json HARDENING=strict ./setup-auggie-daemon-linux.sh
```
WSL2 note: enable systemd first (`/etc/wsl.conf` → `[boot]\nsystemd=true`, then `wsl --shutdown`).

### Windows (native)
```powershell
# Elevated PowerShell
Set-ExecutionPolicy -Scope Process Bypass
.\setup-auggie-daemon-windows.ps1
# non-interactive:
.\setup-auggie-daemon-windows.ps1 -PoolId pool-xxxx -SessionJson C:\tmp\session.json -RepoUrl https://github.com/org/repo.git
```

## What every script does

1. Preflight: Node 22+ (20 minimum), git, auggie CLI (Windows enforces >= 0.28.0).
2. Prompts for pool ID, credential (path or hidden paste), and repo URL, all overridable via env vars/parameters for unattended installs.
3. Creates the locked-down account: hidden non-admin user (macOS), `--system` account with `nologin` and home outside `/home` (Linux), non-admin local user with batch-logon right (Windows).
4. Installs auggie under the service account's own npm prefix (macOS/Linux) or globally (Windows), clones your repo as the workspace (or creates a git sandbox so worktrees function).
5. Installs the credential at the service account's `~/.augment/session.json` (macOS/Linux) or via `--augment-session-json` (Windows), locked to owner-only.
6. Registers the always-on service wrapper and waits for the daemon to report CONNECTED.
7. Runs the validation suite and prints PASS/FAIL:
   - account is non-admin, hidden, no interactive shell
   - cannot read any other user's home/profile; cannot write outside its tree; can write inside the workspace
   - (Linux strict mode) `/home` is invisible inside the service's mount namespace, kernel-enforced
   - daemon process owned by the service account
   - no inbound listening ports (the daemon is outbound-only)
   - credential file is owner-only
8. Prints the four manual checks that need Cosmos: pool shows 1 daemon online, a live agent gets "permission denied" reading a real user's files, session attribution shows the service account, and a non-connector identity is rejected with "daemon user is not the daemon pool connector".

## Tuning

- `MAX_AGENTS` (default 4): each concurrent session can use 0.5 to 2 GB RAM; keep 4-5 on an 8-16 GB host and archive completed sessions in Cosmos to reclaim memory.
- Linux `HARDENING=strict` makes the whole filesystem read-only to agents outside `/srv/augment`. If a workflow legitimately needs other paths, add `ReadWritePaths=` lines to the unit or use `HARDENING=full`.
- Never point `--workspace` at the account's home directory itself; indexing is blocked there and pool sessions will fail to start.
- Keep the CLI updated on the host (`npm update -g @augmentcode/auggie`); long-running daemons don't auto-update.

## Uninstall

```bash
sudo ./setup-auggie-daemon-macos.sh --uninstall     # macOS
sudo ./setup-auggie-daemon-linux.sh --uninstall     # Linux
.\setup-auggie-daemon-windows.ps1 -Uninstall        # Windows
```

## Disclaimer

Community scripts, not an official Augment Code product. Review before running with root/admin rights, and dry-run on a test host before production or customer environments.