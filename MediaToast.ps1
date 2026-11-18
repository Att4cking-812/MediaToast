# MediaToast 2.0 — плашка «сейчас играет» в левом верхнем углу.
# Плавное появление/уход, обложка с лёгким зумом, показ времени трека.
# Запуск: powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File MediaToast.ps1

param(
  [switch]$Demo,
  [string]$DemoArt = ''
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
[void][System.Reflection.Assembly]::Load('System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')

$logPath = Join-Path $PSScriptRoot 'toast.log'
$pidPath = Join-Path $PSScriptRoot 'toast.pid'

function Write-Log([string]$message) {
  try {
    if ((Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue).Length -gt 250000) { Remove-Item -LiteralPath $logPath -Force }
  } catch { }
  try { Add-Content -LiteralPath $logPath -Value ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $message) -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- один экземпляр
$mutex = New-Object System.Threading.Mutex($false, 'Local\BrickyardMediaToast')
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0) } catch { $hasMutex = $false }
if (-not $hasMutex) {
  Write-Log 'already running, exit'
  exit 0
}

# подчистить старый pid-файл
try {
  $oldPid = Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($oldPid -match '^\d+$' -and [int]$oldPid -ne $PID) {
    $old = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
    if ($old) {
      $cmd = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $old.Id) -ErrorAction SilentlyContinue).CommandLine
      if ($cmd -and $cmd -like '*MediaToast.ps1*') { Stop-Process -Id $old.Id -Force -ErrorAction SilentlyContinue }
    }
  }
} catch { }
try { Set-Content -LiteralPath $pidPath -Value $PID -Encoding ASCII } catch { }

# ---------------------------------------------------------------- громкость
$csPath = Join-Path $PSScriptRoot 'AudioEndpoint.cs'
try { Add-Type -TypeDefinition ([IO.File]::ReadAllText($csPath, [Text.Encoding]::UTF8)) -Language CSharp -ErrorAction Stop }
catch { Write-Log ('audio compile fail: ' + $_.Exception.Message) }

# ---------------------------------------------------------------- WinRT медиа
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  })[0]

function Await($op, $type) {
  $asTask = $asTaskGeneric.MakeGenericMethod($type)
  $task = $asTask.Invoke($null, @($op))
  if (-not $task.Wait(6000)) { throw 'async timeout' }
  return $task.Result
}

$wtManager = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$wtProps = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
$wtStream = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$wtInput = [Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$asStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@($wtInput))

$sessionManager = $null
try { $sessionManager = Await ($wtManager::RequestAsync()) $wtManager } catch { Write-Log ('manager fail: ' + $_.Exception.Message) }

$script:currentSession = $null
$script:artCacheKey = ''
$script:artCacheArt = $null
$script:emptyTicks = 0

function Refresh-SessionManager {
  try {
    $script:sessionManager = Await ($wtManager::RequestAsync()) $wtManager
    Write-Log 'manager refreshed'
    return $true
  } catch {
    Write-Log ('manager refresh fail: ' + $_.Exception.Message)
    return $false
  }
}

