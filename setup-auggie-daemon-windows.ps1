<#
.SYNOPSIS
  Creates a locked-down Windows local service account, links an Augment (Cosmos)
  Service Account credential, registers the Auggie daemon as a Scheduled Task
  running as that account, and validates the OS-level security boundary.

.NOTES
  RECOMMENDED ALTERNATIVE: WSL2 with systemd. The official supported Windows
  platform for the Auggie CLI is WSL; inside WSL2 run setup-auggie-daemon-linux.sh
  unchanged and Windows user profiles are not visible to it at all.
  This native script is for hosts where WSL is not an option.

  Requires: Windows 10/11 or Server, Node.js 22+, git, auggie CLI >= 0.28.0.
  Run from an elevated (Administrator) PowerShell.

.USAGE
  .\setup-auggie-daemon-windows.ps1
  .\setup-auggie-daemon-windows.ps1 -Uninstall
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  [string]$SvcUser     = "svc-augment",
  [string]$Root        = "C:\augment",
  [string]$PoolId      = $env:POOL_ID,
  [string]$SessionJson = $env:SESSION_JSON_PATH,
  [string]$RepoUrl     = $env:REPO_URL,
  [int]   $MaxAgents   = -1,   # -1 = prompt; 0 = daemon default (100); N = cap
  [string[]]$ExtraWorkspaces = @(),
  [string]$DaemonName  = "$($env:COMPUTERNAME.ToLower())-bridge-01",
  [ValidateSet("","task","service")][string]$RunMode = "",
  [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
$TaskName  = "AuggieDaemon"
$Workspace = Join-Path $Root "workspace"
$RepoDir   = Join-Path $Workspace "repo-a"
$CredPath  = Join-Path $Root "sa-session.json"
$LogOut    = Join-Path $Root "daemon.out.log"

$script:Pass = 0; $script:Fail = 0; $script:Warn = 0
function OK($m)   { Write-Host "  [PASS] $m" -ForegroundColor Green;  $script:Pass++ }
function BAD($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:Fail++ }
function WRN($m)  { Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:Warn++ }
function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }

# ---------- uninstall ----------
if ($Uninstall) {
  Info "Uninstalling..."
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  if (Get-Service -Name $TaskName -ErrorAction SilentlyContinue) {
    Stop-Service $TaskName -Force -ErrorAction SilentlyContinue
    $nssmExe = Join-Path $Root "nssm\nssm.exe"
    if (Test-Path $nssmExe) { & $nssmExe remove $TaskName confirm | Out-Null } else { sc.exe delete $TaskName | Out-Null }
  }
  Get-Process -Name node -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -match "auggie" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  net user $SvcUser /delete 2>$null
  $ans = Read-Host "Delete $Root (workspace + credential)? [y/N]"
  if ($ans -eq "y") { Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue }
  Write-Host "Uninstalled."; exit 0
}

# ---------- preflight ----------
Info "Preflight checks"
foreach ($cmd in @("node","npm","git")) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "$cmd not found on PATH. Install it first." }
}
$nodeMajor = [int](node -e "console.log(process.versions.node.split('.')[0])")
if ($nodeMajor -lt 20) { throw "Node $nodeMajor too old; Node 22+ required." }
elseif ($nodeMajor -lt 22) { WRN "Node $nodeMajor; Node 22+ recommended." } else { OK "Node $nodeMajor" }

# auggie is installed later, into C:\augment\npm, so the service account can read it.
# A per-user npm install under the admin's profile is UNREACHABLE by svc-augment
# (our own ACL boundary blocks it) and the task exits with code 1.

# ---------- inputs ----------
if (-not $PoolId) { $PoolId = Read-Host "Daemon pool ID (Cosmos > Environments > your Daemon Pool)" }
if (-not $PoolId) { throw "Pool ID is required." }
# Normalize: Cosmos pool IDs carry a 'pool-' prefix; auto-add it for bare UUIDs.
if ($PoolId -match '^[0-9a-fA-F-]{36}$') { $PoolId = "pool-$PoolId"; WRN "pool ID had no 'pool-' prefix; using $PoolId" }

