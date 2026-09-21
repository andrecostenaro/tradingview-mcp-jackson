<#
.SYNOPSIS
  Launch TradingView Desktop with Chrome DevTools Protocol enabled, including
  Microsoft Store (MSIX) installs.

.DESCRIPTION
  scripts\launch_tv_debug.bat only finds classic installs. It also probes
  %PROGRAMFILES%\WindowsApps, but that directory has restrictive ACLs which
  block directory listing, so the probe fails on Store installs.

  This script resolves the executable via Get-AppxPackage instead, which does
  not require listing WindowsApps. Direct execution of the binary works even
  though enumerating the folder does not.

  CDP cannot be enabled on an already-running process, so TradingView is
  force-closed first. Close any open order ticket before running.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\launch_tv_msix.ps1
  powershell -ExecutionPolicy Bypass -File scripts\launch_tv_msix.ps1 -Port 9333
  powershell -ExecutionPolicy Bypass -File scripts\launch_tv_msix.ps1 -DetectOnly
#>
[CmdletBinding()]
param(
  [int]    $Port = 9222,
  [int]    $TimeoutSeconds = 60,
  [switch] $DetectOnly
)

function Resolve-TradingViewExe {
  # MSIX / Microsoft Store install
  $pkg = Get-AppxPackage -Name '*TradingView*' -ErrorAction SilentlyContinue |
           Sort-Object Version -Descending | Select-Object -First 1
  if ($pkg) {
    $exe = Join-Path $pkg.InstallLocation 'TradingView.exe'
    if (Test-Path $exe) { return $exe }
  }

  # Classic installs
  foreach ($p in @(
      "$env:LOCALAPPDATA\TradingView\TradingView.exe",
      "$env:ProgramFiles\TradingView\TradingView.exe",
      "${env:ProgramFiles(x86)}\TradingView\TradingView.exe")) {
    if ($p -and (Test-Path $p)) { return $p }
  }

  # Last resort: PATH
  $cmd = Get-Command TradingView.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  return $null
}

$exe = Resolve-TradingViewExe
if (-not $exe) {
  Write-Error "TradingView nao encontrado (verificados: MSIX via Get-AppxPackage, caminhos classicos, PATH)."
  exit 1
}
Write-Host "TradingView encontrado em: $exe"
if ($DetectOnly) { exit 0 }

if (Get-Process TradingView -ErrorAction SilentlyContinue) {
  Write-Host "Fechando instancia em execucao..."
  taskkill /F /IM TradingView.exe 2>&1 | Out-Null
  Start-Sleep -Seconds 3
}

Write-Host "Iniciando com --remote-debugging-port=$Port ..."
try {
  Start-Process -FilePath $exe -ArgumentList "--remote-debugging-port=$Port" -ErrorAction Stop
} catch {
  Write-Error "Falha ao iniciar: $($_.Exception.Message)"
  exit 1
}

Write-Host "Aguardando CDP responder..."
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  try {
    $r = Invoke-RestMethod -Uri "http://localhost:$Port/json/version" -TimeoutSec 3 -ErrorAction Stop
    Write-Host "CDP ativo na porta $Port  ($($r.Browser))"
    exit 0
  } catch { }
}
Write-Error "CDP nao respondeu em ${TimeoutSeconds}s."
exit 1
