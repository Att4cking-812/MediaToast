#Requires -Version 5.1
<#
    Установка MediaToast + MusicTray: ярлыки в автозагрузке и запуск.
    Права администратора не нужны.
#>
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1 = Join-Path $root 'MediaToast.ps1'
$vbs = Join-Path $root 'MediaToast.vbs'
$trayPs1 = Join-Path $root 'MusicTray.ps1'
$trayVbs = Join-Path $root 'MusicTray.vbs'
$ico = Join-Path $root 'App.ico'

if (-not (Test-Path -LiteralPath $ps1)) { throw 'MediaToast.ps1 не найден рядом с install.ps1' }

# остановить текущие экземпляры
foreach ($f in @('toast.pid', 'tray.pid')) {
  $pidFile = Join-Path $root $f
  if (Test-Path -LiteralPath $pidFile) {
    $old = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($old -match '^\d+$') { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
  }
}
Start-Sleep -Milliseconds 500

$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell

$targets = @(
  @{ Lnk = (Join-Path $startup 'MediaToast.lnk'); Vbs = $vbs; Desc = 'MediaToast — плашка «сейчас играет»' },
  @{ Lnk = (Join-Path $startup 'MusicTray.lnk'); Vbs = $trayVbs; Desc = 'MusicTray — управление музыкой' }
)

foreach ($t in $targets) {
  if (-not (Test-Path -LiteralPath $t.Vbs)) { continue }
  $sc = $ws.CreateShortcut($t.Lnk)
  $sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
  $sc.Arguments = '"' + $t.Vbs + '"'
  $sc.WorkingDirectory = $root
  if (Test-Path -LiteralPath $ico) { $sc.IconLocation = $ico + ',0' }
  $sc.Description = $t.Desc
  $sc.Save()
  Write-Output ('Автозагрузка: ' + $t.Lnk)
}

Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"')
if (Test-Path -LiteralPath $trayVbs) {
  Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $trayVbs + '"')
}
Start-Sleep -Seconds 4

$newPid = Get-Content -LiteralPath (Join-Path $root 'toast.pid') -ErrorAction SilentlyContinue | Select-Object -First 1
if ($newPid -and (Get-Process -Id ([int]$newPid) -ErrorAction SilentlyContinue)) {
  Write-Output ('MediaToast запущен, PID ' + $newPid)
  Write-Output ('Лог: ' + (Join-Path $root 'toast.log'))
} else {
  Write-Output 'Не удалось запустить плашку. Проверь лог и попробуй вручную:'
  Write-Output ('  powershell -NoProfile -Sta -ExecutionPolicy Bypass -File "' + $ps1 + '"')
}

if (Test-Path -LiteralPath $trayVbs) {
  $trayPid = Get-Content -LiteralPath (Join-Path $root 'tray.pid') -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($trayPid -and (Get-Process -Id ([int]$trayPid) -ErrorAction SilentlyContinue)) {
    Write-Output ('MusicTray запущен, PID ' + $trayPid)
  } else {
    Write-Output 'MusicTray не запустился — смотри tray.log.'
  }
}
