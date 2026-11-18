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
          $bitmap.DecodePixelWidth = 256
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
# ---------------------------------------------------------------- статистика
$script:listenPath = Join-Path $PSScriptRoot 'listening.tsv'
$script:listenKey = ''
$script:listenArtist = ''
$script:listenTitle = ''
$script:listenAccum = 0.0
$script:listenLast = [DateTime]::UtcNow

function Write-ListenChunk([double]$seconds) {
  if ($seconds -lt 1 -or -not $script:listenArtist -and -not $script:listenTitle) { return }
  try {
    $stamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    $line = $stamp + "`t" + [int][Math]::Round($seconds) + "`t" + $script:listenArtist + "`t" + $script:listenTitle
    Add-Content -LiteralPath $script:listenPath -Value $line -Encoding UTF8
  } catch { }
}

function Track-Listening($track, [bool]$playing) {
  $now = [DateTime]::UtcNow
  $delta = ($now - $script:listenLast).TotalSeconds
  $script:listenLast = $now
  if ($delta -lt 0 -or $delta -gt 10) { $delta = 0 }

  if (-not $playing -or -not $track -or -not $track.Title) {
    if ($script:listenAccum -ge 1) { Write-ListenChunk $script:listenAccum; $script:listenAccum = 0 }
    return
  }

  $key = $track.Title + '|' + $track.Artist
  if ($key -ne $script:listenKey) {
    if ($script:listenAccum -ge 1) { Write-ListenChunk $script:listenAccum }
    $script:listenKey = $key
    $script:listenArtist = [string]$track.Artist
    $script:listenTitle = [string]$track.Title
    $script:listenAccum = 0
  }

  $script:listenAccum += $delta
  if ($script:listenAccum -ge 30) {
    Write-ListenChunk 30
    $script:listenAccum = $script:listenAccum - 30
  }
}

# ---------------------------------------------------------------- окно
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ShowActivated="False" Topmost="True" Focusable="False"
        ResizeMode="NoResize" SizeToContent="WidthAndHeight" Opacity="0">
  <Border x:Name="Card" Width="384" CornerRadius="16" Padding="12"
          Background="#FA171321" BorderThickness="1"
          RenderTransformOrigin="0,0.5">
    <Border.BorderBrush>
      <LinearGradientBrush x:Name="CardBorderBrush" StartPoint="0,0" EndPoint="1,1">
        <LinearGradientBrush.RelativeTransform>
          <RotateTransform x:Name="BorderSpin" CenterX="0.5" CenterY="0.5" Angle="0"/>
        </LinearGradientBrush.RelativeTransform>
        <GradientStop Color="#33FFFFFF" Offset="0"/>
        <GradientStop Color="#88FFFFFF" Offset="0.5"/>
        <GradientStop Color="#22FFFFFF" Offset="1"/>
      </LinearGradientBrush>
    </Border.BorderBrush>
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

      <Border x:Name="CardBackdrop" Grid.ColumnSpan="2" Margin="-12" CornerRadius="15" Opacity="0"
              Background="Transparent" IsHitTestVisible="False"/>
      <Border Grid.ColumnSpan="2" Margin="-12" CornerRadius="15" Background="#CE14111C" IsHitTestVisible="False"/>
      <Border Grid.ColumnSpan="2" Margin="-12" CornerRadius="15" IsHitTestVisible="False">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#16FFFFFF" Offset="0"/>
            <GradientStop Color="#00FFFFFF" Offset="0.42"/>
          </LinearGradientBrush>
        </Border.Background>
      </Border>

      <Grid Grid.Column="0" Width="84" Height="84" VerticalAlignment="Center" Margin="0,0,8,0">
        <Ellipse x:Name="RingTrack" Width="84" Height="84" Stroke="#22FFFFFF" StrokeThickness="2" Visibility="Collapsed"/>
        <Path x:Name="Ring" Stroke="#6FD8FF" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
              Width="84" Height="84" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
        <Border x:Name="CoverBorder" Width="76" Height="76" CornerRadius="12"
                Background="#2A2333" VerticalAlignment="Center" HorizontalAlignment="Center">
          <Grid>
            <TextBlock x:Name="CoverGlyph" Text="♪" FontSize="30" Foreground="#6B5E7D"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
            <Border x:Name="CoverArt" CornerRadius="12" Background="Transparent" Opacity="0" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform>
                <ScaleTransform x:Name="ArtScale" ScaleX="1" ScaleY="1"/>
              </Border.RenderTransform>
            </Border>
            <Border CornerRadius="12" BorderBrush="#26FFFFFF" BorderThickness="1" IsHitTestVisible="False"/>
          </Grid>
        </Border>
      </Grid>

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
$card = $window.FindName('Card')
$cardBackdrop = $window.FindName('CardBackdrop')
$cardBorderBrush = $window.FindName('CardBorderBrush')
$borderSpin = $window.FindName('BorderSpin')

