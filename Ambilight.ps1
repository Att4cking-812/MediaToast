# Ambilight — подсветка краёв, которая берёт цвета с самого экрана.
# Запуск: powershell -NoProfile -Sta -ExecutionPolicy Bypass -File Ambilight.ps1
param(
  [int]$Thickness = 150,
  [int]$Segments = 6,
  [int]$Fps = 8,
  [int]$Inset = 170
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Drawing
[void][System.Reflection.Assembly]::Load('System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')

$root = $PSScriptRoot
$logPath = Join-Path $root 'ambilight.log'
$script:enabledFlag = Join-Path $root 'ambilight.on'

function Write-Log([string]$m) {
  try {
    if ((Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue).Length -gt 100000) { Remove-Item -LiteralPath $logPath -Force }
  } catch { }
  try { Add-Content -LiteralPath $logPath -Value ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m) -Encoding UTF8 } catch { }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\BrickyardAmbilight')
$ok = $false
try { $ok = $mutex.WaitOne(0) } catch { $ok = $false }
if (-not $ok) { Write-Log 'already running'; exit 0 }
try { Set-Content -LiteralPath (Join-Path $root 'ambilight.pid') -Value $PID -Encoding ASCII } catch { }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AmbWin {
  [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
"@

function Set-ClickThrough($win) {
  try {
    $helper = New-Object Windows.Interop.WindowInteropHelper($win)
    $h = $helper.Handle
    if ($h -eq [IntPtr]::Zero) { return }
    $ex = [AmbWin]::GetWindowLong($h, -20)
    $ex = $ex -bor 0x20 -bor 0x80 -bor 0x08000000
    [void][AmbWin]::SetWindowLong($h, -20, $ex)
  } catch { }
}

# ---------------------------------------------------------------- окна
$sw = [System.Windows.SystemParameters]::PrimaryScreenWidth
$sh = [System.Windows.SystemParameters]::PrimaryScreenHeight
$sides = @('top', 'bottom', 'left', 'right')
$windows = @{}
$segments = @{}

function New-EdgeWindow([string]$side) {
  $w = New-Object Windows.Window
  $w.WindowStyle = 'None'
  $w.AllowsTransparency = $true
  $w.Background = [Windows.Media.Brushes]::Transparent
  $w.ShowInTaskbar = $false
  $w.Topmost = $true
  $w.ShowActivated = $false
  $w.Focusable = $false
  $w.IsHitTestVisible = $false
  $w.ResizeMode = 'NoResize'
  $w.Opacity = 0

  $root = New-Object Windows.Controls.Grid
  $list = @()

  $horizontal = ($side -eq 'top' -or $side -eq 'bottom')
  for ($i = 0; $i -lt $Segments; $i++) {
    $b = New-Object Windows.Controls.Border
    $brush = New-Object Windows.Media.LinearGradientBrush
    $brush.StartPoint = New-Object Windows.Point(0.5, 0)
    $brush.EndPoint = New-Object Windows.Point(0.5, 1)
    $brush.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.Color]::FromArgb(0, 0, 0, 0), 0.0)))
    $brush.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.Color]::FromArgb(0, 0, 0, 0), 1.0)))
    $b.Background = $brush
    if ($horizontal) {
      [void]$root.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
      [Windows.Controls.Grid]::SetColumn($b, $i)
    } else {
      [void]$root.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
      [Windows.Controls.Grid]::SetRow($b, $i)
    }
    [void]$root.Children.Add($b)
    $list += $b
  }
  $w.Content = $root

  switch ($side) {
    'top'    { $w.Left = 0; $w.Top = 0; $w.Width = $sw; $w.Height = $Thickness }
    'bottom' { $w.Left = 0; $w.Top = $sh - $Thickness; $w.Width = $sw; $w.Height = $Thickness }
    'left'   { $w.Left = 0; $w.Top = 0; $w.Width = $Thickness; $w.Height = $sh }
    'right'  { $w.Left = $sw - $Thickness; $w.Top = 0; $w.Width = $Thickness; $w.Height = $sh }
  }

  $w.Show()
  Set-ClickThrough $w
  $w.Visibility = 'Hidden'
  return @{ Window = $w; Segments = $list; Side = $side }
}

foreach ($s in $sides) {
  $built = New-EdgeWindow $s
  $windows[$s] = $built.Window
  $segments[$s] = $built.Segments
}

# направление градиента внутрь экрана
function Apply-Orientation([string]$side, $border) {
  $brush = $border.Background
  switch ($side) {
    'top'    { $brush.StartPoint = New-Object Windows.Point(0.5, 0.0); $brush.EndPoint = New-Object Windows.Point(0.5, 1.0) }
    'bottom' { $brush.StartPoint = New-Object Windows.Point(0.5, 1.0); $brush.EndPoint = New-Object Windows.Point(0.5, 0.0) }
    'left'   { $brush.StartPoint = New-Object Windows.Point(0.0, 0.5); $brush.EndPoint = New-Object Windows.Point(1.0, 0.5) }
    'right'  { $brush.StartPoint = New-Object Windows.Point(1.0, 0.5); $brush.EndPoint = New-Object Windows.Point(0.0, 0.5) }
  }
}
foreach ($s in $sides) { foreach ($b in $segments[$s]) { Apply-Orientation $s $b } }

# ---------------------------------------------------------------- сэмплинг экрана
$script:colors = @{}
foreach ($s in $sides) { $script:colors[$s] = @(0..($Segments - 1) | ForEach-Object { @(20, 20, 28) }) }

