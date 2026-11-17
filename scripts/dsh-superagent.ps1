<#
.SYNOPSIS
Manages a local dsh-superagent service on Windows: one DSH profile, default `superagent`.

.DESCRIPTION
The Windows counterpart of `scripts/dsh-superagent`, which needs tmux, `ps`, and SIGINT. This script keeps the same
contract:

  `status`, `start`, and `restart` exit 0 while the service runs normally; 1 when it is stopped, duplicated,
  unreachable, or reporting a runtime error, which `restart` may fix; 2 when it runs while a component such as a Source
  reports an error; and 3 when it runs and waits for setup. A restart fixes neither 2 nor 3: they need a person.

Where POSIX uses a tmux session and `ps`, this script records the service PID in the control directory and finds
processes by their command line, so it also notices an instance started outside it. It writes one log per start and
keeps the newest 20.

Windows has no SIGINT for a process another console started: `stop` asks the orchestrator to pause through its own API,
waits two seconds for the request to land, and then terminates the process. Running Executor Sessions end with it.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('start', 'stop', 'restart', 'status')]
  [string]$Action,

  [string]$Profile = $(if ($env:DSH_SUPERAGENT_PROFILE) { $env:DSH_SUPERAGENT_PROFILE } else { 'superagent' }),

  [string]$Url = $(if ($env:DSH_SUPERAGENT_URL) { $env:DSH_SUPERAGENT_URL } else { 'http://127.0.0.1:3082' }),

  [double]$Timeout = 60,

  [double]$StopTimeout = 300,

  # For monitoring: never start or restart after an intentional stop.
  [switch]$RespectStop
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $root '.artifacts'
$control = Join-Path $artifacts ('control\profiles\' + $Profile)
$keepLogs = 20
$partError = 2
$setupWaits = 3

if ($Timeout -le 0 -or $StopTimeout -le 0) { throw 'Timeout and StopTimeout must be positive.' }
if ($Profile -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') { throw 'Profile must be a DSH profile name.' }
New-Item -ItemType Directory -Force -Path $control | Out-Null

function Get-ControlPath([string]$name) { return (Join-Path $control $name) }

<#
Returns whether a command line belongs to the main DSH service process for this profile: an argument `--profile <name>`
or `--profile=<name>`, and no `plugin` subcommand. Arguments are split on whitespace, so a path with spaces becomes
several words and only `--profile` and subcommands are inspected, as the POSIX script does.
#>
function Test-ServesProfile([string]$commandLine) {
  if (-not $commandLine) { return $false }
  $words = @($commandLine -split '\s+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim('"', "'") })
  $matched = $false
  $pending = $false
  for ($index = 1; $index -lt $words.Count; $index++) {
    $word = $words[$index]
    if ($pending) { if ($word -eq $Profile) { $matched = $true }; $pending = $false; continue }
    if ($word -eq '--profile') { $pending = $true; continue }
    if ($word -eq "--profile=$Profile") { $matched = $true; continue }
    # A CLI call such as `dsh --profile superagent plugin ...` is not the service.
    if ($word -eq 'plugin') { return $false }
  }
  return $matched
}

function Get-RecordedPid {
  $file = Get-ControlPath 'service.pid'
  if (-not (Test-Path $file)) { return 0 }
  $number = 0
  if ([int]::TryParse((Get-Content -Raw -ErrorAction SilentlyContinue $file).Trim(), [ref]$number)) { return $number }
  return 0
}

function Test-Alive([int]$processId) { return ($processId -gt 0) -and ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) }

function Test-Stopped { return (Test-Path (Get-ControlPath 'manually-stopped')) }

<# Returns the DSH service processes for this profile, including one started outside this script. #>
function Get-ServiceProcess {
  $found = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe' OR Name = 'dsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { Test-ServesProfile $_.CommandLine } |
    Select-Object -ExpandProperty ProcessId)
  $recorded = Get-RecordedPid
  if ((Test-Alive $recorded) -and ($found -notcontains $recorded)) { $found += $recorded }
  return @($found | Sort-Object -Unique)
}

<#
Reads health and setup status from the management API, or returns $null when unreachable. The endpoint and header match
the POSIX script.
#>
function Get-ServiceState {
  try {
    $response = Invoke-RestMethod -Uri ($Url.TrimEnd('/') + '/orchestrator/api/state') -Headers @{ 'x-orchestrator-request' = '1' } -TimeoutSec 2
  } catch { return $null }
  $health = if ($response.health) { $response.health } else { @{} }
  $setup = if ($response.setup) { $response.setup } else { @{} }
  $states = @{}
  $errors = @{}
  foreach ($name in $health.PSObject.Properties.Name) {
    $entry = $health.$name
    $state = if ($entry -is [System.Management.Automation.PSCustomObject]) { $entry.state } else { $null }
    $states[$name] = $state
    if ($state -eq 'error') {
      $errors[$name] = if ($entry -is [System.Management.Automation.PSCustomObject]) { "$($entry.detail)" } else { '' }
    }
  }
  # The state directory is optional in the answer: an older version or a partial payload simply has none.
  $directory = $null
  if ($setup.machine -and $setup.machine.PSObject.Properties['stateDir']) { $directory = "$($setup.machine.stateDir)" }
  return [pscustomobject]@{ health = $states; errors = $errors; setup = $setup.problem; feishu = $setup.feishuProblem
    stateDir = $directory }
}

function Test-RuntimeUp($current) {
  return ($null -ne $current) -and (($current.health['runtime'] -eq 'ready') -or ($current.health['runtime'] -eq 'paused'))
}

function Get-PartErrors($current) {
  $result = @{}
  foreach ($name in ($current.errors.Keys | Sort-Object)) { if ($name -ne 'runtime') { $result[$name] = $current.errors[$name] } }
  return $result
}

<# Computes the exit code from running PIDs and management API state. #>
function Get-Outcome([int[]]$pids, $current) {
  if (($pids.Count -ne 1) -or -not (Test-RuntimeUp $current)) { return 1 }
  if ($current.setup) { return $setupWaits }
  if ((Get-PartErrors $current).Count -gt 0) { return $partError }
  return 0
}

<# Prints the status report as JSON on stdout and returns the exit code, keeping the two apart. #>
function Write-Status([int[]]$pids) {
  $current = if ($pids.Count -gt 0) { Get-ServiceState } else { $null }
  $payload = [ordered]@{
    pids             = @($pids)
    cwd              = $root
    url              = $Url
    manually_stopped = (Test-Stopped)
    health           = if ($current) { $current.health } else { $null }
    errors           = if ($current) { $current.errors } else { $null }
    setup            = if ($current) { $current.setup } else { $null }
    feishu           = if ($current) { $current.feishu } else { $null }
  }
  [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 8))
  return (Get-Outcome $pids $current)
}