try {
  $spinAnim = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 360.0, [Windows.Duration]([TimeSpan]::FromSeconds(7)))
  $spinAnim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
  $borderSpin.BeginAnimation([Windows.Media.Animation.RotateTransform]::AngleProperty, $spinAnim)
} catch { }

function Update-CardBackdrop($bitmap) {
  try {
    if (-not $cardBackdrop) { return }
    if (-not $bitmap) { $cardBackdrop.Opacity = 0; return }
    $scale = New-Object Windows.Media.ScaleTransform(0.28, 0.28)
    $small = New-Object Windows.Media.Imaging.TransformedBitmap($bitmap, $scale)
    $small.Freeze()
    $brush = New-Object Windows.Media.ImageBrush($small)
    $brush.Stretch = [Windows.Media.Stretch]::UniformToFill
    $cardBackdrop.Background = $brush
    $fade = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 0.34, [Windows.Duration]([TimeSpan]::FromMilliseconds(520)))
    $cardBackdrop.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
  } catch { }
}

function Update-CardBorder($color) {
  if (-not $color -or -not $cardBorderBrush) { return }
  try {
    $cardBorderBrush.GradientStops[0].Color = [Windows.Media.Color]::FromArgb(70, $color.R, $color.G, $color.B)
    $cardBorderBrush.GradientStops[1].Color = [Windows.Media.Color]::FromArgb(170, $color.R, $color.G, $color.B)
    $cardBorderBrush.GradientStops[2].Color = [Windows.Media.Color]::FromArgb(36, $color.R, $color.G, $color.B)
  } catch { }
}
$cardScale = $window.FindName('CardScale')
$cardSlide = $window.FindName('CardSlide')
$artScale = $window.FindName('ArtScale')
$coverArt = $window.FindName('CoverArt')
$coverGlyph = $window.FindName('CoverGlyph')
$ring = $window.FindName('Ring')
$ringTrack = $window.FindName('RingTrack')
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
$script:glowParts = @()
$script:glowShown = $false
$script:glowColor = [Windows.Media.Color]::FromRgb(111, 216, 255)
$script:glowKey = ''
$script:glowVol = -1
$script:glowStatic = $false
$script:glowAudio = $false
$script:glowLevel = 0.0
$script:beatLog = [DateTime]::MinValue
$script:tintKey = ''
$script:accentColor = [Windows.Media.Color]::FromRgb(111, 216, 255)

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

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class FgWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

  public static bool IsFullscreen(uint myPid, int screenW, int screenH) {
    IntPtr h = GetForegroundWindow();
    if (h == IntPtr.Zero) return false;
    uint pid;
    GetWindowThreadProcessId(h, out pid);
    if (pid == myPid) return false;
    RECT r;
    if (!GetWindowRect(h, out r)) return false;
    int w = r.Right - r.Left;
    int hh = r.Bottom - r.Top;
    return (w >= screenW - 4) && (hh >= screenH - 4);
  }
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

