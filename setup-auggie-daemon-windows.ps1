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
  [string]$AuggieVersion = "0.32.0",
  [ValidateSet("","task","service")][string]$RunMode = "",
  [switch]$Uninstall
)
$ErrorActionPreference = "Stop"

function Assert-SafeRoot([string]$Path) {
  if (-not [IO.Path]::IsPathRooted($Path)) { throw "Root must be an absolute path." }
  $full = [IO.Path]::GetFullPath($Path)
  $volumeRoot = [IO.Path]::GetPathRoot($full)
  if ($full.TrimEnd('\') -eq $volumeRoot.TrimEnd('\')) { throw "Root cannot be a drive root." }
  if ($full -match '["&|<>^%!`\r\n]') { throw "Root contains characters unsafe for Windows service command handling." }
  foreach ($forbidden in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE)) {
    if ($forbidden -and $full.TrimEnd('\') -ieq ([IO.Path]::GetFullPath($forbidden)).TrimEnd('\')) {
      throw "Root cannot replace a Windows, Program Files, or user-profile directory."
    }
  }
  if (Test-Path $full) {
    $item = Get-Item -LiteralPath $full -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse-point Root: $full" }
  }
  return $full.TrimEnd('\')
}

function Assert-SafeServiceUser([string]$Name) {
  if ($Name -notmatch '^[A-Za-z][A-Za-z0-9._-]{0,19}$') { throw "SvcUser contains unsupported characters or exceeds 20 characters." }
  if ($Name -match '^(Administrator|Guest|DefaultAccount|WDAGUtilityAccount|SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$') {
    throw "Refusing reserved SvcUser '$Name'."
  }
}

function Get-CryptoRandomPassword([int]$Length = 28) {
  $classes = @('0123456789', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz', '!#$%&*')
  $all = ($classes -join '')
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $chars = New-Object 'System.Collections.Generic.List[char]'
  $nextIndex = {
    param([int]$ExclusiveMax)
    $limit = 256 - (256 % $ExclusiveMax)
    $byte = New-Object byte[] 1
    do { $rng.GetBytes($byte) } while ($byte[0] -ge $limit)
    return [int]($byte[0] % $ExclusiveMax)
  }
  try {
    foreach ($class in $classes) { $chars.Add($class[(& $nextIndex $class.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[(& $nextIndex $all.Length)]) }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
      $j = & $nextIndex ($i + 1)
      $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    return -join $chars
  } finally { $rng.Dispose() }
}

function Remove-SensitiveFile([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  $stream = $null
  try {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $zeros = New-Object byte[] 65536
    $remaining = $stream.Length
    while ($remaining -gt 0) {
      $count = [int][Math]::Min($zeros.Length, $remaining)
      $stream.Write($zeros, 0, $count); $remaining -= $count
    }
    $stream.Flush($true)
  } catch {
    Write-Warning "Could not overwrite temporary credential before removal."
  } finally {
    if ($stream) { $stream.Dispose() }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  }
}

Assert-SafeServiceUser $SvcUser
if ($DaemonName -notmatch '^[A-Za-z0-9._-]{1,128}$') { throw "DaemonName must use only letters, numbers, dot, underscore, and hyphen." }
if ($AuggieVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$') { throw "AuggieVersion must be an exact version, such as 0.32.0." }
$Root = Assert-SafeRoot $Root
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
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  if (Get-Service -Name $TaskName -ErrorAction SilentlyContinue) {
    Stop-Service $TaskName -Force -ErrorAction SilentlyContinue
    $winswExe = Join-Path $Root "service\$TaskName.exe"
    if (Test-Path $winswExe) { & $winswExe uninstall | Out-Null } else { sc.exe delete $TaskName | Out-Null }
  }
  Remove-SensitiveFile $CredPath
  $existingUser = Get-LocalUser -Name $SvcUser -ErrorAction SilentlyContinue
  if ($existingUser -and $existingUser.SID.Value -notmatch '-500$') { Remove-LocalUser -Name $SvcUser }
  $ans = Read-Host "Type DELETE to remove $Root (workspace, tools, and logs), or press Enter to keep it"
  if ($ans -eq "DELETE") { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction Stop }
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
if ($PoolId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
  $PoolId = "pool-$PoolId"; WRN "pool ID had no 'pool-' prefix; using $PoolId"
}
if ($PoolId -notmatch '^pool-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
  throw "Pool ID must be pool- followed by a UUID."
}

if (-not $SessionJson) {
  Write-Host "Service Account credential (session.json from app.augmentcode.com/settings/service-accounts)."
  $SessionJson = Read-Host "Path to session.json (blank to paste JSON instead)"
}
$tmpCred = New-TemporaryFile
trap {
  if ($tmpCred) { Remove-SensitiveFile $tmpCred.FullName }
  [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
  exit 1
}
if ($SessionJson) {
  if (-not (Test-Path $SessionJson)) { throw "File not found: $SessionJson" }
  Copy-Item $SessionJson $tmpCred -Force
} else {
  Write-Host "Paste the session JSON now (multi-line OK; input hidden). It ends automatically at the closing brace."
  $buf = ""; $depth = 0; $started = $false
  do {
    $secure = Read-Host -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $line = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $buf += $line + "`n"
    foreach ($ch in $line.ToCharArray()) {
      if ($ch -eq '{') { $depth++; $started = $true }
      elseif ($ch -eq '}') { $depth-- }
    }
    if ($buf.Length -gt 1MB) { throw "Pasted credential exceeds 1 MiB." }
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
$s = $null

if (-not $RepoUrl) { $RepoUrl = Read-Host "Primary workspace (git URL to clone / existing local path to COPY / blank = sandbox)" }
if ($MaxAgents -lt 0) {
  $ma = Read-Host "Max concurrent agent sessions [Enter = daemon default (100); 4-5 recommended on 8-16GB hosts]"
  if ($ma) { $MaxAgents = [int]$ma } else { $MaxAgents = 0; WRN "using daemon default (100 slots); consider a cap on small hosts" }
}
if ($MaxAgents -lt 0) { throw "MaxAgents cannot be negative after input processing." }

if (-not $RunMode) {
  Write-Host ""
  Write-Host "How should the daemon run persistently?"
  Write-Host "  [1] Scheduled Task (default) - starts at boot with no login, runs as the"
  Write-Host "      service account, auto-restarts on failure. No third-party software."
  Write-Host "      Managed in Task Scheduler (taskschd.msc), NOT in services.msc."
  Write-Host "  [2] Windows Service (via WinSW) - appears in services.msc, supervised by the"
  Write-Host "      Service Control Manager, works with SCOM/Datadog service monitoring."
  Write-Host "      Downloads the open-source WinSW wrapper (github.com/winsw/winsw, official"
  Write-Host "      release) into C:\augment\service."
  $rm = Read-Host "Choose [1/2, Enter = 1]"
  if ($rm -eq "2") { $RunMode = "service" } else { $RunMode = "task" }
}
Info "Run mode: $RunMode (one mechanism only - the other is removed if present)"

# Stop the prior instance before changing privileged files it can otherwise race.
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Stop-Service -Name $TaskName -Force -ErrorAction SilentlyContinue

# ---------- service account ----------
Info "Creating local service account '$SvcUser'"
$pwPlain = Get-CryptoRandomPassword
$pwSecure = ConvertTo-SecureString -String $pwPlain -AsPlainText -Force
if (Get-LocalUser -Name $SvcUser -ErrorAction SilentlyContinue) {
  $existingUser = Get-LocalUser -Name $SvcUser
  if ($existingUser.SID.Value -match '-500$') { throw "Refusing to repurpose the built-in administrator account." }
  if (Get-LocalGroupMember -Group "Administrators" -Member $SvcUser -ErrorAction SilentlyContinue) {
    throw "Existing account $SvcUser is an administrator; refusing to repurpose it."
  }
  WRN "user exists; resetting its password for the task registration"
  Set-LocalUser -Name $SvcUser -Password $pwSecure
} else {
  New-LocalUser -Name $SvcUser -Password $pwSecure -PasswordNeverExpires -AccountNeverExpires -Description "Auggie daemon service account" | Out-Null
  OK "created"
}
$pwSecure = $null
Set-LocalUser -Name $SvcUser -PasswordNeverExpires $true
# Ensure not in Administrators
Remove-LocalGroupMember -Group "Administrators" -Member $SvcUser -ErrorAction SilentlyContinue
# Grant "Log on as a batch job" (required for scheduled task with stored password)
$sid = (Get-LocalUser $SvcUser).SID.Value
$inf = Join-Path $env:TEMP "auggie-rights.inf"; $sdb = Join-Path $env:TEMP "auggie-rights.sdb"
secedit /export /cfg $inf /quiet
$cfg = Get-Content $inf
foreach ($right in @("SeBatchLogonRight","SeServiceLogonRight")) {
  $line = $cfg | Where-Object { $_ -match "^$right" }
  if ($line -and $line -notmatch [regex]::Escape($sid)) {
    $cfg = $cfg -replace "^$right\s*=\s*(.*)$", ($right + ' = $1,*' + $sid)
  } elseif (-not $line) {
    $cfg += "$right = *$sid"
  }
}
$cfg | Set-Content $inf
secedit /configure /db $sdb /cfg $inf /areas USER_RIGHTS /quiet
Remove-Item $inf,$sdb -ErrorAction SilentlyContinue
OK "granted 'Log on as a batch job' + 'Log on as a service'"

# ---------- directories + ACLs ----------
Info "Preparing $Root with a tight, non-inherited ACL"
if ((Test-Path $Root) -and ((Get-Item -LiteralPath $Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw "Refusing reparse-point Root: $Root"
}
if ((Test-Path $Workspace) -and ((Get-Item -LiteralPath $Workspace -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw "Refusing reparse-point workspace root: $Workspace"
}
New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
icacls $Root /inheritance:r | Out-Null
icacls $Root /grant "${SvcUser}:(OI)(CI)M" "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null

# ---------- auggie: installed INSIDE C:\augment so svc-augment can execute it ----------
Info "Installing @augmentcode/auggie@$AuggieVersion into $Root\npm (readable by the service account)"
$NpmPrefix = Join-Path $Root "npm"
if ((Test-Path $NpmPrefix) -and ((Get-Item -LiteralPath $NpmPrefix -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw "Refusing reparse-point npm prefix: $NpmPrefix"
}
New-Item -ItemType Directory -Force -Path $NpmPrefix | Out-Null
npm install -g --prefix $NpmPrefix "@augmentcode/auggie@$AuggieVersion" --loglevel=error
$AuggieCmd = Join-Path $NpmPrefix "auggie.cmd"
if (-not (Test-Path $AuggieCmd)) { throw "auggie install failed: $AuggieCmd not found" }
$ver = (& $AuggieCmd --version 2>$null | Select-Object -First 1)
if ($ver -match "(\d+)\.(\d+)") {
  $vMaj = [int]$Matches[1]; $vMin = [int]$Matches[2]
  if (($vMaj -eq 0) -and ($vMin -lt 28)) { throw "auggie $ver has a daemon startup bug on Windows. Upgrade required." }
}
OK "auggie $ver at $AuggieCmd"
icacls $NpmPrefix /inheritance:r | Out-Null
icacls $NpmPrefix /grant:r "${SvcUser}:(OI)(CI)RX" "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null

# repo (clone/copy as admin; the ACL above already grants the service account)
$AddWsDirs = @()
function Materialize-Ws([string]$src) {
  if ($src -match '^https?://[^/@:]+:[^/@]+@') { throw "Do not embed Git credentials in a repository URL; use a credential helper or SSH key." }
  $normalizedSource = $src.TrimEnd([char[]]@('/','\')).Replace('\','/')
  $leaf = ($normalizedSource -split '/')[-1]
  $name = $leaf -replace '\.git$',''
  if ($name -notmatch '^[A-Za-z0-9._ -]+$' -or $name -in @('.','..')) { throw "Workspace destination name contains unsupported characters: $name" }
  if (Test-Path $src -PathType Container) {
    $dest = Join-Path $Workspace $name
    if ((Test-Path $dest) -and ((Get-Item -LiteralPath $dest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing reparse-point workspace: $dest" }
    if (-not (Test-Path $dest)) {
      Write-Host "    copying local path $src -> $dest"
      Copy-Item $src $dest -Recurse
      if (-not (Test-Path (Join-Path $dest ".git"))) {
        Push-Location $dest; git init -q; git config user.email "svc@localhost"; git config user.name "svc-augment"; git add -A; git commit -qm import; Pop-Location
      }
    }
    return $dest
  } else {
    $dest = Join-Path $Workspace $name
    if ((Test-Path $dest) -and ((Get-Item -LiteralPath $dest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing reparse-point workspace: $dest" }
    if (-not (Test-Path $dest)) { git clone -- $src $dest }
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
if ((Test-Path $CredPath) -and ((Get-Item -LiteralPath $CredPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw "Refusing reparse-point credential destination: $CredPath"
}
Remove-SensitiveFile $CredPath
Copy-Item $tmpCred $CredPath -Force
Remove-SensitiveFile $tmpCred.FullName
$tmpCred = $null
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
  Info "Installing Windows Service '$TaskName' via WinSW (runs as $SvcUser, auto-start)"
  # WinSW ships from official GitHub releases (nssm.cc is a single-maintainer host
  # that intermittently 503s). WinSW requires the exe and xml to share a basename.
  $SvcDir  = Join-Path $Root "service"
  $WinswExe = Join-Path $SvcDir "$TaskName.exe"
  $WinswXml = Join-Path $SvcDir "$TaskName.xml"
  New-Item -ItemType Directory -Force -Path $SvcDir | Out-Null
  if (-not (Test-Path $WinswExe)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe" -OutFile $WinswExe
  }
  $expectedWinswHash = "05B82D46AD331CC16BDC00DE5C6332C1EF818DF8CEEFCD49C726553209B3A0DA"
  $actualWinswHash = (Get-FileHash -LiteralPath $WinswExe -Algorithm SHA256).Hash
  if ($actualWinswHash -ne $expectedWinswHash) { throw "WinSW v2.12.0 integrity verification failed." }
  # svc-augment needs read+execute on the wrapper; nobody else beyond admins
  icacls $SvcDir /inheritance:r | Out-Null
  icacls $SvcDir /grant "${SvcUser}:(OI)(CI)RX" "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null

  # Service config: NO credentials in the XML. WinSW v2 and v3 use different
  # serviceaccount schemas (a v3-style block is silently ignored by v2 and the
  # service lands on LocalSystem - caught by the validation suite in field
  # testing). The logon account is set through Win32_Service.Change instead,
  # so the password never touches disk or a child-process command line.
  $xmlEsc = { param($t) $t -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' }
  $svcXml = @"
<service>
  <id>$TaskName</id>
  <name>$TaskName</name>
  <description>Augment Auggie daemon (hardened service account: $SvcUser)</description>
  <executable>%SystemRoot%\System32\cmd.exe</executable>
  <arguments>/c ""$AuggieCmd" $(& $xmlEsc $argsLine)"</arguments>
  <workingdirectory>$RepoDir</workingdirectory>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="5 sec"/>
  <logpath>$Root</logpath>
  <log mode="append"/>
</service>
"@
  try {
    Set-Content -Path $WinswXml -Value $svcXml -Encoding UTF8
    & $WinswExe install | Out-Null
    # Configure SCM in-process so the password never appears in a child-process command line.
    $serviceObject = Get-CimInstance Win32_Service -Filter "Name='$TaskName'"
    $changeResult = Invoke-CimMethod -InputObject $serviceObject -MethodName Change -Arguments @{ StartName = $UserAccount; StartPassword = $pwPlain }
    if ($changeResult.ReturnValue -ne 0) { throw "Win32_Service.Change failed with code $($changeResult.ReturnValue)" }
    $pwPlain = $null
    & $WinswExe start | Out-Null
    Start-Sleep 3
    $svc = Get-Service $TaskName -ErrorAction Stop
    if ($svc.Status -ne "Running") { throw "service state: $($svc.Status)" }
    # Verify the logon account actually took (the exact failure field testing caught)
    $obj = (Get-CimInstance Win32_Service -Filter "Name='$TaskName'").StartName
    if ($obj -notmatch [regex]::Escape($SvcUser)) { throw "service logon is '$obj', expected $UserAccount" }
    OK "Windows Service '$TaskName' installed and running (logon: $obj) - visible in services.msc"
  } catch {
    $pwPlain = $null
    throw "Windows Service install failed: $_  (logs: $Root\$TaskName.out.log and .err.log)"
  }
}

Info "Waiting up to 90s for the daemon process"
$deadline = (Get-Date).AddSeconds(90); $proc = $null
$rootPattern = [regex]::Escape($Root)
$poolPattern = [regex]::Escape($PoolId)
while ((Get-Date) -lt $deadline) {
  $proc = Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -and $_.CommandLine -match $rootPattern -and
    $_.CommandLine -match '(?i)\bdaemon\b' -and $_.CommandLine -match "--pool-id\s+`"?$poolPattern"
  } | Select-Object -First 1
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