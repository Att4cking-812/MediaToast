# MusicTray — иконка в трее с панелью управления музыкой.
# Слева от неё: обложка, трек, прогресс, кнопки, громкость и тумблеры.
# Запуск: powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File MusicTray.ps1

param(
  [switch]$Demo
)

$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[void][System.Reflection.Assembly]::Load('System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')

$root = $PSScriptRoot
$logPath = Join-Path $root 'tray.log'
$toastPidPath = Join-Path $root 'toast.pid'

function Write-Log([string]$message) {
  try {
    if ((Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue).Length -gt 150000) { Remove-Item -LiteralPath $logPath -Force }
  } catch { }
  try { Add-Content -LiteralPath $logPath -Value ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $message) -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- один экземпляр
$mutex = New-Object System.Threading.Mutex($false, 'Local\BrickyardMusicTray')
$ok = $false
try { $ok = $mutex.WaitOne(0) } catch { $ok = $false }
if (-not $ok) { Write-Log 'already running, exit'; exit 0 }
try { Set-Content -LiteralPath (Join-Path $root 'tray.pid') -Value $PID -Encoding ASCII } catch { }

# ---------------------------------------------------------------- зависимости
try { Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'AudioEndpoint.cs'), [Text.Encoding]::UTF8)) -Language CSharp -ErrorAction Stop }
catch { Write-Log ('audio fail: ' + $_.Exception.Message) }

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  })[0]

function Await($op, $type) {
  $asTask = $asTaskGeneric.MakeGenericMethod($type)
  $task = $asTask.Invoke($null, @($op))
  if (-not $task.Wait(5000)) { throw 'async timeout' }
  return $task.Result
}

$wtManager = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$wtProps = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
$wtStream = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$wtInput = [Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$asStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@($wtInput))

$script:manager = $null
try { $script:manager = Await ($wtManager::RequestAsync()) $wtManager } catch { Write-Log ('manager fail: ' + $_.Exception.Message) }

$script:session = $null
$script:artKey = ''
$script:artBitmap = $null