function New-GlowFill([string]$side, $color, [string]$kind) {
  $brush = New-Object Windows.Media.LinearGradientBrush
  if ($kind -eq 'core') {
    $stops = @(@(170, 0.0), @(90, 0.45), @(0, 1.0))
  } else {
    $stops = @(@(200, 0.0), @(110, 0.20), @(40, 0.55), @(0, 1.0))
  }
  foreach ($s in $stops) {
    $col = [Windows.Media.Color]::FromArgb([int]$s[0], $color.R, $color.G, $color.B)
    $brush.GradientStops.Add((New-Object Windows.Media.GradientStop($col, [double]$s[1])))
  }
  switch ($side) {
    'top'    { $brush.StartPoint = New-Object Windows.Point(0.5, 0.0); $brush.EndPoint = New-Object Windows.Point(0.5, 1.0) }
    'bottom' { $brush.StartPoint = New-Object Windows.Point(0.5, 1.0); $brush.EndPoint = New-Object Windows.Point(0.5, 0.0) }
    'left'   { $brush.StartPoint = New-Object Windows.Point(0.0, 0.5); $brush.EndPoint = New-Object Windows.Point(1.0, 0.5) }
    'right'  { $brush.StartPoint = New-Object Windows.Point(1.0, 0.5); $brush.EndPoint = New-Object Windows.Point(0.0, 0.5) }
  }
  if ($kind -eq 'soft') {
    try {
      $mid = $brush.GradientStops[1]
      $shift = [Windows.Media.Color]::FromArgb(90,
        [int](($color.R * 0.82) + ($color.B * 0.18)),
        [int](($color.G * 0.82) + ($color.R * 0.18)),
        [int](($color.B * 0.82) + ($color.G * 0.18)))
      $drift = New-Object Windows.Media.Animation.ColorAnimation($mid.Color, $shift, [Windows.Duration]([TimeSpan]::FromSeconds(10)))
      $drift.AutoReverse = $true
      $drift.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
      $mid.BeginAnimation([Windows.Media.GradientStop]::ColorProperty, $drift)
    } catch { }
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

  $grid = New-Object Windows.Controls.Grid
  $soft = New-Object Windows.Shapes.Rectangle
  $soft.Fill = (New-GlowFill $side $script:glowColor 'soft')
  $core = New-Object Windows.Shapes.Rectangle
  $core.Fill = (New-GlowFill $side $script:glowColor 'core')

  $softT = 84
  $coreT = 16
  switch ($side) {
    'top'    { $soft.VerticalAlignment = 'Top'; $soft.Height = $softT; $core.VerticalAlignment = 'Top'; $core.Height = $coreT }
    'bottom' { $soft.VerticalAlignment = 'Bottom'; $soft.Height = $softT; $core.VerticalAlignment = 'Bottom'; $core.Height = $coreT }
    'left'   { $soft.HorizontalAlignment = 'Left'; $soft.Width = $softT; $core.HorizontalAlignment = 'Left'; $core.Width = $coreT }
    'right'  { $soft.HorizontalAlignment = 'Right'; $soft.Width = $softT; $core.HorizontalAlignment = 'Right'; $core.Width = $coreT }
  }
  [void]$grid.Children.Add($soft)
  [void]$grid.Children.Add($core)
  $w.Content = $grid

  $sw = [System.Windows.SystemParameters]::PrimaryScreenWidth
  $sh = [System.Windows.SystemParameters]::PrimaryScreenHeight
  $thick = 84

  switch ($side) {
    'top'    { $w.Left = 0; $w.Top = 0; $w.Width = $sw; $w.Height = $thick }
    'bottom' { $w.Left = 0; $w.Top = $sh - $thick; $w.Width = $sw; $w.Height = $thick }
    'left'   { $w.Left = 0; $w.Top = 0; $w.Width = $thick; $w.Height = $sh }
    'right'  { $w.Left = $sw - $thick; $w.Top = 0; $w.Width = $thick; $w.Height = $sh }
  }

  $w.Show()
  Set-ClickThrough $w
  $w.Visibility = 'Hidden'
  $script:glowParts += [pscustomobject]@{ Side = $side; Soft = $soft; Core = $core }
  return $w
}

function Update-GlowColor($color) {
  if (-not $color) { return }
  $script:glowColor = $color
  Write-Log ('glow color rgb(' + $color.R + ',' + $color.G + ',' + $color.B + ')')
  foreach ($p in $script:glowParts) {
    try {
      $p.Soft.Fill = (New-GlowFill $p.Side $color 'soft')
      $p.Core.Fill = (New-GlowFill $p.Side $color 'core')
    } catch { }
  }
}

function Start-GlowBreathing {
  $lo = 0.10
  $hi = 0.30
  $delays = @(0, 400, 200, 600)
  for ($i = 0; $i -lt $script:glowWindows.Count; $i++) {
    $w = $script:glowWindows[$i]
    try {
      $anim = New-Object Windows.Media.Animation.DoubleAnimation([double]$lo, [double]$hi, [Windows.Duration]([TimeSpan]::FromMilliseconds(2800)))
      $anim.AutoReverse = $true
      $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
      $anim.BeginTime = [TimeSpan]::FromMilliseconds($delays[$i])
      $anim.EasingFunction = $easeOut
      $w.BeginAnimation([Windows.Window]::OpacityProperty, $anim)
    } catch { }
  }
}

function Show-Glow {
  if ($script:glowShown) { return }
  $sides = @('top', 'bottom', 'left', 'right')
  if ($script:glowWindows.Count -eq 0) {
    foreach ($s in $sides) { $script:glowWindows += (New-GlowWindow $s) }
  }
  $script:glowAudio = $false
  $script:glowLevel = 0.05
  foreach ($w in $script:glowWindows) {
    try { $w.BeginAnimation([Windows.Window]::OpacityProperty, $null); $w.Opacity = 0.10; $w.Visibility = 'Visible' } catch { }
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
  $script:glowAudio = $false
  $script:glowLevel = 0.0
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
    $sumR = 0.0; $sumG = 0.0; $sumB = 0.0; $sumW = 0.0
    $buckets = @{}
    $stepX = [Math]::Max(1, [int]($w / 16))
    $stepY = [Math]::Max(1, [int]($h / 16))
    for ($y = 0; $y -lt $h; $y += $stepY) {
      for ($x = 0; $x -lt $w; $x += $stepX) {
        $i = $y * $stride + $x * 4
        $b = [double]$pixels[$i]
        $g = [double]$pixels[$i + 1]
        $r = [double]$pixels[$i + 2]
        $max = [Math]::Max($r, [Math]::Max($g, $b))
        $min = [Math]::Min($r, [Math]::Min($g, $b))
        if ($max -le 12) { continue }
        $sat = ($max - $min) / $max
        if ($sat -lt 0.15) { continue }

        $delta = $max - $min
        if ($delta -le 0) { continue }
        if ($max -eq $r) { $hue = 60.0 * ((($g - $b) / $delta) % 6.0) }
        elseif ($max -eq $g) { $hue = 60.0 * ((($b - $r) / $delta) + 2.0) }
        else { $hue = 60.0 * ((($r - $g) / $delta) + 4.0) }
        if ($hue -lt 0) { $hue += 360.0 }

        $bucket = [int][Math]::Floor($hue / 30.0) % 12
        $weight = $sat * ($max / 255.0)
        if (-not $buckets.ContainsKey($bucket)) {
          $buckets[$bucket] = [pscustomobject]@{ W = 0.0; R = 0.0; G = 0.0; B = 0.0 }
        }
        $bb = $buckets[$bucket]
        $bb.W += $weight
        $bb.R += $r * $weight
        $bb.G += $g * $weight
        $bb.B += $b * $weight
      }
    }

    if ($buckets.Count -eq 0) { return [Windows.Media.Color]::FromRgb(196, 214, 232) }
    $best = $buckets.GetEnumerator() | Sort-Object { $_.Value.W } -Descending | Select-Object -First 1
    $bv = $best.Value
    if ($bv.W -le 0) { return [Windows.Media.Color]::FromRgb(196, 214, 232) }
    $r = [int][Math]::Round($bv.R / $bv.W)
    $g = [int][Math]::Round($bv.G / $bv.W)
    $b = [int][Math]::Round($bv.B / $bv.W)

    # приглушаем слишком светлые и серые цвета
    $maxC = [Math]::Max($r, [Math]::Max($g, $b))
    $minC = [Math]::Min($r, [Math]::Min($g, $b))
    $sat = if ($maxC -le 0) { 0 } else { ($maxC - $minC) / [double]$maxC }
    # серые и белые обложки: вместо бирюзы — мягкое «серебристое» свечение
    if ($sat -lt 0.22) {
      $lum = 0.2126 * $r + 0.7152 * $g + 0.0722 * $b
      if ($lum -gt 190) { return [Windows.Media.Color]::FromRgb(226, 236, 246) }
      if ($lum -lt 90) { return [Windows.Media.Color]::FromRgb(146, 166, 188) }
      return [Windows.Media.Color]::FromRgb(196, 214, 232)
    }
    if ($maxC -gt 185) {
      $k = 185.0 / $maxC
      $r = [int]($r * $k); $g = [int]($g * $k); $b = [int]($b * $k)
    } elseif ($maxC -lt 125) {
      # тёмные обложки дают почти невидимую подсветку — поднимаем яркость
      $k = 150.0 / [Math]::Max(1, $maxC)
      $r = [int][Math]::Min(255, $r * $k)
      $g = [int][Math]::Min(255, $g * $k)
      $b = [int][Math]::Min(255, $b * $k)
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
    # без ухода в ноль: текст обновляется сразу и мягко проявляется
    $titleText.Text = $title
    $artistText.Text = $artist
    $albumText.Text = $album
    foreach ($el in @($titleText, $artistText, $albumText)) {
      $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
      $el.Opacity = 1
    }
    $textCol.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $fadeIn = New-Object Windows.Media.Animation.DoubleAnimation(0.35, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(180)))
    $fadeIn.EasingFunction = $easeOut
    $textCol.BeginAnimation([Windows.UIElement]::OpacityProperty, $fadeIn)
    $script:pendingText = $null
    $swapTimer.Stop()
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

function Update-Ring([double]$ratio, $color) {
  try {
    if ($ratio -le 0.0005 -or $ratio -gt 1.0) { $ring.Visibility = 'Collapsed'; if ($ringTrack) { $ringTrack.Visibility = 'Collapsed' }; return }
    if ($ringTrack) { $ringTrack.Visibility = 'Visible' }
    $size = 84.0
    $c = $size / 2.0
    $r = ($size / 2.0) - 2.0
    $startDeg = -90.0
    $endDeg = -90.0 + 360.0 * $ratio
    $a1 = $startDeg * [Math]::PI / 180.0
    $a2 = $endDeg * [Math]::PI / 180.0
    $x1 = $c + $r * [Math]::Cos($a1)
    $y1 = $c + $r * [Math]::Sin($a1)
    $x2 = $c + $r * [Math]::Cos($a2)
    $y2 = $c + $r * [Math]::Sin($a2)
    $large = if (($endDeg - $startDeg) -gt 180.0) { $true } else { $false }

    $geo = New-Object Windows.Media.StreamGeometry
    $ctx = $geo.Open()
    $ctx.BeginFigure((New-Object Windows.Point($x1, $y1)), $false, $false)
    $ctx.ArcTo((New-Object Windows.Point($x2, $y2)), (New-Object Windows.Size($r, $r)), 0.0, $large, [Windows.Media.SweepDirection]::Clockwise, $true, $false)
    $ctx.Close()
    $geo.Freeze()
    $ring.Data = $geo
    if ($color) { $ring.Stroke = New-Object Windows.Media.SolidColorBrush($color) }
    $ring.Visibility = 'Visible'
  } catch { }
}

function Update-Progress {
  $progressRow.Visibility = 'Visible'
  if (-not $script:currentSession) { $progressText.Text = '—:—'; $ring.Visibility = 'Collapsed'; if ($ringTrack) { $ringTrack.Visibility = 'Collapsed' }; return }
  try { $timeline = $script:currentSession.GetTimelineProperties() } catch { $progressText.Text = '—:—'; $ring.Visibility = 'Collapsed'; if ($ringTrack) { $ringTrack.Visibility = 'Collapsed' }; return }
  if (-not $timeline) { $progressText.Text = '—:—'; $ring.Visibility = 'Collapsed'; if ($ringTrack) { $ringTrack.Visibility = 'Collapsed' }; return }

  $total = $timeline.EndTime - $timeline.StartTime
  if ($total.Ticks -le 0) { $progressText.Text = '—:—'; $ring.Visibility = 'Collapsed'; if ($ringTrack) { $ringTrack.Visibility = 'Collapsed' }; return }

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
  Update-Ring $ratio $script:accentColor
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
$swapTimer = New-Object Windows.Threading.DispatcherTimer$swapTimer.Add_Tick({
    try {
      $swapTimer.Stop()
      $pending = $script:pendingText
      if (-not $pending) { return }
      $titleText.Text = $pending.title
      $artistText.Text = $pending.artist
      $albumText.Text = $pending.album
      if ($pending.art) { Set-Art $pending.art }
      Write-Log ('swap text: [' + $pending.title + '] colOp=' + [math]::Round($textCol.Opacity,2) + ' titleOp=' + [math]::Round($titleText.Opacity,2))
      $fadeIn = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(150)))
      $fadeIn.EasingFunction = $easeOut
      $textCol.BeginAnimation([Windows.UIElement]::OpacityProperty, $fadeIn)
      $script:pendingText = $null
    } catch { }
  })

# смена обложки на видимой карточке: лёгкий «переворот»
$script:pendingArt = $null
$artTimer = New-Object Windows.Threading.DispatcherTimer
$artTimer.Add_Tick({
    try {
      $artTimer.Stop()
      $pending = $script:pendingArt
      if (-not $pending) { $pending = $null }
      Set-Art $pending
      $fadeIn = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(140)))
      $fadeIn.EasingFunction = $easeOut
      $coverArt.BeginAnimation([Windows.UIElement]::OpacityProperty, $fadeIn)
      $zoomIn = New-Object Windows.Media.Animation.DoubleAnimation(0.94, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(180)))
      $zoomIn.EasingFunction = $easeOut
      $artScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $zoomIn)
      $artScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $zoomIn)
      $script:pendingArt = $null
    } catch { }
  })