function Get-CurrentTrack {
  if (-not $script:sessionManager) { return $null }

  $sessions = $null
  try { $sessions = $script:sessionManager.GetSessions() } catch { $sessions = $null }

  if (-not $sessions -or $sessions.Count -eq 0) {
    $script:currentSession = $null
    $script:emptyTicks++
    if ($script:emptyTicks -ge 4) { $script:emptyTicks = 0; [void](Refresh-SessionManager) }
    return $null
  }

  # порядок: сначала те, что реально играют
  $ordered = New-Object System.Collections.ArrayList
  foreach ($s in $sessions) {
    $playing = $false
    try { $playing = ($s.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') } catch { }
    if ($playing) { [void]$ordered.Add($s) }
  }
  foreach ($s in $sessions) { if (-not $ordered.Contains($s)) { [void]$ordered.Add($s) } }

  foreach ($s in $ordered) {
    $props = $null
    try { $props = Await ($s.TryGetMediaPropertiesAsync()) $wtProps } catch { $props = $null }
    if (-not $props -or -not $props.Title) { continue }

    $track = [pscustomobject]@{ Title = ''; Artist = ''; Album = ''; Art = $null; Key = ''; Status = '' }
    try { $track.Status = ($s.GetPlaybackInfo().PlaybackStatus).ToString() } catch { }

    $script:currentSession = $s
    $script:emptyTicks = 0

    $track.Title = [string]$props.Title
    $track.Artist = [string]$props.Artist
    $track.Album = [string]$props.AlbumTitle
    $track.Key = ($track.Title + '|' + $track.Artist + '|' + $track.Album)

    if ($script:artCacheKey -eq $track.Key) {
      $track.Art = $script:artCacheArt
    } elseif ($props.Thumbnail) {
      try {
        $stream = Await ($props.Thumbnail.OpenReadAsync()) $wtStream
        $netStream = $asStreamForRead.Invoke($null, @($stream))
        $memory = New-Object System.IO.MemoryStream
        $netStream.CopyTo($memory)
        $bytes = $memory.ToArray()
        $memory.Dispose(); $netStream.Dispose()
        if ($bytes.Length -gt 0) {
          $bitmap = New-Object Windows.Media.Imaging.BitmapImage
          $bitmap.BeginInit()
          $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
          $bitmap.DecodePixelWidth = 152
          $bitmap.StreamSource = New-Object System.IO.MemoryStream(, $bytes)
          $bitmap.EndInit()
          $bitmap.Freeze()
          $track.Art = $bitmap
        }
      } catch { Write-Log ('art fail ' + $track.Title + ': ' + $_.Exception.Message) }
      $script:artCacheKey = $track.Key
      $script:artCacheArt = $track.Art
    } else {
      $script:artCacheKey = $track.Key
      $script:artCacheArt = $null
    }

    return $track
  }

  # сессии есть, но метаданных нет — считаем пустыми и обновляем менеджер
  $script:currentSession = $null
  $script:emptyTicks++
  if ($script:emptyTicks -ge 4) { $script:emptyTicks = 0; [void](Refresh-SessionManager) }
  return $null
}
# ---------------------------------------------------------------- окно
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ShowActivated="False" Topmost="True" Focusable="False"
        ResizeMode="NoResize" SizeToContent="WidthAndHeight" Opacity="0">
  <Border x:Name="Card" Width="384" CornerRadius="16" Padding="12"
          Background="#FA171321" BorderBrush="#2EFFFFFF" BorderThickness="1"
          RenderTransformOrigin="0,0.5">
    <Border.RenderTransform>
      <TransformGroup>
        <ScaleTransform x:Name="CardScale" ScaleX="1" ScaleY="1"/>
        <TranslateTransform x:Name="CardSlide" X="0" Y="0"/>
      </TransformGroup>
    </Border.RenderTransform>
    <Border.Effect>
      <DropShadowEffect BlurRadius="20" ShadowDepth="0" Opacity="0.55" Color="#000000"/>
    </Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border x:Name="CoverBorder" Grid.Column="0" Width="76" Height="76" CornerRadius="12"
              Background="#2A2333" VerticalAlignment="Center" Margin="0,0,12,0">
        <Grid>
          <TextBlock x:Name="CoverGlyph" Text="♪" FontSize="30" Foreground="#6B5E7D"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
          <Border x:Name="CoverArt" CornerRadius="12" Background="Transparent" Opacity="0" RenderTransformOrigin="0.5,0.5">
            <Border.RenderTransform>
              <ScaleTransform x:Name="ArtScale" ScaleX="1" ScaleY="1"/>
            </Border.RenderTransform>
          </Border>
        </Grid>
      </Border>

      <Grid x:Name="TextCol" Grid.Column="1" VerticalAlignment="Center">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock x:Name="TitleText" Grid.Row="0" FontFamily="Segoe UI Semibold" FontSize="15"
                   Foreground="#F4EFFA" TextTrimming="CharacterEllipsis" MaxWidth="256">
          <TextBlock.RenderTransform><TranslateTransform x:Name="TitleT" Y="0"/></TextBlock.RenderTransform>
        </TextBlock>
        <TextBlock x:Name="ArtistText" Grid.Row="1" FontFamily="Segoe UI" FontSize="12.5"
                   Foreground="#B6A8C6" TextTrimming="CharacterEllipsis" MaxWidth="256" Margin="0,2,0,0">
          <TextBlock.RenderTransform><TranslateTransform x:Name="ArtistT" Y="0"/></TextBlock.RenderTransform>
        </TextBlock>
        <TextBlock x:Name="AlbumText" Grid.Row="2" FontFamily="Segoe UI" FontSize="11"
                   Foreground="#877A9A" TextTrimming="CharacterEllipsis" MaxWidth="256" Margin="0,3,0,0">
          <TextBlock.RenderTransform><TranslateTransform x:Name="AlbumT" Y="0"/></TextBlock.RenderTransform>
        </TextBlock>

        <Grid x:Name="ProgressRow" Grid.Row="3" Margin="0,8,0,0" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Height="4" CornerRadius="2" Background="#2B2439" VerticalAlignment="Center">
            <Border x:Name="ProgressFill" Height="4" CornerRadius="2" HorizontalAlignment="Left"
                    Background="#6FD8FF" Width="0"/>
          </Border>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,0,0">
            <StackPanel x:Name="Eq" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,8,0">
              <Border x:Name="Eq1" Width="2.5" Height="4" Background="#59F28F" CornerRadius="1" Margin="0,0,2,0" VerticalAlignment="Bottom"/>
              <Border x:Name="Eq2" Width="2.5" Height="8" Background="#59F28F" CornerRadius="1" Margin="0,0,2,0" VerticalAlignment="Bottom"/>
              <Border x:Name="Eq3" Width="2.5" Height="6" Background="#59F28F" CornerRadius="1" VerticalAlignment="Bottom"/>
            </StackPanel>
            <TextBlock x:Name="ProgressText" FontFamily="Segoe UI Semibold" FontSize="11"
                       Foreground="#877A9A" VerticalAlignment="Center" TextAlignment="Right" MinWidth="96"/>
          </StackPanel>
        </Grid>

        <Grid x:Name="VolumeRow" Grid.Row="4" Margin="0,7,0,0" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Height="4" CornerRadius="2" Background="#2B2439" VerticalAlignment="Center">
            <Border x:Name="VolumeFill" Height="4" CornerRadius="2" HorizontalAlignment="Left"
                    Background="#59F28F" Width="0"/>
          </Border>
          <TextBlock x:Name="VolumeText" Grid.Column="1" FontFamily="Segoe UI Semibold" FontSize="11"
                     Foreground="#B6A8C6" Margin="8,0,0,0" VerticalAlignment="Center" MinWidth="34" TextAlignment="Right"/>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$cardScale = $window.FindName('CardScale')
$cardSlide = $window.FindName('CardSlide')
$artScale = $window.FindName('ArtScale')
$coverArt = $window.FindName('CoverArt')
$coverGlyph = $window.FindName('CoverGlyph')
$titleText = $window.FindName('TitleText')
$artistText = $window.FindName('ArtistText')
$albumText = $window.FindName('AlbumText')
$volumeRow = $window.FindName('VolumeRow')
$volumeFill = $window.FindName('VolumeFill')
$volumeText = $window.FindName('VolumeText')
$progressRow = $window.FindName('ProgressRow')
$progressFill = $window.FindName('ProgressFill')
$progressText = $window.FindName('ProgressText')
$textCol = $window.FindName('TextCol')
$titleT = $window.FindName('TitleT')
$artistT = $window.FindName('ArtistT')
$albumT = $window.FindName('AlbumT')
$eq = $window.FindName('Eq')
$eqBars = @($window.FindName('Eq1'), $window.FindName('Eq2'), $window.FindName('Eq3'))

# ---------------------------------------------------------------- подсветка краёв
$script:glowFlag = Join-Path $PSScriptRoot 'glow.on'
$script:glowWindows = @()
$script:glowShown = $false
$script:glowColor = [Windows.Media.Color]::FromRgb(111, 216, 255)
$script:glowKey = ''

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class WinEx {
  [DllImport("user32.dll", SetLastError=true)]
  public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
"@

function Set-ClickThrough($win) {
  try {
    $helper = New-Object Windows.Interop.WindowInteropHelper($win)
    $h = $helper.Handle
    if ($h -eq [IntPtr]::Zero) { return }
    $ex = [WinEx]::GetWindowLong($h, -20)
    $ex = $ex -bor 0x20 -bor 0x80 -bor 0x08000000
    [void][WinEx]::SetWindowLong($h, -20, $ex)
  } catch { }
}

function New-GlowBrush([string]$side, $color) {
  $brush = New-Object Windows.Media.LinearGradientBrush
  $c1 = [Windows.Media.Color]::FromArgb(255, $color.R, $color.G, $color.B)
  $c2 = [Windows.Media.Color]::FromArgb(90, $color.R, $color.G, $color.B)
  $c3 = [Windows.Media.Color]::FromArgb(0, $color.R, $color.G, $color.B)
  $brush.GradientStops.Add((New-Object Windows.Media.GradientStop($c1, 0.0)))
  $brush.GradientStops.Add((New-Object Windows.Media.GradientStop($c2, 0.45)))
  $brush.GradientStops.Add((New-Object Windows.Media.GradientStop($c3, 1.0)))
  switch ($side) {
    'top'    { $brush.StartPoint = New-Object Windows.Point(0.5, 0.0); $brush.EndPoint = New-Object Windows.Point(0.5, 1.0) }
    'bottom' { $brush.StartPoint = New-Object Windows.Point(0.5, 1.0); $brush.EndPoint = New-Object Windows.Point(0.5, 0.0) }
    'left'   { $brush.StartPoint = New-Object Windows.Point(0.0, 0.5); $brush.EndPoint = New-Object Windows.Point(1.0, 0.5) }
    'right'  { $brush.StartPoint = New-Object Windows.Point(1.0, 0.5); $brush.EndPoint = New-Object Windows.Point(0.0, 0.5) }
  }
  return $brush
}

function New-GlowWindow([string]$side) {
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

  $rect = New-Object Windows.Shapes.Rectangle
  $rect.Fill = (New-GlowBrush $side $script:glowColor)
  $w.Content = $rect

  $sw = [System.Windows.SystemParameters]::PrimaryScreenWidth
  $sh = [System.Windows.SystemParameters]::PrimaryScreenHeight
  $thick = 66

  switch ($side) {
    'top'    { $w.Left = 0; $w.Top = 0; $w.Width = $sw; $w.Height = $thick }
    'bottom' { $w.Left = 0; $w.Top = $sh - $thick; $w.Width = $sw; $w.Height = $thick }
    'left'   { $w.Left = 0; $w.Top = 0; $w.Width = $thick; $w.Height = $sh }
    'right'  { $w.Left = $sw - $thick; $w.Top = 0; $w.Width = $thick; $w.Height = $sh }
  }

  $w.Show()
  Set-ClickThrough $w
  $w.Visibility = 'Hidden'
  return $w
}

function Update-GlowColor($color) {
  if (-not $color) { return }
  $script:glowColor = $color
  Write-Log ('glow color rgb(' + $color.R + ',' + $color.G + ',' + $color.B + ')')
  $sides = @('top', 'bottom', 'left', 'right')
  for ($i = 0; $i -lt $script:glowWindows.Count; $i++) {
    try {
      $rect = $script:glowWindows[$i].Content
      $rect.Fill = (New-GlowBrush $sides[$i] $color)
    } catch { }
  }
}

function Show-Glow {
  if ($script:glowShown) { return }
  $sides = @('top', 'bottom', 'left', 'right')
  if ($script:glowWindows.Count -eq 0) {
    foreach ($s in $sides) { $script:glowWindows += (New-GlowWindow $s) }
  }
  $delays = @(0, 400, 200, 600)
  for ($i = 0; $i -lt $script:glowWindows.Count; $i++) {
    $w = $script:glowWindows[$i]
    $w.Visibility = 'Visible'
    $anim = New-Object Windows.Media.Animation.DoubleAnimation(0.07, 0.22, [Windows.Duration]([TimeSpan]::FromMilliseconds(2800)))
    $anim.AutoReverse = $true
    $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $anim.BeginTime = [TimeSpan]::FromMilliseconds($delays[$i])
    $anim.EasingFunction = $easeOut
    $w.BeginAnimation([Windows.Window]::OpacityProperty, $anim)
  }
  $script:glowShown = $true
  Write-Log 'glow on'
}

function Hide-Glow {
  if (-not $script:glowShown) { return }
  foreach ($w in $script:glowWindows) {
    try {
      $w.BeginAnimation([Windows.Window]::OpacityProperty, $null)
      $w.Visibility = 'Hidden'
    } catch { }
  }
  $script:glowShown = $false
  Write-Log 'glow off'
}

function Get-ArtColor($bmp) {
  try {
    $w = [int]$bmp.PixelWidth
    $h = [int]$bmp.PixelHeight
    if ($w -le 0 -or $h -le 0) { return $null }
    $stride = $w * 4
    $pixels = New-Object byte[] ($stride * $h)
    $bmp.CopyPixels($pixels, $stride, 0)
    $bestScore = -1.0
    $best = @(111, 216, 255)
    $stepX = [Math]::Max(1, [int]($w / 14))
    $stepY = [Math]::Max(1, [int]($h / 14))
    for ($y = 0; $y -lt $h; $y += $stepY) {
      for ($x = 0; $x -lt $w; $x += $stepX) {
        $i = $y * $stride + $x * 4
        $b = [double]$pixels[$i]
        $g = [double]$pixels[$i + 1]
        $r = [double]$pixels[$i + 2]
        $max = [Math]::Max($r, [Math]::Max($g, $b))
        $min = [Math]::Min($r, [Math]::Min($g, $b))
        $sat = if ($max -le 0) { 0 } else { ($max - $min) / $max }
        $score = $sat * 0.85 + ($max / 255.0) * 0.15
        if ($score -gt $bestScore) { $bestScore = $score; $best = @([int]$r, [int]$g, [int]$b) }
      }
    }

    # приглушаем слишком светлые и серые цвета
    $r = $best[0]; $g = $best[1]; $b = $best[2]
    $maxC = [Math]::Max($r, [Math]::Max($g, $b))
    $minC = [Math]::Min($r, [Math]::Min($g, $b))
    $sat = if ($maxC -le 0) { 0 } else { ($maxC - $minC) / [double]$maxC }
    if ($sat -lt 0.22) { return [Windows.Media.Color]::FromRgb(111, 216, 255) }
    if ($maxC -gt 185) {
      $k = 185.0 / $maxC
      $r = [int]($r * $k); $g = [int]($g * $k); $b = [int]($b * $k)
    }
    return [Windows.Media.Color]::FromRgb($r, $g, $b)
  } catch { return $null }
}

# предсозданные кисти — меньше мусора при обновлении
$brushGreen = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(89, 242, 143))
$brushAmber = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(240, 192, 96))
$brushRed = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(255, 122, 107))
$brushMuted = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(182, 168, 198))
foreach ($b in @($brushGreen, $brushAmber, $brushRed, $brushMuted)) { $b.Freeze() }

