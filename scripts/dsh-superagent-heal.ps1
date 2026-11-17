<#
.SYNOPSIS
The hourly repair for a Windows host: starts dsh-superagent when it is not running.

.DESCRIPTION
The counterpart of the POSIX cron entry in docs/006-deployment.md. It asks `status` and acts on its exit code:

  0  the service runs normally
  1  stopped, unreachable, or duplicated: `start -RespectStop` brings it back, and respects a deliberate stop
  2  a component such as a Source reports an error, which a restart does not fix
  3  the service waits for setup, which needs a person

Codes 2 and 3 are left alone: restarting would only hide them. Each run appends one line to `.artifacts/heal.log`, and
keeps the check quiet otherwise.
#>
[CmdletBinding()]
param([string]$Profile = $(if ($env:DSH_SUPERAGENT_PROFILE) { $env:DSH_SUPERAGENT_PROFILE } else { 'superagent' }))

$root = Split-Path -Parent $PSScriptRoot
$log = Join-Path (Join-Path $root '.artifacts') 'heal.log'
$script = Join-Path $PSScriptRoot 'dsh-superagent.ps1'
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script status -Profile $Profile *> $null
$code = $LASTEXITCODE
Add-Content -Path $log -Value "$stamp status=$code"

if ($code -ne 1) { exit 0 }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script start -Profile $Profile -RespectStop 2>&1 |
  ForEach-Object { Add-Content -Path $log -Value "$stamp start: $_" }
Add-Content -Path $log -Value "$stamp start exit=$LASTEXITCODE"
exit 0