function Get-Session {
  if (-not $script:manager) { return $null }
  $sessions = $null
  try { $sessions = $script:manager.GetSessions() } catch { $sessions = $null }
  if (-not $sessions -or $sessions.Count -eq 0) { return $null }
  foreach ($s in $sessions) {
    try { if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') { return $s } } catch { }
  }
  return $sessions[0]
}

# ---------------------------------------------------------------- окно панели
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="Height" Width="352"
        Topmost="True" Opacity="0">
  <Border x:Name="Card" CornerRadius="18" Background="#F5151220" BorderBrush="#2EFFFFFF" BorderThickness="1" Padding="16">
    <Border.Effect>
      <DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.6" Color="#000000"/>
    </Border.Effect>
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Width="58" Height="58" CornerRadius="12" Background="#2A2333" Margin="0,0,12,0">
          <Grid>
            <TextBlock x:Name="CoverGlyph" Text="♪" FontSize="24" Foreground="#6B5E7D"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
            <Border x:Name="CoverArt" CornerRadius="12" Background="Transparent" Opacity="0"/>
          </Grid>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock x:Name="TitleText" Text="Ничего не играет" FontFamily="Segoe UI Semibold" FontSize="14"
                     Foreground="#F4EFFA" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="ArtistText" Text="" FontFamily="Segoe UI" FontSize="11.5"
                     Foreground="#9C8FAE" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="AlbumText" Text="" FontFamily="Segoe UI" FontSize="10.5"
                     Foreground="#6F6382" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </Grid>

      <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Height="4" CornerRadius="2" Background="#2B2439" VerticalAlignment="Center">
          <Border x:Name="Fill" Height="4" CornerRadius="2" Background="#6FD8FF" Width="0" HorizontalAlignment="Left"/>
        </Border>
        <TextBlock x:Name="TimeText" Grid.Column="1" Text="—:—" FontFamily="Segoe UI Semibold" FontSize="10.5"
                   Foreground="#7E7292" Margin="8,0,0,0" VerticalAlignment="Center"/>
      </Grid>

      <Grid Margin="0,14,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="PrevBtn" Grid.Column="0" Width="64" Height="34" CornerRadius="10" Background="#1E1A2A"
                HorizontalAlignment="Center" Cursor="Hand">
          <TextBlock Text="◀◀" FontSize="12" Foreground="#D9CFE6" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <Border x:Name="PlayBtn" Grid.Column="1" Width="64" Height="34" CornerRadius="10" Background="#231E31"
                HorizontalAlignment="Center" Cursor="Hand" Margin="8,0">
          <TextBlock x:Name="PlayGlyph" Text="▶" FontSize="14" Foreground="#EAF7EF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <Border x:Name="NextBtn" Grid.Column="2" Width="64" Height="34" CornerRadius="10" Background="#1E1A2A"
                HorizontalAlignment="Center" Cursor="Hand">
          <TextBlock Text="▶▶" FontSize="12" Foreground="#D9CFE6" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </Grid>

      <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="VolGlyph" Grid.Column="0" Text="🔊" FontSize="12" Foreground="#9C8FAE" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <Slider x:Name="VolumeSlider" Grid.Column="1" Minimum="0" Maximum="100" Value="50" VerticalAlignment="Center"
                Height="18" Background="Transparent" BorderBrush="Transparent" Foreground="#59F28F">
          <Slider.Template>
            <ControlTemplate TargetType="Slider">
              <Grid VerticalAlignment="Center" Height="18">
                <Border Height="4" CornerRadius="2" Background="#2B2439" VerticalAlignment="Center"/>
                <Track x:Name="PART_Track">
                  <Track.DecreaseRepeatButton>
                    <RepeatButton Command="Slider.DecreaseLarge">
                      <RepeatButton.Template>
                        <ControlTemplate TargetType="RepeatButton">
                          <Border Height="4" CornerRadius="2" Background="#59F28F" VerticalAlignment="Center"/>
                        </ControlTemplate>
                      </RepeatButton.Template>
                    </RepeatButton>
                  </Track.DecreaseRepeatButton>
                  <Track.Thumb>
                    <Thumb Width="12" Height="12">
                      <Thumb.Template>
                        <ControlTemplate TargetType="Thumb">
                          <Ellipse Fill="#EAF7EF" Width="12" Height="12"/>
                        </ControlTemplate>
                      </Thumb.Template>
                    </Thumb>
                  </Track.Thumb>
                  <Track.IncreaseRepeatButton>
                    <RepeatButton Command="Slider.IncreaseLarge">
                      <RepeatButton.Template>
                        <ControlTemplate TargetType="RepeatButton">
                          <Border Background="Transparent"/>
                        </ControlTemplate>
                      </RepeatButton.Template>
                    </RepeatButton>
                  </Track.IncreaseRepeatButton>
                </Track>
              </Grid>
            </ControlTemplate>
          </Slider.Template>
        </Slider>
        <TextBlock x:Name="VolText" Grid.Column="2" Text="50" FontFamily="Segoe UI Semibold" FontSize="10.5"
                   Foreground="#9C8FAE" VerticalAlignment="Center" MinWidth="24" TextAlignment="Right"/>
      </Grid>

      <Border Height="1" Background="#22FFFFFF" Margin="0,12,0,10"/>

      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border x:Name="PillToast" Grid.Column="0" CornerRadius="10" Background="#171322" BorderBrush="#26FFFFFF" BorderThickness="1"
                Padding="8,6" Margin="0,0,6,0" Cursor="Hand">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
              <TextBlock Text="Плашка" FontFamily="Segoe UI Semibold" FontSize="11.5" Foreground="#E7DFF2"/>
              <TextBlock x:Name="ToastState" Text="вкл" FontFamily="Segoe UI" FontSize="10" Foreground="#59F28F" Margin="0,1,0,0"/>
            </StackPanel>
            <Border x:Name="ToastDot" Grid.Column="1" Width="8" Height="8" CornerRadius="4" Background="#59F28F" VerticalAlignment="Center" Margin="6,0,0,0"/>
          </Grid>
        </Border>

        <Border x:Name="PillAuto" Grid.Column="1" CornerRadius="10" Background="#171322" BorderBrush="#26FFFFFF" BorderThickness="1"
                Padding="8,6" Margin="6,0,0,0" Cursor="Hand">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
              <TextBlock Text="Автозапуск" FontFamily="Segoe UI Semibold" FontSize="11.5" Foreground="#E7DFF2"/>
              <TextBlock x:Name="AutoState" Text="вкл" FontFamily="Segoe UI" FontSize="10" Foreground="#59F28F" Margin="0,1,0,0"/>
            </StackPanel>
            <Border x:Name="AutoDot" Grid.Column="1" Width="8" Height="8" CornerRadius="4" Background="#59F28F" VerticalAlignment="Center" Margin="6,0,0,0"/>
          </Grid>
        </Border>
      </Grid>

      <Border x:Name="PillGlow" CornerRadius="10" Background="#171322" BorderBrush="#26FFFFFF" BorderThickness="1"
              Padding="8,6" Margin="0,8,0,0" Cursor="Hand">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0">
            <TextBlock Text="Подсветка краёв" FontFamily="Segoe UI Semibold" FontSize="11.5" Foreground="#E7DFF2"/>
            <TextBlock x:Name="GlowState" Text="выкл" FontFamily="Segoe UI" FontSize="10" Foreground="#877A9A" Margin="0,1,0,0"/>
          </StackPanel>
          <Border x:Name="GlowDot" Grid.Column="1" Width="8" Height="8" CornerRadius="4" Background="#3A3148" VerticalAlignment="Center" Margin="6,0,0,0"/>
        </Grid>
      </Border>
    </StackPanel>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$winCard = $window.FindName('Card')
$coverArt = $window.FindName('CoverArt')
$coverGlyph = $window.FindName('CoverGlyph')
$titleText = $window.FindName('TitleText')
$artistText = $window.FindName('ArtistText')
$albumText = $window.FindName('AlbumText')
$fill = $window.FindName('Fill')
$timeText = $window.FindName('TimeText')
$prevBtn = $window.FindName('PrevBtn')
$playBtn = $window.FindName('PlayBtn')
$playGlyph = $window.FindName('PlayGlyph')
$nextBtn = $window.FindName('NextBtn')
$volumeSlider = $window.FindName('VolumeSlider')
$volText = $window.FindName('VolText')
$volGlyph = $window.FindName('VolGlyph')
$pillToast = $window.FindName('PillToast')
$toastState = $window.FindName('ToastState')
$toastDot = $window.FindName('ToastDot')
$pillAuto = $window.FindName('PillAuto')
$autoState = $window.FindName('AutoState')
$autoDot = $window.FindName('AutoDot')
$pillGlow = $window.FindName('PillGlow')
$glowState = $window.FindName('GlowState')
$glowDot = $window.FindName('GlowDot')

$script:startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'MediaToast.lnk'
$script:trayLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'MusicTray.lnk'
$script:toastVbs = Join-Path $root 'MediaToast.vbs'
$script:trayVbs = Join-Path $root 'MusicTray.vbs'
$script:glowFlag = Join-Path $root 'glow.on'

function Get-ToastAlive {
  $p = Get-Content -LiteralPath $toastPidPath -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p -match '^\d+$') { return [bool](Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue) }
  return $false
}

