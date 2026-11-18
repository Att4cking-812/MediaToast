#Requires -Version 5.1
<#
    Установка MediaToast: ярлык в автозагрузке + запуск.
    Права администратора не нужны.
#>
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1 = Join-Path $root 'MediaToast.ps1'
$vbs = Join-Path $root 'MediaToast.vbs'
$ico = Join-Path $root 'App.ico'

if (-not (Test-Path -LiteralPath $ps1)) { throw 'MediaToast.ps1 не найден рядом с install.ps1' }
if (-not (Test-Path -LiteralPath $vbs)) { throw 'MediaToast.vbs не найден' }

# остановить текущий экземпляр
$pidFile = Join-Path $root 'toast.pid'
if (Test-Path -LiteralPath $pidFile) {
  $old = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($old -match '^\d+$') { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500

# ярлык в автозагрузке
$startup = [Environment]::GetFolderPath('Startup')
$lnk = Join-Path $startup 'MediaToast.lnk'
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath = (Join-Path $env:WINDIR 'System32\wscript.exe')
$sc.Arguments = '"' + $vbs + '"'
$sc.WorkingDirectory = $root
if (Test-Path -LiteralPath $ico) { $sc.IconLocation = $ico + ',0' }
$sc.Description = 'MediaToast — плашка «сейчас играет»'
$sc.Save()
Write-Output ('Автозагрузка: ' + $lnk)

# запуск
Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"')
Start-Sleep -Seconds 4

$newPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
if ($newPid -and (Get-Process -Id ([int]$newPid) -ErrorAction SilentlyContinue)) {
  Write-Output ('MediaToast запущен, PID ' + $newPid)
  Write-Output ('Лог: ' + (Join-Path $root 'toast.log'))
} else {
  Write-Output 'Не удалось запустить. Проверь лог и попробуй вручную:'
  Write-Output ('  powershell -NoProfile -Sta -ExecutionPolicy Bypass -File "' + $ps1 + '"')
}