function Fade-Art($art) {
  try {
    Set-Art $art
    $coverArt.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $fadeIn = New-Object Windows.Media.Animation.DoubleAnimation(0.45, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(170)))
    $fadeIn.EasingFunction = $easeOut
    $coverArt.BeginAnimation([Windows.UIElement]::OpacityProperty, $fadeIn)
    $zoomIn = New-Object Windows.Media.Animation.DoubleAnimation(1.06, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(220)))
    $zoomIn.EasingFunction = $easeOut
    $artScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $zoomIn)
    $artScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $zoomIn)
    $script:pendingArt = $null
    $artTimer.Stop()
  } catch { }
}

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
    Write-Log ('show fail: ' + $_.Exception.Message + ' @ ' + ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' '))
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
            Fade-Art $track.Art
            Crossfade-Text $track.Title $(if ($track.Artist) { $track.Artist } else { 'Неизвестный исполнитель' }) $(if ($track.Album) { $track.Album } else { 'Сингл' }) $null
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
        Track-Listening $track $isPlaying
        if ($track.Art -and $script:tintKey -ne $track.Key) {
          $script:tintKey = $track.Key
          $tint = Get-ArtColor $track.Art
          if ($tint) {
            $script:accentColor = $tint
            try { if ($card -and $card.Effect) { $card.Effect.Color = $tint } } catch { }
            Update-CardBorder $tint
            Update-CardBackdrop $track.Art
          }
        }
        if ($script:glowShown -and $track.Art -and $script:glowKey -ne $track.Key) {
          $script:glowKey = $track.Key
          $glowColor = Get-ArtColor $track.Art
          if ($glowColor) { Update-GlowColor $glowColor }
        }
      } else {
        $script:lastStatus = ''
        Track-Listening $null $false
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
      # страховка: если текст застрял невидимым (прерванный кроссфейд) — вернуть
      if ($window.Visibility -eq 'Visible' -and -not $script:pendingText -and $textCol.Opacity -lt 0.5) {
        $textCol.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $textCol.Opacity = 1
        Write-Log 'text opacity restored'
      }
      if ($window.Visibility -eq 'Visible' -and -not $script:pendingText) {
        $bad = @()
        foreach ($el in @($titleText, $artistText, $albumText)) {
          if ($el.Opacity -lt 0.5) { $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $el.Opacity = 1; $bad += 'el' }
        }
        if ($titleText.Text.Length -eq 0) { $bad += 'empty' }
        if ($bad.Count -gt 0) { Write-Log ('watchdog: ' + ($bad -join ',')) }
      }
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
      } elseif ($on -and $script:glowShown) {
        # яркость ведёт таймер уровня звука, здесь ничего не делаем
      }
    } catch { }
  })