function Format-Time([TimeSpan]$value) {
  if ($value.Ticks -lt 0) { $value = [TimeSpan]::Zero }
  if ($value.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($value.TotalHours), $value.Minutes, $value.Seconds) }
  return ('{0}:{1:00}' -f [int][Math]::Floor($value.TotalMinutes), $value.Seconds)
}

$script:volumeMode = $false
$script:lastTrack = $null
$script:lastGoodTrack = $null
$script:lastGoodAt = [DateTime]::MinValue
$script:lastKey = ''
$script:lastStatus = ''
$script:lastVolume = -1
$script:lastMute = $false
$script:lastShownKey = ''
$script:lastShownAt = [DateTime]::MinValue
$script:lastBeat = [DateTime]::MinValue

function Get-DisplayTrack {
  if ($script:lastTrack -and $script:lastTrack.Title) { return $script:lastTrack }
  if ($script:lastGoodTrack -and ((Get-Date).ToUniversalTime() - $script:lastGoodAt).TotalMinutes -lt 20) { return $script:lastGoodTrack }
  return $script:lastTrack
}

function Set-Art($bitmap) {
  if ($bitmap) {
    $brush = New-Object Windows.Media.ImageBrush($bitmap)
    $brush.Stretch = [Windows.Media.Stretch]::UniformToFill
    $coverArt.Background = $brush
    $coverGlyph.Visibility = 'Collapsed'
  } else {
    $coverArt.Background = [Windows.Media.Brushes]::Transparent
    $coverGlyph.Visibility = 'Visible'
  }
}