if (-not $SessionJson) {
  Write-Host "Service Account credential (session.json from app.augmentcode.com/settings/service-accounts)."
  $SessionJson = Read-Host "Path to session.json (blank to paste JSON instead)"
}
$tmpCred = New-TemporaryFile
if ($SessionJson) {
  if (-not (Test-Path $SessionJson)) { throw "File not found: $SessionJson" }
  Copy-Item $SessionJson $tmpCred -Force
} else {
  Write-Host "Paste the session JSON now (multi-line OK; input hidden). It ends automatically at the closing brace."
  $buf = ""; $depth = 0; $started = $false
  do {
    $secure = Read-Host -AsSecureString
    $line = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    $buf += $line + "`n"
    foreach ($ch in $line.ToCharArray()) {
      if ($ch -eq '{') { $depth++; $started = $true }
      elseif ($ch -eq '}') { $depth-- }
    }
  } while (-not $started -or $depth -gt 0)
  Set-Content -Path $tmpCred -Value $buf -NoNewline; $buf = $null
}

Info "Validating credential format"
try {
  $s = Get-Content $tmpCred -Raw | ConvertFrom-Json
  $problems = @()
  if (-not $s.accessToken) { $problems += "missing accessToken" }
  if (-not $s.tenantURL)   { $problems += "missing tenantURL" }
  if ($null -eq $s.scopes -or $s.scopes -isnot [System.Array]) { $problems += 'scopes must be an array (e.g. ["email"]) - the CLI rejects the session without it' }
  if ($problems) { throw ("Invalid session.json: " + ($problems -join "; ")) }
  OK "credential OK (tenant: $($s.tenantURL))"
} catch { throw "Credential validation failed: $_" }

if (-not $RepoUrl) { $RepoUrl = Read-Host "Primary workspace (git URL to clone / existing local path to COPY / blank = sandbox)" }
if ($MaxAgents -lt 0) {
  $ma = Read-Host "Max concurrent agent sessions [Enter = daemon default (100); 4-5 recommended on 8-16GB hosts]"
  if ($ma) { $MaxAgents = [int]$ma } else { $MaxAgents = 0; WRN "using daemon default (100 slots); consider a cap on small hosts" }
}

if (-not $RunMode) {
  Write-Host ""
  Write-Host "How should the daemon run persistently?"
  Write-Host "  [1] Scheduled Task (default) - starts at boot with no login, runs as the"
  Write-Host "      service account, auto-restarts on failure. No third-party software."
  Write-Host "      Managed in Task Scheduler (taskschd.msc), NOT in services.msc."
  Write-Host "  [2] Windows Service (via NSSM) - appears in services.msc, supervised by the"
  Write-Host "      Service Control Manager, works with SCOM/Datadog service monitoring."
  Write-Host "      Downloads the open-source NSSM wrapper (nssm.cc) into C:\augment\nssm."
  $rm = Read-Host "Choose [1/2, Enter = 1]"
  if ($rm -eq "2") { $RunMode = "service" } else { $RunMode = "task" }
}
Info "Run mode: $RunMode (one mechanism only - the other is removed if present)"

# ---------- service account ----------
Info "Creating local service account '$SvcUser'"
$pwPlain = -join ((48..57)+(65..90)+(97..122)+(33,35,36,37,38,42) | Get-Random -Count 28 | ForEach-Object {[char]$_})
if (Get-LocalUser -Name $SvcUser -ErrorAction SilentlyContinue) {
  WRN "user exists; resetting its password for the task registration"
  net user $SvcUser $pwPlain | Out-Null
} else {
  net user $SvcUser $pwPlain /add /passwordchg:no /y | Out-Null
  OK "created"
}
Set-LocalUser -Name $SvcUser -PasswordNeverExpires $true
# Ensure not in Administrators
Remove-LocalGroupMember -Group "Administrators" -Member $SvcUser -ErrorAction SilentlyContinue
# Grant "Log on as a batch job" (required for scheduled task with stored password)
$sid = (Get-LocalUser $SvcUser).SID.Value
$inf = Join-Path $env:TEMP "auggie-rights.inf"; $sdb = Join-Path $env:TEMP "auggie-rights.sdb"
secedit /export /cfg $inf /quiet
$cfg = Get-Content $inf
$line = $cfg | Where-Object { $_ -match "^SeBatchLogonRight" }
if ($line -and $line -notmatch [regex]::Escape($sid)) {
  $cfg = $cfg -replace "^SeBatchLogonRight\s*=\s*(.*)$", ('SeBatchLogonRight = $1,*' + $sid)
} elseif (-not $line) {
  $cfg += "SeBatchLogonRight = *$sid"
}
$cfg | Set-Content $inf
secedit /configure /db $sdb /cfg $inf /areas USER_RIGHTS /quiet
Remove-Item $inf,$sdb -ErrorAction SilentlyContinue
OK "granted 'Log on as a batch job'"