function Sample-Strip([string]$side) {
  try {
    $stripLong = 48
    $stripShort = 4
    if ($side -eq 'top' -or $side -eq 'bottom') {
      $srcW = [int]$sw - (2 * $Inset)
      $srcH = 40
      $srcX = $Inset
      $srcY = if ($side -eq 'top') { $Inset } else { [int]$sh - $Inset - 40 }
      $src = New-Object Drawing.Bitmap $srcW, $srcH
    } else {
      $srcW = 40
      $srcH = [int]$sh - (2 * $Inset)
      $srcX = if ($side -eq 'left') { $Inset } else { [int]$sw - $Inset - 40 }
      $srcY = $Inset
      $src = New-Object Drawing.Bitmap $srcW, $srcH
    }

    $g = [Drawing.Graphics]::FromImage($src)
    $g.CopyFromScreen($srcX, $srcY, 0, 0, (New-Object Drawing.Size $srcW, $srcH))
    $g.Dispose()

    $horizontal = ($side -eq 'top' -or $side -eq 'bottom')
    $smallW = if ($horizontal) { $stripLong } else { $stripShort }
    $smallH = if ($horizontal) { $stripShort } else { $stripLong }
    $small = New-Object Drawing.Bitmap $smallW, $smallH
    $g2 = [Drawing.Graphics]::FromImage($small)
    $g2.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
    $g2.DrawImage($src, (New-Object Drawing.Rectangle 0, 0, $smallW, $smallH), (New-Object Drawing.Rectangle 0, 0, $srcW, $srcH), [Drawing.GraphicsUnit]::Pixel)
    $g2.Dispose()
    $src.Dispose()

    $result = @()
    for ($i = 0; $i -lt $Segments; $i++) {
      $r = 0; $gg = 0; $b = 0; $n = 0
      if ($horizontal) {
        $from = [int][Math]::Floor($smallW * $i / $Segments)
        $to = [int][Math]::Floor($smallW * ($i + 1) / $Segments) - 1
        for ($x = $from; $x -le $to; $x++) {
          for ($y = 0; $y -lt $smallH; $y++) {
            $c = $small.GetPixel($x, $y)
            $r += $c.R; $gg += $c.G; $b += $c.B; $n++
          }
        }
      } else {
        $from = [int][Math]::Floor($smallH * $i / $Segments)
        $to = [int][Math]::Floor($smallH * ($i + 1) / $Segments) - 1
        for ($y = $from; $y -le $to; $y++) {
          for ($x = 0; $x -lt $smallW; $x++) {
            $c = $small.GetPixel($x, $y)
            $r += $c.R; $gg += $c.G; $b += $c.B; $n++
          }
        }
      }
      if ($n -gt 0) { $result += , @([int]($r / $n), [int]($gg / $n), [int]($b / $n)) } else { $result += , @(30, 30, 40) }
    }
    $small.Dispose()
    return $result
  } catch {
    return $null
  }
}

function Update-Colors {
  foreach ($side in $sides) {
    $new = Sample-Strip $side
    if (-not $new) { continue }
    $old = $script:colors[$side]
    $merged = @()
    for ($i = 0; $i -lt $Segments; $i++) {
      $o = $old[$i]; $n = $new[$i]
      $merged += , @(
        [int]($o[0] * 0.65 + $n[0] * 0.35),
        [int]($o[1] * 0.65 + $n[1] * 0.35),
        [int]($o[2] * 0.65 + $n[2] * 0.35))
    }
    $script:colors[$side] = $merged

    for ($i = 0; $i -lt $Segments; $i++) {
      $c = $merged[$i]
      $border = $segments[$side][$i]
      $brush = $border.Background
      $brush.GradientStops[0].Color = [Windows.Media.Color]::FromArgb(215, $c[0], $c[1], $c[2])
      $brush.GradientStops[1].Color = [Windows.Media.Color]::FromArgb(0, $c[0], $c[1], $c[2])
    }
  }
}

# ---------------------------------------------------------------- музыка
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  })[0]

function Await($op, $type) {
  $t = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
  if (-not $t.Wait(4000)) { throw 'timeout' }
  return $t.Result
}

$wtManager = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$script:manager = $null
try { $script:manager = Await ($wtManager::RequestAsync()) $wtManager } catch { }

function Test-Playing {
  try {
    if (-not $script:manager) { return $false }
    foreach ($s in $script:manager.GetSessions()) {
      if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') { return $true }
    }
  } catch { }
  return $false
}

$script:opacity = 0.0
$script:targetOpacity = 0.0

# ---------------------------------------------------------------- таймеры
$sampleTimer = New-Object Windows.Threading.DispatcherTimer
$sampleTimer.Interval = [TimeSpan]::FromMilliseconds([int](1000 / $Fps))
$sampleTimer.Add_Tick({
    try {
      $on = Test-Path -LiteralPath $script:enabledFlag
      $playing = Test-Playing
      $script:targetOpacity = if ($on -and $playing) { 0.9 } else { 0.0 }

      if ($on) {
        Update-Colors
        foreach ($s in $sides) {
          if ($script:targetOpacity -gt 0 -and $windows[$s].Visibility -ne 'Visible') { $windows[$s].Visibility = 'Visible' }
        }
      }

      $script:opacity = $script:opacity + (($script:targetOpacity - $script:opacity) * 0.25)
      foreach ($s in $sides) {
        $windows[$s].Opacity = [Math]::Max(0, [Math]::Min(1, $script:opacity))
        if ($script:opacity -le 0.02 -and $script:targetOpacity -eq 0) { $windows[$s].Visibility = 'Hidden' }
      }
    } catch { }
  })
$sampleTimer.Start()
Write-Log 'ambilight started'

$app = New-Object Windows.Application
$app.Add_DispatcherUnhandledException({
    param($sender, $e)
    try { Write-Log ('dispatcher: ' + $e.Exception.Message) } catch { }
    $e.Handled = $true
  })
[void]$app.Run()