function Get-Status { return (Write-Status @(Get-ServiceProcess)) }

# Stopping deliberately does not pause processing: `POST executor/pause` is a persisted setting, so a pause made here
# would survive the restart and leave every later start unable to accept work. The two seconds it would buy before a
# forced termination are not worth that.

function Stop-Service([bool]$intentional = $true) {
  $pids = @(Get-ServiceProcess)
  if ($pids.Count -gt 1) { throw 'Multiple dsh-superagent processes found; refusing to choose one.' }
  # The state directory is needed after the process is gone: it names the lock a killed process cannot release.
  $stateDir = $null
  if ($pids.Count -gt 0) { $current = Get-ServiceState; if ($current) { $stateDir = $current.stateDir } }
  # Write the stop marker before stopping, so a monitor respects the intentional stop even if shutdown fails part way.
  if ($intentional) { Set-Content -Path (Get-ControlPath 'manually-stopped') -Value ((Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')) }
  foreach ($processId in $pids) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
  $deadline = (Get-Date).AddSeconds($StopTimeout)
  while ((Get-Date) -lt $deadline) {
    if (@(Get-ServiceProcess).Count -eq 0) { break }
    Start-Sleep -Milliseconds 500
  }
  if (@(Get-ServiceProcess).Count -gt 0) { throw 'Stop timed out; a process still runs. Check status.' }
  # A terminated process releases nothing, and dsh-superagent treats its state lock as held for 30 s after its last
  # heartbeat, so the next start would fail to activate. With no process left, the lock is stale by definition.
  if ($stateDir) {
    $lock = $stateDir.TrimEnd('/', '\') + '.lock'
    if (Test-Path $lock) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $lock }
  }
  Remove-Item -Force -ErrorAction SilentlyContinue (Get-ControlPath 'service.pid')
  if ($intentional) { Write-Output 'dsh-superagent stopped. Automatic recovery is paused until start/restart.' }
  else { Write-Output 'dsh-superagent stopped.' }
}

function Remove-OldLogs {
  $pattern = '^dsh-superagent-' + [regex]::Escape($Profile) + '-\d{8}-\d{6}-\d+\.log$'
  $logs = @(Get-ChildItem -Path $artifacts -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $pattern } | Sort-Object LastWriteTime)
  if ($logs.Count -gt $keepLogs) { $logs[0..($logs.Count - $keepLogs - 1)] | Remove-Item -Force -ErrorAction SilentlyContinue }
}

<#
Resolves how to start the `dsh` command. npm writes three shims beside each other, and only `cmd.exe` can run the `.cmd`
one: `Get-Command dsh` returns the `.ps1` first, which `cmd` cannot start at all.
#>
function Resolve-Dsh {
  $found = @(Get-Command dsh -All -ErrorAction SilentlyContinue)
  foreach ($candidate in $found) {
    if ($candidate.Source -match '\.(cmd|bat|exe)$') {
      # `cmd /c` parses its own quoting, so the whole line travels as one argument.
      return [pscustomobject]@{ Program = $(if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' })
        Arguments = @('/d', '/s', '/c', ('"{0}" --profile {1} --no-open' -f $candidate.Source, $Profile)) }
    }
  }
  $script = $found | Where-Object { $_.Source -match '\.ps1$' } | Select-Object -First 1
  if ($script) {
    return [pscustomobject]@{ Program = 'powershell.exe'
      Arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script.Source), '--profile', $Profile, '--no-open') }
  }
  throw 'dsh must be on PATH.'
}

<# Waits for the service process that the started command creates, so the recorded PID is the DSH process itself. #>
function Wait-ServicePid([int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    $pids = @(Get-ServiceProcess)
    if ($pids.Count -ge 1) { return $pids[0] }
    Start-Sleep -Milliseconds 250
  }
  return 0
}

function Start-Service {
  $pids = @(Get-ServiceProcess)
  if ($pids.Count -gt 1) { throw 'Multiple dsh-superagent processes found; refusing to start another.' }
  if ($pids.Count -eq 0) {
    $launch = Resolve-Dsh
    if (Get-ServiceState) { throw 'An existing orchestrator answers at this URL; refusing duplicate startup.' }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $log = Join-Path $artifacts ("dsh-superagent-{0}-{1}-{2}.log" -f $Profile, $stamp, $PID)
    New-Item -ItemType File -Force -Path $log | Out-Null
    Remove-OldLogs
    # The started shell is not the service: the DSH process it creates is found by its command line and recorded.
    Start-Process -FilePath $launch.Program -ArgumentList $launch.Arguments -RedirectStandardOutput $log `
      -RedirectStandardError ($log + '.err') -WindowStyle Hidden | Out-Null
    $servicePid = Wait-ServicePid ([Math]::Max(5, [Math]::Min($Timeout, 30)))
    if ($servicePid -le 0) {
      $tail = (Get-Content -ErrorAction SilentlyContinue ($log + '.err') | Select-Object -Last 3) -join ' '
      throw ("The service did not start; see " + $log + $(if ($tail) { ': ' + $tail } else { '' }))
    }
    Set-Content -Path (Get-ControlPath 'service.pid') -Value $servicePid
    Write-Output ('Log: ' + $log)
  } else {
    Set-Content -Path (Get-ControlPath 'service.pid') -Value $pids[0]
    Write-Output ('dsh-superagent already running (PID {0}); no duplicate started.' -f $pids[0])
  }
  Remove-Item -Force -ErrorAction SilentlyContinue (Get-ControlPath 'manually-stopped')
  $deadline = (Get-Date).AddSeconds($Timeout)
  while ((Get-Date) -lt $deadline) {
    $current = Get-ServiceState
    if ((@(Get-ServiceProcess).Count -gt 0) -and (Test-RuntimeUp $current)) {
      $code = Get-Status
      if ($current.setup) {
        Write-Output ('dsh-superagent is waiting for setup: ' + "$($current.setup.detail)")
        Write-Output 'Open the URL DSH printed in the log, then the dsh-superagent overview.'
      }
      if ($current.feishu) {
        Write-Output ('dsh-superagent runs without Feishu: ' + "$($current.feishu.detail)")
        Write-Output 'Fix it on the Feishu card of the Source settings.'
      }
      foreach ($name in (Get-PartErrors $current).Keys) {
        Write-Output ('{0} reports an error, which a restart does not fix: {1}' -f $name, $current.errors[$name])
      }
      return $code
    }
    Start-Sleep -Seconds 1
  }
  Get-Status | Out-Null
  throw 'Startup health check timed out; inspect the log. Any running process was left intact.'
}

# One control operation at a time, so a monitor and an operator never start or stop together.
$lock = $null
try {
  try { $lock = [System.IO.File]::Open((Get-ControlPath 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
  catch { throw 'Another dsh-superagent control operation is in progress.' }
  if ($RespectStop -and ($Action -in @('start', 'restart')) -and (Test-Stopped)) {
    Write-Output 'Intentional stop is active; automatic recovery skipped.'
    exit 0
  }
  switch ($Action) {
    'status' { exit (Get-Status) }
    default {
      if ($Action -in @('stop', 'restart')) { Stop-Service -intentional:($Action -eq 'stop') }
      if ($Action -in @('start', 'restart')) { exit (Start-Service) }
    }
  }
  exit 0
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
} finally {
  if ($lock) { $lock.Dispose() }
}