# ---------- directories + ACLs ----------
Info "Preparing $Root with a tight, non-inherited ACL"
New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
icacls $Root /inheritance:r | Out-Null
icacls $Root /grant "${SvcUser}:(OI)(CI)M" "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null

# ---------- auggie: installed INSIDE C:\augment so svc-augment can execute it ----------
Info "Installing @augmentcode/auggie into $Root\npm (readable by the service account)"
$NpmPrefix = Join-Path $Root "npm"
New-Item -ItemType Directory -Force -Path $NpmPrefix | Out-Null
npm install -g --prefix $NpmPrefix @augmentcode/auggie --loglevel=error
$AuggieCmd = Join-Path $NpmPrefix "auggie.cmd"
if (-not (Test-Path $AuggieCmd)) { throw "auggie install failed: $AuggieCmd not found" }
$ver = (& $AuggieCmd --version 2>$null | Select-Object -First 1)
if ($ver -match "(\d+)\.(\d+)") {
  $vMaj = [int]$Matches[1]; $vMin = [int]$Matches[2]
  if (($vMaj -eq 0) -and ($vMin -lt 28)) { throw "auggie $ver has a daemon startup bug on Windows. Upgrade required." }
}
OK "auggie $ver at $AuggieCmd"

# repo (clone/copy as admin; the ACL above already grants the service account)
$AddWsDirs = @()
function Materialize-Ws([string]$src) {
  if (Test-Path $src -PathType Container) {
    $dest = Join-Path $Workspace (Split-Path $src -Leaf)
    if (-not (Test-Path $dest)) {
      Write-Host "    copying local path $src -> $dest"
      Copy-Item $src $dest -Recurse
      if (-not (Test-Path (Join-Path $dest ".git"))) {
        Push-Location $dest; git init -q; git config user.email "svc@localhost"; git config user.name "svc-augment"; git add -A; git commit -qm import; Pop-Location
      }
    }
    return $dest
  } else {
    $dest = Join-Path $Workspace ((Split-Path $src -Leaf) -replace "\.git$","")
    if (-not (Test-Path $dest)) { git clone $src $dest }
    return $dest
  }
}
if (-not (Test-Path (Join-Path $RepoDir ".git"))) {
  if ($RepoUrl) {
    $RepoDir = Materialize-Ws $RepoUrl
  } else {
    New-Item -ItemType Directory -Force -Path $RepoDir | Out-Null
    Push-Location $RepoDir
    git init -q; git config user.email "svc@localhost"; git config user.name "svc-augment"
    Set-Content README.md "# sandbox"; git add .; git commit -qm init
    Pop-Location
    WRN "no repo URL; created empty sandbox repo (worktrees need a git repo)"
  }
}
foreach ($w in $ExtraWorkspaces) { if ($w) { $AddWsDirs += (Materialize-Ws $w) } }

# ---------- credential ----------
Info "Installing credential with owner-only ACL"
Copy-Item $tmpCred $CredPath -Force
Remove-Item $tmpCred -Force
icacls $CredPath /inheritance:r | Out-Null
icacls $CredPath /grant "${SvcUser}:R" "Administrators:F" | Out-Null

