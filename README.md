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

## Onboarding prompts (v2.0)

- **Pool ID:** bare UUIDs are auto-prefixed with `pool-`.
- **Max agents:** press Enter to keep the daemon's own default (100 slots). Enter a number to cap it; 4-5 is recommended on 8-16 GB hosts since each active session can use 0.5-2 GB RAM.
- **Workspaces:** each prompt accepts a git URL (cloned as the service account) or an existing local path (COPIED into the service account's workspace; the original is untouched and later edits don't sync - refresh with rsync if needed). Blank creates an empty sandbox repo. Add as many as you want; extras become `--add-workspace` flags.

## Tuning

- `MAX_AGENTS` (default 4): each concurrent session can use 0.5 to 2 GB RAM; keep 4-5 on an 8-16 GB host and archive completed sessions in Cosmos to reclaim memory.
- Linux `HARDENING=strict` makes the whole filesystem read-only to agents outside `/srv/augment`. If a workflow legitimately needs other paths, add `ReadWritePaths=` lines to the unit or use `HARDENING=full`.
- Never point `--workspace` at the account's home directory itself; indexing is blocked there and pool sessions will fail to start.
- Keep the CLI updated on the host (`npm update -g @augmentcode/auggie`); long-running daemons don't auto-update.

## Field-testing notes (v1.1)

- **macOS group fix:** the service account gets its own dedicated primary group and is removed from `staff`. macOS home directories are group `staff` by default, so a `staff`-member service account could list any home directory set to 750. With the dedicated group, only `chmod 700`-level privacy is assumed of no one; the validator now recommends `chmod 700` on any home directory it can still read.
- **Loopback listeners are normal:** the daemon (Node) may open local `127.0.0.1` ports for internal IPC. These are not reachable from the network. All three validators now fail only on non-loopback (`0.0.0.0` / LAN-bound) listeners and report loopback listeners as informational.

- **Run-from-anywhere fix (v1.2):** commands executed as the service account now `cd` into its own home first. Previously, running the installer from inside a `chmod 700` home directory made npm crash as the service user (`EACCES uv_cwd`), because child processes inherited an unreadable working directory.

## Validated environments

Every script was executed end to end against a live Cosmos daemon pool (Augment `e2` tenant), with all three OSes registering daemons to the same pool (horizontal slot pooling confirmed). Boundary validations were run against real user data on each host.

| OS | Environment | Runtime | Result |
|---|---|---|---|
| macOS 26.5.1 (25F80) | MacBook Pro, Apple Silicon (physical hardware, multi-user machine) | Node 23, auggie 0.32.0 | Full suite passing: hidden service account with dedicated group, home-dir denial verified at 700, zero listening ports, LaunchDaemon persistence, live pool registration |
| Ubuntu 26.04 LTS (aarch64) | Multipass VM on Apple Silicon (2 vCPU / 6 GB), systemd | Node 22, auggie 0.32.0 | Full suite passing including `ProtectHome`/`ProtectSystem=strict` hardening, mount-namespace `/home` invisibility, decoy-user boundary test, systemd persistence |
| Windows Server 2022 | GCP `e2-standard-2` (us-east1), fresh image | Node 22.14, auggie 0.32.0 | Scheduled Task path passing: non-admin local account, non-inherited ACLs, credential lockdown, task running as `svc-augment`. Windows Service (WinSW) mode added in v2.3.1 and not yet field-run |

Not yet field-tested: WSL2 + the Linux script (the officially supported Windows path - expected to behave identically to the Ubuntu run), macOS Intel, and non-Ubuntu distros. The scripts use only portable mechanisms (useradd/systemd, sysadminctl/launchd, net user/schtasks), but dry-run on your target before production use.

## Version history

All findings below came from real installs on macOS (validated end to end against a live Cosmos pool), and every fix applies to the corresponding scripts.

**v2.3.2 - Service logon fix: SYSTEM escalation caught by validation** (Windows)
- Field testing caught the service running as **LocalSystem**: WinSW v2 and v3 use different `serviceaccount` schemas, and a v3-style block is silently ignored by v2.12, defaulting the service to SYSTEM. The validation suite's process-owner check flagged it immediately.
- Fix: credentials are no longer placed in the WinSW XML at all. The logon account is set via `sc.exe config` after install (with `SeServiceLogonRight` granted alongside the batch right), and the installer now verifies the service's actual StartName before declaring success. The password never touches disk.

**v2.3.1 - Service wrapper switched to WinSW** (Windows)
- nssm.cc (a single-maintainer host) returned 503 during field testing; the service mode now uses WinSW v2.12.0 from official GitHub releases instead (github.com/winsw/winsw, MIT, actively maintained). The account password is required only at install time and is scrubbed from the on-disk config immediately after the SCM stores the credential.

