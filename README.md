# Auggie Daemon: Locked-Down Service Account Installers

One script per OS that provisions everything needed to run the [Auggie daemon](https://docs.augmentcode.com) under a **dedicated, least-privileged local service account** linked to an **Augment Service Account** (Cosmos identity), then **validates the security boundary** automatically.

Why: by default the daemon runs with the full OS permissions of whoever launches it. These installers instead run it as a dedicated account, preventing access to other users' private files and preventing writes outside the managed daemon tree in strict mode.

| OS | Script | Runs the daemon via |
|---|---|---|
| macOS | `setup-auggie-daemon-macos.sh` | LaunchDaemon (hidden service user) |
| Linux / WSL2 | `setup-auggie-daemon-linux.sh` | Hardened systemd unit (`ProtectHome`, `ProtectSystem=strict`) |
| Windows (native) | `setup-auggie-daemon-windows.ps1` | Your choice at onboarding: Scheduled Task (default) or Windows Service via WinSW - both as a local service account |

For customer-owned Google Cloud deployments using private Rocky Linux 8 images,
see [`deploy/README.md`](deploy/README.md). The bundle includes GKE Standard and
Autopilot Helm profiles, a customer-built bootstrap runtime, and direct-host or
rootless-container GCE/MIG options with Google Secret Manager integration.

On Windows, **WSL2 + the Linux script is the recommended path** (WSL is the officially supported Windows platform for the CLI, and the systemd sandboxing is the strongest boundary). The native PowerShell script is for hosts where WSL isn't an option.

## Before you run anything (Cosmos side, done once by an Enterprise admin)

1. **Create the Service Account + token:** app.augmentcode.com/settings/service-accounts → Add Service Account → Add API token → **download `session.json`**. Tokens don't expire; rotate by issuing a new one and deleting the old.
2. **Create a connector-backed Daemon Pool:** Cosmos → Environments → Create → Daemon Pool. Set the **connector to the service account** (only daemons authenticating as it can join) and visibility to **Shared/Tenant**. Copy the **pool ID**.

## Getting the credential onto the daemon host (do this safely)

The `session.json` downloads via browser on the admin's machine. It is a bearer credential; treat it like a password:

- **Preferred:** copy it over an authenticated channel: `scp session.json admin@daemonhost:/tmp/` then run the installer pointing at that path. The installer moves it into place with owner-only permissions and you should **delete the original** afterward (`rm` / secure-delete on both the download folder and `/tmp`).
- **Alternative:** run the installer and choose the **paste option**. Input is hidden, the pretty-printed multi-line `session.json` can be pasted as-is (capture ends automatically at the closing brace), and it is written straight to the final location with `0600`/restricted ACL, never stored elsewhere.
- **Never** email it, put it in chat, commit it, or place it in a shared drive. If it may have been exposed, revoke the token in the Service Accounts page and issue a new one.

The scripts validate the JSON before installing: it must contain `accessToken`, `tenantURL`, **and** `scopes` as an array. A missing `scopes` array is silently rejected by the CLI and is the single most common cause of "auth worked yesterday" failures.

## Security boundary and trust model

These installers reduce host access; they do **not** create a complete sandbox for mutually untrusted agents:

- Agent commands run as the same service account as the daemon. That identity can read its own Augment session credential and everything in its workspace. OS file permissions cannot distinguish the daemon from child commands using the same identity.
- Linux `strict` mode makes files outside `/srv/augment` read-only and hides user homes, but normal world-readable system files remain readable. It does not restrict outbound destinations.
- macOS and Windows enforce account and filesystem boundaries but do not provide Linux mount-namespace isolation.
- A writable workspace intentionally permits code changes. The installed Auggie CLI and Windows service wrapper are made read-only to the service account to prevent agent-level persistence through executable replacement.

Use a dedicated, least-privileged Augment Service Account for each trust boundary, restrict who can route sessions to its pool, apply Auggie tool-permission policies, restrict egress at the host/network layer when needed, and rotate the token after any potentially untrusted session. For hostile multi-tenant workloads, use an ephemeral VM or container boundary per tenant/session rather than relying on these account installers alone.

## Usage

### macOS
```bash
chmod +x setup-auggie-daemon-macos.sh
sudo ./setup-auggie-daemon-macos.sh
# non-interactive:
sudo POOL_ID=pool-xxxx SESSION_JSON_PATH=/tmp/session.json \
  WORKSPACE_SRC=git@github.com:org/repo.git EXTRA_WORKSPACES="/path/to/local-repo,git@github.com:org/repo2.git" \
  MAX_AGENTS=4 ./setup-auggie-daemon-macos.sh   # MAX_AGENTS="" keeps the daemon default (100)
```

### Linux / WSL2
```bash
chmod +x setup-auggie-daemon-linux.sh
sudo ./setup-auggie-daemon-linux.sh
# hardening levels: HARDENING=strict (default) | full | off
sudo POOL_ID=pool-xxxx SESSION_JSON_PATH=/tmp/session.json HARDENING=strict \
  WORKSPACE_SRC=git@github.com:org/repo.git MAX_AGENTS=4 AUGGIE_VERSION=0.32.0 \
  ./setup-auggie-daemon-linux.sh
```
WSL2 note: enable systemd first (`/etc/wsl.conf` → `[boot]\nsystemd=true`, then `wsl --shutdown`).

### Windows (native)
```powershell
# Elevated PowerShell
Set-ExecutionPolicy -Scope Process Bypass
.\setup-auggie-daemon-windows.ps1
# non-interactive:
.\setup-auggie-daemon-windows.ps1 -PoolId pool-xxxx -SessionJson C:\tmp\session.json `
  -RepoUrl https://github.com/org/repo.git -RunMode task -MaxAgents 4
# -RunMode task|service (service = WinSW, visible in services.msc); -MaxAgents 0 keeps the daemon default (100)
# -ExtraWorkspaces @("C:\path\to\local-repo","https://github.com/org/repo2.git") for multi-repo
```

## What every script does

1. Preflight: Node 22+ (20 minimum) and git.
2. Prompts for pool ID, credential (path or hidden multi-line paste), max agents (Enter = daemon default), one or more workspaces (git URL / local path / sandbox), and on Windows the run mode (Scheduled Task or Windows Service). All overridable via env vars/parameters for unattended installs.
3. Creates the locked-down account: hidden non-admin user with a dedicated primary group (macOS), `--system` account with `nologin` and home outside `/home` (Linux), non-admin local user with batch + service logon rights (Windows).
4. Installs a pinned Auggie version (default `0.32.0`, overridable with `AUGGIE_VERSION` / `-AuggieVersion`) where the service account can execute but not modify it: under a root-owned npm prefix (macOS/Linux) or inside the ACL'd `C:\augment\npm` tree (Windows; Windows enforces auggie >= 0.28.0). Clones/copies your workspaces or creates a git sandbox so worktrees function.
5. Installs the credential at the service account's `~/.augment/session.json` (macOS/Linux) or via `--augment-session-json` (Windows), locked to owner-only.
6. Registers the always-on wrapper (LaunchDaemon / systemd / Scheduled Task or WinSW service) and waits for real pool **registration** in the logs (macOS/Linux) or the daemon process running as the service account (Windows) - a mere websocket handshake is not treated as success, and known Cosmos rejections are diagnosed in plain English.
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

- `MAX_AGENTS` (default: the daemon's own 100 slots when left blank): each concurrent session can use 0.5 to 2 GB RAM, so set 4-5 on an 8-16 GB host and archive completed sessions in Cosmos to reclaim memory. Leave blank only on hosts sized for it.
- Linux `HARDENING=strict` makes the whole filesystem read-only to agents outside `/srv/augment`. If a workflow legitimately needs other paths, add `ReadWritePaths=` lines to the unit or use `HARDENING=full`.
- Never point `--workspace` at the account's home directory itself; indexing is blocked there and pool sessions will fail to start.
- The installer pins Auggie to `0.32.0` by default to avoid silently installing a different release. Upgrade explicitly by rerunning the installer with `AUGGIE_VERSION=x.y.z` (macOS/Linux) or `-AuggieVersion x.y.z` (Windows), then re-run validation.

## Validated environments and support status

Every configuration below was executed end to end against a **live Cosmos daemon pool** (Augment `e2` tenant). At one point all three OSes had daemons registered to the same pool simultaneously, confirming horizontal slot pooling. Boundary validations ran against real user data on each host, and the negative tests (permission denials, identity rejection) were verified, not assumed.

### Field-validated (ran here, passing)

| OS / build | Environment | Persistence mechanism | Runtime | Validation result |
|---|---|---|---|---|
| macOS 26.5.1 (25F80) | MacBook Pro, Apple Silicon - physical multi-user machine | LaunchDaemon (`launchctl`) | Node 23, auggie 0.32.0 | Full suite passing: hidden non-admin account with dedicated primary group (not `staff`), other homes denied at `chmod 700`, zero listening ports, credential 0600, boot persistence, live pool registration |
| Ubuntu 26.04 LTS (aarch64, kernel 7.0) | Multipass VM on Apple Silicon, 2 vCPU / 6 GB, systemd | systemd unit, `HARDENING=strict` | Node 22, auggie 0.32.0 | Full suite passing: `ProtectHome` + `ProtectSystem=strict` enforced, `/home` invisible inside the service mount namespace (verified via `nsenter`), decoy-user boundary test, boot persistence |
| Windows Server 2022 | GCP `e2-standard-2` (us-east1), fresh image | **Scheduled Task** mode | Node 22.14, auggie 0.32.0 | Passing: non-admin local account with batch-logon right, non-inherited ACLs on `C:\augment`, other profiles denied by NTFS, task running as `svc-augment`, no listening ports |
| Windows Server 2022 | same VM | **Windows Service** mode (WinSW v2.12.0) | Node 22.14, auggie 0.32.0 | Passing 12/0: service visible in services.msc, logon verified as `svc-augment` via StartName read-back, password never written to disk, SCM supervision, no listening ports |

### Expected to work (same mechanisms, not run here)

- **WSL2 + the Linux script** - WSL is Augment's *officially supported* Windows platform for the Auggie CLI, and WSL2 runs systemd, so the Ubuntu-validated path applies unchanged. Enable systemd in `/etc/wsl.conf` first.
- **Other systemd distros** (Debian, RHEL/Rocky, Amazon Linux 2023) - the script uses only `useradd`, `npm`, `git`, and standard systemd directives. RHEL-family note: shell path is `/usr/sbin/nologin` (already what the script uses).
- **macOS on Intel** - no Apple Silicon-specific code; Homebrew paths for both architectures are on the daemon's PATH.
- **Windows 10/11 desktop** - same account/ACL/task mechanisms as Server 2022; the deny-interactive-logon step matters more on a shared desktop.

### Known constraints (upstream, not this repo)

- Augment platform requirements: Enterprise plan for Service Accounts; auggie **>= 0.28.0 on Windows** (earlier versions have a daemon startup bug); Node 22 recommended (20 minimum per docs).
- Officially supported CLI platforms per Augment docs: **macOS, Linux, Windows via WSL**. Native Windows (both modes in this repo) is a field-proven pattern, not the documented platform.
- Laptops sleep: a closed MacBook lid drops the daemon until wake. Production deployments belong on always-on hosts.
- The pool ID must include its `pool-` prefix (the installer auto-corrects bare UUIDs).
- A first-party service installer (`auggie daemon install`) is on Augment's roadmap and will eventually supersede the wrappers here.

### What the validation suite proved on each host (the claims a security reviewer can check)

1. The service account is non-admin, hidden/non-interactive, and on macOS holds its own primary group.
2. It cannot read any other user's home directory or profile, and cannot write outside its own tree - verified by attempting it, not by inspecting config.
3. The daemon process is owned by the service account (the suite caught and blocked a silent SYSTEM escalation during development - see v2.3.2).
4. The daemon opens **no listening ports**; connectivity is outbound-only WSS to Augment.
5. The credential file is owner-only (0600 / restricted ACL), and in Windows service mode the password never exists on disk.
6. A daemon presenting any identity other than the pool's connector service account is rejected by Cosmos at connect.

## Version history

Every finding below came from real installs during field testing on macOS, Ubuntu, and Windows Server - all validated end to end against a live Cosmos pool. Nine real defects were caught this way; each entry names the failure and the fix.

Repository release tags (for example, `v2.4.0`) version this installer and deployment bundle. They are independent of the Auggie CLI version selected with `AUGGIE_VERSION` / `-AuggieVersion` or the Helm `auggie.version` value. Tags are immutable release points. When a security fix also applies to an older supported release line, it may be issued as a patch release from that line after the affected platforms are requalified; customers do not need to adopt the GCP deployment bundle to consume an installer-only backport.

**v2.4.0 - Security audit hardening and customer-hosted GCP deployments** (all platforms)
- Eliminated user-controlled shell interpolation in Unix workspace setup, escaped generated systemd/plist arguments, validated pool/account/daemon/path inputs, and rejected managed-path symlinks/reparse points.
- Pinned the Auggie package version and made installed daemon binaries read-only to the service account after installation.
- Added WinSW SHA-256 verification, cryptographic Windows password generation, in-process Windows account/service configuration, guaranteed temporary-credential cleanup, and precise daemon process discovery.
- Corrected the documented trust boundary: same-identity agent commands can read the daemon's own credential, world-readable files and allowed network destinations; use ephemeral tenant/session isolation for hostile workloads.
- Added the customer-hosted `deploy/` bundle: a production Helm chart for GKE Standard and Autopilot, hardened and standard profiles, StatefulSet workspace/PVC modes, Workload Identity and Secret Manager CSI integration, customer-built Rocky Linux 8-compatible bootstrap runtime, GCE direct/rootless-container startup paths, Terraform examples, and local validation automation.
- Validated shell syntax/static analysis, Helm lint/rendering and negative configuration cases, Kubernetes schemas, Terraform formatting, integration assertions, and secret-pattern checks. Customer image builds and live GKE/GCE canaries remain environment-specific release qualification steps.

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
.\setup-auggie-daemon-windows.ps1 -Uninstall        # Windows (removes the task or the service)
```

## Disclaimer

Community scripts, not an official Augment Code product. Review before running with root/admin rights, and dry-run on a test host before production or customer environments.