function Update-Pills {
  $alive = Get-ToastAlive
  if ($alive) {
    $toastState.Text = 'вкл'
    $toastState.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(89,242,143))
    $toastDot.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(89,242,143))
  } else {
    $toastState.Text = 'выкл'
    $toastState.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(255,122,107))
    $toastDot.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(255,122,107))
  }

  $auto = (Test-Path -LiteralPath $script:startupLnk) -and (Test-Path -LiteralPath $script:trayLnk)
  if ($auto) {
    $autoState.Text = 'вкл'
    $autoState.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(89,242,143))
    $autoDot.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(89,242,143))
  } else {
    $autoState.Text = 'выкл'
    $autoState.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(255,122,107))
    $autoDot.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(255,122,107))
  }

  $glow = Test-Path -LiteralPath $script:glowFlag
  if ($glow) {
    $glowState.Text = 'вкл — в цвет обложки'
    $glowState.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(89,242,143))
    $glowDot.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(89,242,143))
  } else {
    $glowState.Text = 'выкл'
    $glowState.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(135,122,154))
    $glowDot.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(58,49,72))
  }
}

function Start-Toast {
  $p = Get-Content -LiteralPath $toastPidPath -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p -match '^\d+$' -and (Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue)) { return }
  Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $script:toastVbs + '"')
}