$script:eqPlaying = $null

function Set-Equalizer([bool]$playing) {
  try {
    if ($script:eqPlaying -eq $playing) { return }
    $script:eqPlaying = $playing
    if ($playing) {
      $tops = @(14.0, 9.0, 16.0)
      $durations = @(420, 560, 360)
      for ($i = 0; $i -lt $eqBars.Count; $i++) {
        $anim = New-Object Windows.Media.Animation.DoubleAnimation(3.0, $tops[$i], [Windows.Duration]([TimeSpan]::FromMilliseconds($durations[$i])))
        $anim.AutoReverse = $true
        $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $anim.EasingFunction = $easeOut
        $eqBars[$i].BeginAnimation([Windows.FrameworkElement]::HeightProperty, $anim)
      }
    } else {
      $heights = @(4.0, 8.0, 6.0)
      for ($i = 0; $i -lt $eqBars.Count; $i++) {
        $eqBars[$i].BeginAnimation([Windows.FrameworkElement]::HeightProperty, $null)
        $eqBars[$i].Height = $heights[$i]
      }
    }
  } catch { }
}

function Crossfade-Text([string]$title, [string]$artist, [string]$album, $art) {
  try {
    $fadeOut = New-Object Windows.Media.Animation.DoubleAnimation(1.0, 0.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(90)))
    $textCol.BeginAnimation([Windows.UIElement]::OpacityProperty, $fadeOut)
    $script:pendingText = @{ title = $title; artist = $artist; album = $album; art = $art }
    $swapTimer.Stop()
    $swapTimer.Interval = [TimeSpan]::FromMilliseconds(95)
    $swapTimer.Start()
  } catch { }
}

