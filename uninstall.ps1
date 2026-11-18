#Requires -Version 5.1
<#
    Удаление MediaToast: останавливает процесс и убирает автозагрузку.
    Файлы остаются на месте.
#>
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $root 'toast.pid'

if (Test-Path -LiteralPath $pidFile) {
  $old = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($old -match '^\d+$') {
    Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue
    Write-Output ('Остановлен процесс ' + $old)
  }
  Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'MediaToast.lnk'
if (Test-Path -LiteralPath $lnk) {
  Remove-Item -LiteralPath $lnk -Force
  Write-Output 'Автозагрузка отключена.'
} else {
  Write-Output 'Ярлыка в автозагрузке не было.'
}