function Stop-Toast {
  $p = Get-Content -LiteralPath $toastPidPath -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p -match '^\d+$') { Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue }
}

function Set-Autostart([bool]$on) {
  $ico = Join-Path $root 'App.ico'
  $ws = New-Object -ComObject WScript.Shell

  $targets = @(
    @{ Lnk = $script:startupLnk; Vbs = $script:toastVbs; Desc = 'MediaToast — плашка «сейчас играет»' },
    @{ Lnk = $script:trayLnk; Vbs = $script:trayVbs; Desc = 'MusicTray — управление музыкой' }
  )

  foreach ($t in $targets) {
    if ($on) {
      if (-not (Test-Path -LiteralPath $t.Vbs)) { continue }
      $sc = $ws.CreateShortcut($t.Lnk)
      $sc.TargetPath = (Join-Path $env:WINDIR 'System32\wscript.exe')
      $sc.Arguments = '"' + $t.Vbs + '"'
      $sc.WorkingDirectory = $root
      if (Test-Path -LiteralPath $ico) { $sc.IconLocation = $ico + ',0' }
      $sc.Description = $t.Desc
      $sc.Save()
    } else {
      Remove-Item -LiteralPath $t.Lnk -Force -ErrorAction SilentlyContinue
    }
  }
}

# ---------------------------------------------------------------- данные
function Update-Info {
  try {
    $s = Get-Session
    $script:session = $s
    if (-not $s) {
      $titleText.Text = 'Ничего не играет'
      $artistText.Text = ''
      $albumText.Text = ''
      $timeText.Text = '—:—'
      $fill.Width = 0
      $playGlyph.Text = '▶'
      return
    }

    $props = $null
    try { $props = Await ($s.TryGetMediaPropertiesAsync()) $wtProps } catch { $props = $null }
    if ($props -and $props.Title) {
      $titleText.Text = [string]$props.Title
      $artistText.Text = if ($props.Artist) { [string]$props.Artist } else { 'Неизвестный исполнитель' }
      $albumText.Text = if ($props.AlbumTitle) { [string]$props.AlbumTitle } else { 'Сингл' }
      try { $notify.Text = ('♪ ' + [string]$props.Title).Substring(0, [Math]::Min(60, ('♪ ' + [string]$props.Title).Length)) } catch { }

      $key = ([string]$props.Title) + '|' + ([string]$props.Artist) + '|' + ([string]$props.AlbumTitle)
      if ($key -ne $script:artKey -and $props.Thumbnail) {
        try {
          $stream = Await ($props.Thumbnail.OpenReadAsync()) $wtStream
          $net = $asStreamForRead.Invoke($null, @($stream))
          $ms = New-Object System.IO.MemoryStream
          $net.CopyTo($ms)
          $bytes = $ms.ToArray()
          $ms.Dispose(); $net.Dispose()
          if ($bytes.Length -gt 0) {
            $bmp = New-Object Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.DecodePixelWidth = 116
            $bmp.StreamSource = New-Object System.IO.MemoryStream(, $bytes)
            $bmp.EndInit()
            $bmp.Freeze()
            $script:artBitmap = $bmp
            $brush = New-Object Windows.Media.ImageBrush($bmp)
            $brush.Stretch = [Windows.Media.Stretch]::UniformToFill
            $coverArt.Background = $brush
            $coverArt.Opacity = 1
            $coverGlyph.Visibility = 'Collapsed'
          }
        } catch { }
        $script:artKey = $key
      }
      if (-not $props.Thumbnail) {
        $coverArt.Opacity = 0
        $coverGlyph.Visibility = 'Visible'
      }
    }

    $info = $null
    try { $info = $s.GetPlaybackInfo() } catch { }
    if ($info) {
      $playGlyph.Text = if ($info.PlaybackStatus.ToString() -eq 'Playing') { 'II' } else { '▶' }
    }

    try {
      $tl = $s.GetTimelineProperties()
      $total = $tl.EndTime - $tl.StartTime
      $pos = $tl.Position
      if ($info -and $info.PlaybackStatus.ToString() -eq 'Playing') {
        $delta = [DateTimeOffset]::UtcNow - $tl.LastUpdatedTime
        if ($delta.TotalSeconds -gt 0 -and $delta.TotalSeconds -lt 30) { $pos = $pos.Add([TimeSpan]::FromSeconds($delta.TotalSeconds)) }
      }
      if ($total.Ticks -gt 0) {
        $el = $pos - $tl.StartTime
        if ($el.Ticks -lt 0) { $el = [TimeSpan]::Zero }
        if ($el -gt $total) { $el = $total }
        $ratio = $el.TotalSeconds / $total.TotalSeconds
        $fill.Width = [Math]::Max(0, [Math]::Min(320, 320 * $ratio))
        $timeText.Text = ('{0}:{1:00}' -f [int][Math]::Floor($el.TotalMinutes), $el.Seconds) + ' / ' + ('{0}:{1:00}' -f [int][Math]::Floor($total.TotalMinutes), $total.Seconds)
      }
    } catch { }
  } catch { }
}