# ---------- persistence: scheduled task OR windows service (never both) ----------
$argsLine = "daemon --pool-id $PoolId --augment-session-json `"$CredPath`" --workspace `"$RepoDir`""
foreach ($w in $AddWsDirs) { $argsLine += " --add-workspace `"$w`"" }
if ($MaxAgents -gt 0) { $argsLine += " --max-agents $MaxAgents" }
$argsLine += " --allow-indexing --name $DaemonName"
$UserAccount = "$env:COMPUTERNAME\$SvcUser"   # neither mechanism resolves the '.\user' shorthand reliably

# Mutual exclusion: remove whichever mechanism is NOT chosen (and stale copies of the chosen one)
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
if (Get-Service -Name $TaskName -ErrorAction SilentlyContinue) {
  Stop-Service $TaskName -Force -ErrorAction SilentlyContinue
  sc.exe delete $TaskName | Out-Null
  Start-Sleep 2
}

if ($RunMode -eq "task") {
  Info "Registering scheduled task '$TaskName' (runs as $SvcUser at startup)"
  # Wrap in cmd /c so stdout/stderr land in the log (Task Scheduler captures nothing by itself)
  $cmdArg = '/c ""' + $AuggieCmd + '" ' + $argsLine + ' >> "' + $LogOut + '" 2>&1"'
  $action  = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument $cmdArg -WorkingDirectory $RepoDir
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 3650)
  try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
      -User $UserAccount -Password $pwPlain -RunLevel Limited -ErrorAction Stop | Out-Null
    $pwPlain = $null
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    OK "task registered and started (as $UserAccount)"
  } catch {
    $pwPlain = $null
    throw "Scheduled task registration failed: $_  (verify svc-augment exists and has 'Log on as a batch job')"
  }
} else {
  Info "Installing Windows Service '$TaskName' via NSSM (runs as $SvcUser, auto-start)"
  $NssmDir = Join-Path $Root "nssm"
  $NssmExe = Join-Path $NssmDir "nssm.exe"
  if (-not (Test-Path $NssmExe)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $env:TEMP "nssm.zip"
    Invoke-WebRequest "https://nssm.cc/release/nssm-2.24.zip" -OutFile $zip
    Expand-Archive $zip -DestinationPath $env:TEMP\nssm-x -Force
    New-Item -ItemType Directory -Force -Path $NssmDir | Out-Null
    Copy-Item "$env:TEMP\nssm-x\nssm-2.24\win64\nssm.exe" $NssmExe -Force
    Remove-Item $zip -Force; Remove-Item "$env:TEMP\nssm-x" -Recurse -Force
  }
  try {
    & $NssmExe install $TaskName "$env:SystemRoot\System32\cmd.exe" | Out-Null
    & $NssmExe set $TaskName AppParameters ('/c ""' + $AuggieCmd + '" ' + $argsLine + '"') | Out-Null
    & $NssmExe set $TaskName AppDirectory $RepoDir | Out-Null
    & $NssmExe set $TaskName AppStdout $LogOut | Out-Null
    & $NssmExe set $TaskName AppStderr $LogOut | Out-Null
    & $NssmExe set $TaskName AppExit Default Restart | Out-Null
    & $NssmExe set $TaskName AppRestartDelay 5000 | Out-Null
    & $NssmExe set $TaskName Start SERVICE_AUTO_START | Out-Null
    & $NssmExe set $TaskName ObjectName $UserAccount $pwPlain | Out-Null   # NSSM grants 'Log on as a service'
    $pwPlain = $null
    & $NssmExe start $TaskName | Out-Null
    Start-Sleep 3
    $svc = Get-Service $TaskName -ErrorAction Stop
    if ($svc.Status -ne "Running") { throw "service state: $($svc.Status)" }
    OK "Windows Service '$TaskName' installed and running (as $UserAccount) - visible in services.msc"
  } catch {
    $pwPlain = $null
    throw "Windows Service install failed: $_  (check $LogOut and: nssm.exe status $TaskName)"
  }
}

Info "Waiting up to 90s for the daemon process"
$deadline = (Get-Date).AddSeconds(90); $proc = $null
while ((Get-Date) -lt $deadline) {
  $proc = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "auggie" -and $_.CommandLine -match "daemon" } | Select-Object -First 1
  if ($proc) { break }; Start-Sleep 3
}
if ($proc) { OK "daemon process running (pid $($proc.ProcessId))" } else { WRN "daemon process not detected yet - check Task Scheduler history and $LogOut" }

# ---------- validation ----------
Write-Host ""; Info "VALIDATION: OS boundary"
if (Get-LocalGroupMember -Group "Administrators" -Member $SvcUser -ErrorAction SilentlyContinue) {
  BAD "$SvcUser IS in Administrators"
} else { OK "not in Administrators" }

# Effective-access check on another user's profile
$otherProfile = Get-ChildItem C:\Users -Directory |
  Where-Object { $_.Name -notin @($SvcUser,"Public","Default","Default User","All Users") } |
  Select-Object -First 1
if ($otherProfile) {
  $acl = icacls $otherProfile.FullName 2>$null | Out-String
  if ($acl -match [regex]::Escape($SvcUser)) { BAD "$SvcUser appears in ACL of $($otherProfile.FullName)" }
  else { OK "no ACL grant on other user profiles (NTFS denies by default)" }
}
$aclCred = icacls $CredPath | Out-String
if (($aclCred -match [regex]::Escape($SvcUser)) -and ($aclCred -notmatch "Users:")) { OK "credential ACL restricted to $SvcUser + Administrators" }
else { BAD "credential ACL looser than expected: run icacls $CredPath" }

if ($proc) {
  $ownerInfo = Invoke-CimMethod -InputObject $proc -MethodName GetOwner
  if ($ownerInfo.User -eq $SvcUser) { OK "daemon runs as $SvcUser" } else { BAD "daemon runs as $($ownerInfo.User)" }
  # Only NON-loopback listeners are a network exposure; 127.0.0.1/::1 listeners
  # (Node IPC etc.) are unreachable from the network.
  $listen = Get-NetTCPConnection -State Listen -OwningProcess $proc.ProcessId -ErrorAction SilentlyContinue
  $external = $listen | Where-Object { $_.LocalAddress -notin @("127.0.0.1","::1") }
  if ($external) {
    BAD ("daemon listening on a NON-loopback address: " + (($external | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" }) -join " "))
  } elseif ($listen) {
    OK ("listeners are loopback-only (" + (($listen | Select-Object -First 3 | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" }) -join " ") + ") - not network-reachable")
  } else {
    OK "no listening ports at all (outbound-only)"
  }
}

Write-Host ""
Write-Host "================================================================"
Write-Host " RESULT: $script:Pass passed / $script:Fail failed / $script:Warn warnings"
Write-Host "================================================================"
@"

MANUAL CHECKS (require Cosmos):
 1. Pool page should show '1 daemon online' named '$DaemonName'.
 2. Route a test session to the pool; ask it to run:  dir C:\Users\<yourname>\Desktop
    Expected: Access is denied  <- proves the boundary against a live agent.
 3. Session attribution should show the SERVICE ACCOUNT, not a person.
 4. From YOUR login:  auggie daemon --pool-id $PoolId --name imposter-test
    Expected: "daemon user is not the daemon pool connector".

FINAL HARDENING (apply LAST, after everything works):
  secpol.msc > Local Policies > User Rights Assignment > "Deny log on locally" > add $SvcUser

Ops:
$(if ($RunMode -eq "task") {
"  status:    Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo   (LastTaskResult 267009 = running)
  restart:   Stop-ScheduledTask -TaskName $TaskName; Start-ScheduledTask -TaskName $TaskName
  note:      lives in Task Scheduler (taskschd.msc), NOT services.msc"
} else {
"  status:    Get-Service $TaskName    (also visible in services.msc)
  restart:   Restart-Service $TaskName"
})
  logs:      Get-Content $LogOut -Tail 30
  uninstall: .\setup-auggie-daemon-windows.ps1 -Uninstall   (removes task or service)
"@ | Write-Host
if ($script:Fail -gt 0) { exit 1 }