function Update-VolumeBar([int]$percent, [bool]$muted) {
  if ($percent -lt 0) { $volumeRow.Visibility = 'Collapsed'; return }
  $volumeRow.Visibility = 'Visible'
  $available = [Math]::Max(0.0, $volumeRow.ActualWidth - 44)
  if ($available -le 0) { $available = 172 }
  $target = if ($muted) { 0.0 } else { [Math]::Max(0.0, [Math]::Min($available, $available * $percent / 100.0)) }
  $from = $volumeFill.ActualWidth
  if ([double]::IsNaN($from)) { $from = 0 }
  $anim = New-Object Windows.Media.Animation.DoubleAnimation([double]$from, [double]$target, [Windows.Duration]([TimeSpan]::FromMilliseconds(140)))
  $anim.EasingFunction = $easeOut
  $volumeFill.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $anim)
  if ($muted) {
    $volumeText.Text = 'выкл'
    $volumeText.Foreground = $brushRed
    $volumeFill.Background = $brushRed
  } else {
    $volumeText.Text = [string]$percent + '%'
    $volumeText.Foreground = $brushMuted
    if ($percent -ge 60) { $volumeFill.Background = $brushGreen }
    elseif ($percent -ge 25) { $volumeFill.Background = $brushAmber }
    else { $volumeFill.Background = $brushRed }
  }
}