$glowTimer.Start()

# яркость подсветки по уровню звука с устройства
$beatTimer = New-Object Windows.Threading.DispatcherTimer
$beatTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$beatTimer.Add_Tick({
    try {
      if (-not $script:glowShown -or $script:glowWindows.Count -eq 0) { return }
      $peak = 0.0
      try { $peak = [double][BrickyardAudio.Endpoint]::GetPeak() } catch { }
      $db = 20.0 * [Math]::Log10([Math]::Max($peak, 0.00001))
      $norm = [Math]::Max(0.0, [Math]::Min(1.0, ($db + 50.0) / 44.0))
      $target = [Math]::Pow($norm, 0.75)
      # быстрая атака, медленное затухание — так слышны удары и бас
      if ($target -gt $script:glowLevel) { $script:glowLevel = $target }
      else { $script:glowLevel = ($script:glowLevel * 0.90) + ($target * 0.10) }
      if ($script:glowLevel -lt 0.015) { $script:glowLevel = 0.015 }
      $val = 0.06 + ($script:glowLevel * 0.42)
      $factors = @(1.0, 0.92, 1.05, 0.88)
      for ($i = 0; $i -lt $script:glowWindows.Count; $i++) {
        $op = [Math]::Min(1.0, [Math]::Max(0.03, $val * $factors[$i]))
        $script:glowWindows[$i].Opacity = $op
      }
    } catch { }
  })