**v2.3 - Windows run-mode choice** (Windows)
- Onboarding now asks: Scheduled Task (default - boot start, no login, auto-restart, no third-party software; lives in taskschd.msc, not services.msc) or Windows Service (visible in services.msc, SCM-supervised, works with SCOM/Datadog service monitoring). Strictly one mechanism - the installer removes the other if present, and uninstall cleans up both.

**v2.2 - Windows: daemon blocked by its own boundary** (Windows)
- auggie now installs into `C:\augment\npm` instead of the admin's per-user npm path. The service account cannot read `C:\Users\<admin>\AppData\...` (by design), so the task exited with code 1 instantly. The fix keeps the binary inside the ACL'd tree the service account owns.
- Task command is wrapped in `cmd /c ... >> daemon.out.log 2>&1` so the daemon's output is actually captured (Task Scheduler records nothing by itself).

**v2.1 - Windows task registration + multi-line paste** (all scripts)
- `Register-ScheduledTask` cannot resolve the `.\user` shorthand ("No mapping between account names and security IDs"); the explicit `COMPUTERNAME\user` form is used, and registration failures now hard-fail instead of printing a false PASS.
- The credential paste prompt now accepts the pretty-printed multi-line `session.json` as downloaded: hidden input is accumulated until the JSON braces balance. Previously only the first line was captured.

**v2.0 - Onboarding overhaul** (all scripts)
- Max agents: press Enter to keep the daemon's own default (100 slots); enter a number to cap it. The flag is omitted entirely when left at default.
- Workspaces now accept a git URL (cloned), an existing local path (copied into the service account's workspace and chowned; non-git dirs get `git init` so worktrees work), or blank for a sandbox.
- Multi-workspace support: add any number of workspaces; extras become `--add-workspace` flags in the service definition.
- macOS: 2s settle + one retry on `launchctl bootstrap` to avoid "Bootstrap failed: 5: Input/output error" when replacing a running daemon.

**v1.5 - Pool ID normalization** (all scripts)
- Cosmos pool IDs carry a `pool-` prefix; the Cosmos UI and URLs can show the bare UUID. Bare 36-char UUIDs are now auto-prefixed with a warning. Without this, the daemon loops on "unknown daemon pool" while appearing superficially connected.

**v1.4 - Honest registration detection** (macOS, Linux)
- "WebSocket connected" is only the transport handshake and is no longer treated as success. The script now requires a real pool-registration log line, fails fast with plain-English diagnoses on the two known rejections ("unknown daemon pool" = wrong ID or tenant mismatch; "not the daemon pool connector" = connector misconfigured), and detects connect/close reject loops.

**v1.3 - Network check correctness** (macOS, Linux, Windows)
- macOS `lsof` ORs selection filters by default; without `-a` the listener check swept in every TCP listener on the machine (AirPlay 5000/7000, Spotify, etc.) plus all daemon file descriptors. Fixed with `-a` to AND the filters.
- All platforms: only NON-loopback listeners fail the check; 127.0.0.1/::1 listeners are reported as informational. (In practice the daemon opens no listening ports at all - it is purely outbound.)
- Outer script now moves into the service account's home before spawning service-user shells, silencing `shell-init: getcwd` warnings.

**v1.2 - Run-from-anywhere fix** (macOS, Linux)
- Commands executed as the service account now `cd` into its own home first. Previously, running the installer from inside a `chmod 700` home directory crashed npm as the service user (`EACCES uv_cwd`) because child processes inherited an unreadable working directory.

**v1.1 - macOS group boundary fix** (macOS; loopback groundwork all platforms)
- The service account gets its own dedicated primary group and is removed from `staff`. All macOS home directories are group `staff` by default, so a `staff`-member service account could list any home directory set to 750. The validator now recommends `chmod 700` on any home directory it can still read and explicitly fails if the account is in `staff`.

**v1.0 - Initial release**
- Locked-down service account per OS, Auggie CLI installed under the account's own npm prefix, Service Account credential validation (`accessToken` + `tenantURL` + `scopes` array - the CLI silently rejects sessions missing the scopes array), always-on service wrappers (LaunchDaemon / hardened systemd / Scheduled Task), and the automated boundary validation suite.

## Uninstall

```bash
sudo ./setup-auggie-daemon-macos.sh --uninstall     # macOS
sudo ./setup-auggie-daemon-linux.sh --uninstall     # Linux
.\setup-auggie-daemon-windows.ps1 -Uninstall        # Windows
```

## Disclaimer

Community scripts, not an official Augment Code product. Review before running with root/admin rights, and dry-run on a test host before production or customer environments.