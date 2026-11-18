# Watchdog — поднимает плашку, трей и веб-панель, если они упали.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = 'C:\Users\User\MediaToast'
$log = Join-Path $root 'watchdog.log'

function Write-WLog([string]$m) {
  try {
    if ((Get-Item -LiteralPath $log -ErrorAction SilentlyContinue).Length -gt 80000) { Remove-Item -LiteralPath $log -Force }
  } catch { }
  try { Add-Content -LiteralPath $log -Value ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m) -Encoding UTF8 } catch { }
}

function Test-Alive([string]$name) {
  $pf = Join-Path $root ($name + '.pid')
  if (-not (Test-Path -LiteralPath $pf)) { return $false }
  $procId = Get-Content -LiteralPath $pf -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($procId -notmatch '^\d+$') { return $false }
  return [bool](Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue)
}

function Start-Component([string]$vbs) {
  $path = Join-Path $root $vbs
  if (-not (Test-Path -LiteralPath $path)) { return }
  Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $path + '"')
}

# плашка
if (-not (Test-Alive 'toast')) {
  Write-WLog 'toast down, starting'
  Start-Component 'MediaToast.vbs'
  Start-Sleep -Seconds 4
}
# трей
if (-not (Test-Alive 'tray')) {
  Write-WLog 'tray down, starting'
  Start-Component 'MusicTray.vbs'
  Start-Sleep -Seconds 3
}
# веб-панель поднимаем только если она уже использовалась (есть web.pid)
if ((Test-Path -LiteralPath (Join-Path $root 'web.pid')) -and -not (Test-Alive 'web')) {
  Write-WLog 'web down, starting'
  Start-Component 'MusicWeb.vbs'
}