$beatTimer.Start()

# ---------------------------------------------------------------- старт
$script:lastTrack = Get-CurrentTrack
if ($script:lastTrack) { $script:lastKey = $script:lastTrack.Key; $script:lastStatus = $script:lastTrack.Status }
Set-Equalizer ($script:lastStatus -eq 'Playing')
$script:lastVolume = [BrickyardAudio.Endpoint]::GetVolumePercent()
$script:lastMute = [BrickyardAudio.Endpoint]::GetMute()
Write-Log ('started v2 session=' + ($null -ne $sessionManager) + ' volume=' + $script:lastVolume + ' track=' + $(if ($script:lastTrack) { $script:lastTrack.Title } else { '-' }))

# ---------------------------------------------------------------- горячие клавиши
# Отключены: управление удобнее с наушников и панели. Код оставлен на будущее.
$script:hotkeyHook = $null

function Toggle-PlayPause {
  if (-not $script:currentSession) { return }
  try {
    $info = $script:currentSession.GetPlaybackInfo()
    if ($info.PlaybackStatus.ToString() -eq 'Playing') { [void](Await ($script:currentSession.TryPauseAsync()) ([bool])) }
    else { [void](Await ($script:currentSession.TryPlayAsync()) ([bool])) }
  } catch { }
}