function Update-Progress {
  $progressRow.Visibility = 'Visible'
  if (-not $script:currentSession) { $progressText.Text = '—:—'; return }
  try { $timeline = $script:currentSession.GetTimelineProperties() } catch { $progressText.Text = '—:—'; return }
  if (-not $timeline) { $progressText.Text = '—:—'; return }

  $total = $timeline.EndTime - $timeline.StartTime
  if ($total.Ticks -le 0) { $progressText.Text = '—:—'; return }

  $position = $timeline.Position
  if ($script:lastStatus -eq 'Playing') {
    $rate = 1.0
    try {
      $info = $script:currentSession.GetPlaybackInfo()
      if ($info -and $info.PlaybackRate) { $rate = [double]$info.PlaybackRate }
    } catch { }
    $delta = [DateTimeOffset]::UtcNow - $timeline.LastUpdatedTime
    $seconds = $delta.TotalSeconds
    if ($seconds -gt 0 -and $seconds -lt 30) { $position = $position.Add([TimeSpan]::FromSeconds($seconds * $rate)) }
  }

  $elapsed = $position - $timeline.StartTime
  if ($elapsed.Ticks -lt 0) { $elapsed = [TimeSpan]::Zero }
  if ($elapsed -gt $total) { $elapsed = $total }

  $available = [Math]::Max(0.0, $progressRow.ActualWidth - 104)
  if ($available -le 0) { $available = 160 }
  $ratio = $elapsed.TotalSeconds / $total.TotalSeconds
  $target = [Math]::Max(0.0, [Math]::Min($available, $available * $ratio))
  $from = $progressFill.ActualWidth
  if ([double]::IsNaN($from)) { $from = 0 }
  $anim = New-Object Windows.Media.Animation.DoubleAnimation([double]$from, [double]$target, [Windows.Duration]([TimeSpan]::FromMilliseconds(260)))
  $anim.EasingFunction = $null
  $progressFill.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $anim)
  $progressText.Text = (Format-Time $elapsed) + ' — ' + (Format-Time $total)
}

# ---------------------------------------------------------------- анимации
$easeOut = New-Object Windows.Media.Animation.CubicEase
$easeOut.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
$easeIn = New-Object Windows.Media.Animation.CubicEase
$easeIn.EasingMode = [Windows.Media.Animation.EasingMode]::EaseIn

function Animate-Show([bool]$fresh) {
  $fromOpacity = $window.Opacity
  if ([double]::IsNaN($fromOpacity)) { $fromOpacity = 0 }
  $durMs = if ($fresh) { 260 } else { 140 }
  $fade = New-Object Windows.Media.Animation.DoubleAnimation([double]$fromOpacity, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds($durMs)))
  $fade.EasingFunction = $easeOut
  $window.BeginAnimation([Windows.Window]::OpacityProperty, $fade)

  if ($fresh) {
    $dur = [Windows.Duration]([TimeSpan]::FromMilliseconds(260))
    $slide = New-Object Windows.Media.Animation.DoubleAnimation(-26.0, 0.0, $dur)
    $slide.EasingFunction = $easeOut
    $cardSlide.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $slide)

    $scale = New-Object Windows.Media.Animation.DoubleAnimation(0.93, 1.0, $dur)
    $scale.EasingFunction = $easeOut
    $cardScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $scale)
    $cardScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $scale)

    $artFade = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(320)))
    $artFade.EasingFunction = $easeOut
    $coverArt.BeginAnimation([Windows.UIElement]::OpacityProperty, $artFade)

    $artZoom = New-Object Windows.Media.Animation.DoubleAnimation(1.08, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(420)))
    $artZoom.EasingFunction = $easeOut
    $artScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $artZoom)
    $artScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $artZoom)

    # каскад: заголовок, исполнитель, альбом, полоска
    $stagger = @(
      @{ el = $titleText; t = $titleT; delay = 0.0 },
      @{ el = $artistText; t = $artistT; delay = 70.0 },
      @{ el = $albumText; t = $albumT; delay = 140.0 },
      @{ el = $progressRow; t = $null; delay = 210.0 }
    )
    foreach ($item in $stagger) {
      $op = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(230)))
      $op.BeginTime = [TimeSpan]::FromMilliseconds($item.delay)
      $op.EasingFunction = $easeOut
      $item.el.BeginAnimation([Windows.UIElement]::OpacityProperty, $op)
      if ($item.t) {
        $ty = New-Object Windows.Media.Animation.DoubleAnimation(9.0, 0.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(260)))
        $ty.BeginTime = [TimeSpan]::FromMilliseconds($item.delay)
        $ty.EasingFunction = $easeOut
        $item.t.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $ty)
      }
    }
  }
}

function Animate-Hide {
  $dur = [Windows.Duration]([TimeSpan]::FromMilliseconds(200))
  $fade = New-Object Windows.Media.Animation.DoubleAnimation(1.0, 0.0, $dur)
  $fade.EasingFunction = $easeIn
  $window.BeginAnimation([Windows.Window]::OpacityProperty, $fade)

  $slide = New-Object Windows.Media.Animation.DoubleAnimation(0.0, -18.0, $dur)
  $slide.EasingFunction = $easeIn
  $cardSlide.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $slide)

  $scale = New-Object Windows.Media.Animation.DoubleAnimation(1.0, 0.96, $dur)
  $scale.EasingFunction = $easeIn
  $cardScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $scale)
  $cardScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $scale)
}

$script:hiding = $false

$holdTimer = New-Object Windows.Threading.DispatcherTimer
$holdTimer.Add_Tick({
    try {
      $holdTimer.Stop()
      if ($script:hiding) { return }
      $script:hiding = $true
      Animate-Hide
      $hideTimer.Start()
    } catch { Write-Log ('hold tick: ' + $_.Exception.Message) }
  })