$volumeGuard = $false
function Sync-Volume {
  try {
    $v = [BrickyardAudio.Endpoint]::GetVolumePercent()
    if ($v -ge 0) {
      $volumeGuard = $true
      $volumeSlider.Value = $v
      $volText.Text = [string]$v
      $volumeGuard = $false
    }
    $muted = [BrickyardAudio.Endpoint]::GetMute()
    $volGlyph.Text = if ($muted) { '🔇' } else { '🔊' }
  } catch { }
}

$volumeSlider.Add_ValueChanged({
    if ($volumeGuard) { return }
    try {
      $val = [int][Math]::Round($volumeSlider.Value)
      [BrickyardAudio.Endpoint]::SetVolumePercent($val)
      $volText.Text = [string]$val
    } catch { }
  })

# ---------------------------------------------------------------- кнопки
$prevBtn.Add_MouseLeftButtonUp({ try { [void](Await ($script:session.TrySkipPreviousAsync()) ([bool])) } catch { } })
$nextBtn.Add_MouseLeftButtonUp({ try { [void](Await ($script:session.TrySkipNextAsync()) ([bool])) } catch { } })
$playBtn.Add_MouseLeftButtonUp({
    try {
      $info = $script:session.GetPlaybackInfo()
      if ($info.PlaybackStatus.ToString() -eq 'Playing') { [void](Await ($script:session.TryPauseAsync()) ([bool])) }
      else { [void](Await ($script:session.TryPlayAsync()) ([bool])) }
      Start-Sleep -Milliseconds 120
      Update-Info
    } catch { }
  })

$pillToast.Add_MouseLeftButtonUp({
    if (Get-ToastAlive) { Stop-Toast } else { Start-Toast }
    Start-Sleep -Milliseconds 400
    Update-Pills
  })