function Skip-Track([string]$dir) {
  if (-not $script:currentSession) { return }
  try {
    if ($dir -eq 'next') { [void](Await ($script:currentSession.TrySkipNextAsync()) ([bool])) }
    else { [void](Await ($script:currentSession.TrySkipPreviousAsync()) ([bool])) }
  } catch { }
}

function Register-Hotkeys {
  try {
    $helper = New-Object Windows.Interop.WindowInteropHelper($window)
    $hwnd = $helper.Handle
    if ($hwnd -eq [IntPtr]::Zero) { Write-Log 'hotkeys: no hwnd'; return }
    $source = [Windows.Interop.HwndSource]::FromHwnd($hwnd)
    if (-not $script:hotkeyHook) {
      $script:hotkeyHook = {
        param($hwndArg, $msg, $wParam, $lParam, [ref]$handled)
        if ($msg -ne 0x0312) { return }
        try {
          Write-Log ('hotkey id=' + $wParam)
          switch ([int]$wParam) {
            1 { Toggle-PlayPause }
            2 { Skip-Track 'prev' }
            3 { Skip-Track 'next' }
          }
          $handled.Value = $true
        } catch { }
      }
      [void]$source.AddHook($script:hotkeyHook)
    }
    $mods = 0x4003
    $ok1 = [HotKeys]::RegisterHotKey($hwnd, 1, $mods, 0x20)
    $ok2 = [HotKeys]::RegisterHotKey($hwnd, 2, $mods, 0x25)
    $ok3 = [HotKeys]::RegisterHotKey($hwnd, 3, $mods, 0x27)
    Write-Log ('hotkeys registered: ' + $ok1 + ',' + $ok2 + ',' + $ok3)
  } catch { Write-Log ('hotkeys fail: ' + $_.Exception.Message) }
}

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
          $bitmap.DecodePixelWidth = 256
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