$hideTimer = New-Object Windows.Threading.DispatcherTimer
$hideTimer.Interval = [TimeSpan]::FromMilliseconds(210)
$hideTimer.Add_Tick({
    try {
      $hideTimer.Stop()
      $window.Visibility = 'Hidden'
      $window.BeginAnimation([Windows.Window]::OpacityProperty, $null)
      $script:hiding = $false
    } catch { Write-Log ('hide tick: ' + $_.Exception.Message) }
  })

# смена текста на видимой карточке: короткий кроссфейд
$script:pendingText = $null
$swapTimer = New-Object Windows.Threading.DispatcherTimer
$swapTimer.Add_Tick({
    try {
      $swapTimer.Stop()
      $pending = $script:pendingText
      if (-not $pending) { return }
      $titleText.Text = $pending.title
      $artistText.Text = $pending.artist
      $albumText.Text = $pending.album
      if ($pending.art) { Set-Art $pending.art }
      $fadeIn = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(150)))
      $fadeIn.EasingFunction = $easeOut
      $textCol.BeginAnimation([Windows.UIElement]::OpacityProperty, $fadeIn)
      $script:pendingText = $null
    } catch { }
  })

function Show-Toast([string]$mode) {
  try {
    $track = Get-DisplayTrack
    $script:volumeMode = ($mode -eq 'volume')
    $isPause = ($mode -eq 'pause')
    $textCol.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $textCol.Opacity = 1

    if ($track -and $track.Title) {
      $titleText.Text = $track.Title
      $artistText.Text = if ($track.Artist) { $track.Artist } else { 'Неизвестный исполнитель' }
      if ($script:volumeMode) {
        $albumText.Text = 'Громкость'
        $progressRow.Visibility = 'Collapsed'
        Update-VolumeBar ([BrickyardAudio.Endpoint]::GetVolumePercent()) ([BrickyardAudio.Endpoint]::GetMute())
      } else {
        if ($isPause) { $albumText.Text = 'Пауза' }
        else { $albumText.Text = if ($track.Album) { $track.Album } else { 'Сингл' } }
        $volumeRow.Visibility = 'Collapsed'
        Update-Progress
      }
      Set-Art $track.Art
    } else {
      $titleText.Text = 'Громкость'
      $artistText.Text = if ($script:volumeMode) { 'Ничего не играет' } else { '' }
      $albumText.Text = ''
      $progressRow.Visibility = 'Collapsed'
      Set-Art $null
      Update-VolumeBar ([BrickyardAudio.Endpoint]::GetVolumePercent()) ([BrickyardAudio.Endpoint]::GetMute())
    }

    $window.UpdateLayout()
    $area = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $area.Left + 24
    $window.Top = $area.Top + 24

    $script:hiding = $false
    $hideTimer.Stop()
    $fresh = ($window.Visibility -ne 'Visible')
    if ($fresh) { $window.Visibility = 'Visible' }
    Animate-Show $fresh

    $holdMs = if ($script:volumeMode -or $isPause) { 2200 } else { 5600 }
    $holdTimer.Stop()
    $holdTimer.Interval = [TimeSpan]::FromMilliseconds($holdMs)
    $holdTimer.Start()
    Write-Log ('show ' + $mode + ' ' + $titleText.Text)
  } catch {
    Write-Log ('show fail: ' + $_.Exception.Message)
  }
}

# ---------------------------------------------------------------- таймеры данных
$mediaTimer = New-Object Windows.Threading.DispatcherTimer
$mediaTimer.Interval = [TimeSpan]::FromMilliseconds(950)
$mediaTimer.Add_Tick({
    try {
      $track = Get-CurrentTrack
      if ($track -and $track.Title) {
        $script:lastTrack = $track
        $script:lastGoodTrack = $track
        $script:lastGoodAt = (Get-Date).ToUniversalTime()
        $isPlaying = ($track.Status -eq 'Playing')

        if ($track.Key -ne $script:lastKey) {
          $script:lastKey = $track.Key
          if ($window.Visibility -ne 'Visible' -or $script:volumeMode) { Show-Toast 'track' }
          else {
            # карточка уже на экране — кроссфейд текста и обновление прогресса
            Crossfade-Text $track.Title $(if ($track.Artist) { $track.Artist } else { 'Неизвестный исполнитель' }) $(if ($track.Album) { $track.Album } else { 'Сингл' }) $track.Art
            Update-Progress
            $holdTimer.Stop()
            $holdTimer.Interval = [TimeSpan]::FromMilliseconds(5600)
            $holdTimer.Start()
          }
        } elseif ($isPlaying -and $script:lastStatus -ne 'Playing') {
          Show-Toast 'track'
        } elseif (-not $isPlaying -and $track.Status -eq 'Paused' -and $script:lastStatus -eq 'Playing') {
          Show-Toast 'pause'
        }
        $script:lastStatus = $track.Status
        Set-Equalizer $isPlaying
        if ($script:glowShown -and $track.Art -and $script:glowKey -ne $track.Key) {
          $script:glowKey = $track.Key
          $glowColor = Get-ArtColor $track.Art
          if ($glowColor) { Update-GlowColor $glowColor }
        }
      } else {
        $script:lastStatus = ''
      }

      if (-not $script:volumeMode -and $window.Visibility -eq 'Visible') { Update-Progress }
      $nowBeat = Get-Date
      if (($nowBeat - $script:lastBeat).TotalSeconds -gt 60) {
        $script:lastBeat = $nowBeat
        Write-Log ('beat title=' + $track.Title + ' st=' + $track.Status + ' key=' + $track.Key + ' vis=' + $window.Visibility)
      }
    } catch { Write-Log ('media tick: ' + $_.Exception.Message) }
  })