$pillAuto.Add_MouseLeftButtonUp({
    $isOn = (Test-Path -LiteralPath $script:startupLnk) -and (Test-Path -LiteralPath $script:trayLnk)
    Set-Autostart (-not $isOn)
    Update-Pills
  })

$pillGlow.Add_MouseLeftButtonUp({
    if (Test-Path -LiteralPath $script:glowFlag) {
      Remove-Item -LiteralPath $script:glowFlag -Force -ErrorAction SilentlyContinue
    } else {
      Start-Toast
      Set-Content -LiteralPath $script:glowFlag -Value '1' -Encoding ASCII
    }
    Start-Sleep -Milliseconds 400
    Update-Pills
  })

# ---------------------------------------------------------------- показ/скрытие
function Show-Panel {
  Update-Info
  Sync-Volume
  Update-Pills
  $window.Visibility = 'Visible'
  $window.UpdateLayout()
  $area = [System.Windows.SystemParameters]::WorkArea
  $window.Left = $area.Right - $window.ActualWidth - 14
  $window.Top = $area.Bottom - $window.ActualHeight - 14
  if ($window.Top -lt $area.Top) { $window.Top = $area.Top + 14 }
  $fade = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(160)))
  $window.BeginAnimation([Windows.Window]::OpacityProperty, $fade)
}

function Hide-Panel {
  $fade = New-Object Windows.Media.Animation.DoubleAnimation(1.0, 0.0, [Windows.Duration]([TimeSpan]::FromMilliseconds(140)))
  $fade.Add_Completed({ try { $window.Visibility = 'Hidden' } catch { } })
  $window.BeginAnimation([Windows.Window]::OpacityProperty, $fade)
}

$window.Add_Deactivated({ Hide-Panel })

# таймер обновления, пока панель видна
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({
    if ($window.Visibility -eq 'Visible') { Update-Info; Sync-Volume }
  })
$timer.Start()

# ---------------------------------------------------------------- трей
$notify = New-Object System.Windows.Forms.NotifyIcon
$iconPath = Join-Path $root 'App.ico'
if (Test-Path -LiteralPath $iconPath) { $notify.Icon = New-Object System.Drawing.Icon($iconPath) }
else { $notify.Icon = [System.Drawing.SystemIcons]::Application }
$notify.Text = 'MediaToast — управление музыкой'
$notify.Visible = $true

$notify.Add_MouseClick({
    if ($window.Visibility -eq 'Visible') { Hide-Panel } else { Show-Panel }
  })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Открыть панель')
$miOpen.Add_Click({ Show-Panel })
$miToast = $menu.Items.Add('Плашка вкл/выкл')
$miToast.Add_Click({ if (Get-ToastAlive) { Stop-Toast } else { Start-Toast }; Start-Sleep -Milliseconds 300; Update-Pills })
$miAuto = $menu.Items.Add('Автозапуск вкл/выкл')
$miAuto.Add_Click({ Set-Autostart (-not (Test-Path -LiteralPath $script:startupLnk)); Update-Pills })
$miGlow = $menu.Items.Add('Подсветка краёв вкл/выкл')
$miGlow.Add_Click({
    if (Test-Path -LiteralPath $script:glowFlag) { Remove-Item -LiteralPath $script:glowFlag -Force -ErrorAction SilentlyContinue }
    else { Start-Toast; Set-Content -LiteralPath $script:glowFlag -Value '1' -Encoding ASCII }
    Start-Sleep -Milliseconds 300
    Update-Pills
  })
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Выход')
$miExit.Add_Click({
    $notify.Visible = $false
    $notify.Dispose()
    $window.Close()
    [System.Windows.Application]::Current.Shutdown()
  })
$notify.ContextMenuStrip = $menu

Write-Log ('started, toast=' + (Get-ToastAlive))

# ---------------------------------------------------------------- приложение
$app = New-Object Windows.Application
$app.Add_Startup({
    $window.Show()
    $window.Visibility = 'Hidden'
    if ($Demo) { Show-Panel }
  })
[void]$app.Run()