$mediaTimer.Start()

# отдельный лёгкий тик для плавного прогресса
$progressTimer = New-Object Windows.Threading.DispatcherTimer
$progressTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$progressTimer.Add_Tick({
    try {
      if (-not $script:volumeMode -and $window.Visibility -eq 'Visible' -and $script:lastStatus -eq 'Playing') { Update-Progress }
    } catch { }
  })
$progressTimer.Start()

$volumeTimer = New-Object Windows.Threading.DispatcherTimer
$volumeTimer.Interval = [TimeSpan]::FromMilliseconds(260)
$volumeTimer.Add_Tick({
    try {
      $percent = [BrickyardAudio.Endpoint]::GetVolumePercent()
      if ($percent -lt 0) { return }
      $muted = [BrickyardAudio.Endpoint]::GetMute()
      $changed = ($script:lastVolume -ge 0 -and $percent -ne $script:lastVolume) -or ($muted -ne $script:lastMute)
      if ($changed) {
        $key = 'vol|' + $percent + '|' + [int]$muted
        $now = [DateTime]::UtcNow
        if ($key -ne $script:lastShownKey -or ($now - $script:lastShownAt).TotalMilliseconds -gt 1200) {
          $script:lastShownKey = $key
          $script:lastShownAt = $now
          Show-Toast 'volume'
        }
      }
      $script:lastVolume = $percent
      $script:lastMute = $muted
    } catch { }
  })
$volumeTimer.Start()

$reconnectTimer = New-Object Windows.Threading.DispatcherTimer
$reconnectTimer.Interval = [TimeSpan]::FromSeconds(45)
$reconnectTimer.Add_Tick({
    try {
      if (-not $script:sessionManager) { [void](Refresh-SessionManager) }
    } catch { }
  })
$reconnectTimer.Start()

# тумблер подсветки: файл glow.on рядом со скриптом
$glowTimer = New-Object Windows.Threading.DispatcherTimer
$glowTimer.Interval = [TimeSpan]::FromSeconds(1)
$glowTimer.Add_Tick({
    try {
      $on = Test-Path -LiteralPath $script:glowFlag
      if ($on -and -not $script:glowShown) {
        Show-Glow
        if ($script:lastTrack -and $script:lastTrack.Art) {
          $c = Get-ArtColor $script:lastTrack.Art
          if ($c) { Update-GlowColor $c }
        }
      } elseif (-not $on -and $script:glowShown) {
        Hide-Glow
      }
    } catch { }
  })
$glowTimer.Start()

# ---------------------------------------------------------------- старт
$script:lastTrack = Get-CurrentTrack
if ($script:lastTrack) { $script:lastKey = $script:lastTrack.Key; $script:lastStatus = $script:lastTrack.Status }
Set-Equalizer ($script:lastStatus -eq 'Playing')
$script:lastVolume = [BrickyardAudio.Endpoint]::GetVolumePercent()
$script:lastMute = [BrickyardAudio.Endpoint]::GetMute()
Write-Log ('started v2 session=' + ($null -ne $sessionManager) + ' volume=' + $script:lastVolume + ' track=' + $(if ($script:lastTrack) { $script:lastTrack.Title } else { '-' }))

$app = New-Object Windows.Application
$app.Add_Startup({
    $window.Show()
    $window.Visibility = 'Hidden'

    if ($Demo) {
      $art = $null
      if ($DemoArt -and (Test-Path -LiteralPath $DemoArt)) {
        try {
          $bytes = [System.IO.File]::ReadAllBytes($DemoArt)
          $bitmap = New-Object Windows.Media.Imaging.BitmapImage
          $bitmap.BeginInit()
          $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
          $bitmap.DecodePixelWidth = 152
          $bitmap.StreamSource = New-Object System.IO.MemoryStream(, $bytes)
          $bitmap.EndInit()
          $bitmap.Freeze()
          $art = $bitmap
        } catch { Write-Log ('demo art fail: ' + $_.Exception.Message) }
      }
      $script:lastTrack = [pscustomobject]@{ Title = 'Дискеты'; Artist = 'LAZZY2WICE'; Album = ''; Art = $art; Key = 'demo'; Status = 'Playing' }
      Show-Toast 'track'
      $script:volumeMode = $false
      $holdTimer.Stop()
    }
  })
[void]$app.Run()
