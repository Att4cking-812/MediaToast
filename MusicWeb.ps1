# MusicWeb — локальная веб-панель: сейчас играет, управление, статистика.
# Запуск: powershell -NoProfile -Sta -ExecutionPolicy Bypass -File MusicWeb.ps1
param(
  [int]$Port = 8765
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Web
[void][System.Reflection.Assembly]::Load('System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')

$root = $PSScriptRoot
$logPath = Join-Path $root 'web.log'

function Write-Log([string]$m) {
  try {
    if ((Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue).Length -gt 120000) { Remove-Item -LiteralPath $logPath -Force }
  } catch { }
  try { Add-Content -LiteralPath $logPath -Value ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m) -Encoding UTF8 } catch { }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\BrickyardMusicWeb')
$ok = $false
try { $ok = $mutex.WaitOne(0) } catch { $ok = $false }
if (-not $ok) { Write-Log 'already running'; exit 0 }
try { Set-Content -LiteralPath (Join-Path $root 'web.pid') -Value $PID -Encoding ASCII } catch { }

try { Add-Type -Path @((Join-Path $root 'AudioEndpoint.cs'), (Join-Path $root 'AppMeter.cs')) -ErrorAction Stop }
catch {
  Write-Log ('audio fail: ' + $_.Exception.Message)
  try { Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'AudioEndpoint.cs'), [Text.Encoding]::UTF8)) -Language CSharp } catch { }
}

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  })[0]

function Await($op, $type) {
  $t = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
  if (-not $t.Wait(5000)) { throw 'timeout' }
  return $t.Result
}

$wtManager = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$wtProps = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
$wtStream = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$wtInput = [Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$asStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@($wtInput))

$script:manager = $null
try { $script:manager = Await ($wtManager::RequestAsync()) $wtManager } catch { }
$script:artKey = ''
$script:artBytes = $null
$script:session = $null
$script:posKey = ''
$script:posVal = 0.0
$script:posAt = [DateTimeOffset]::UtcNow

function Get-Session {
  if (-not $script:manager) {
    try { $script:manager = Await ($wtManager::RequestAsync()) $wtManager } catch { return $null }
  }
  $sessions = $null
  try { $sessions = $script:manager.GetSessions() } catch { }
  if (-not $sessions -or $sessions.Count -eq 0) { return $null }
  $ordered = @()
  foreach ($s in $sessions) { try { if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') { $ordered += $s } } catch { } }
  foreach ($s in $sessions) { if ($ordered -notcontains $s) { $ordered += $s } }
  foreach ($s in $ordered) {
    try {
      $p = Await ($s.TryGetMediaPropertiesAsync()) $wtProps
      if ($p -and $p.Title) { $script:session = $s; return $s }
    } catch { }
  }
  return $null
}

function Get-NowState {
  $s = Get-Session
  if (-not $s) { return @{ ok = $false } }
  $res = @{ ok = $true; title = ''; artist = ''; album = ''; status = ''; position = 0; duration = 0; key = '' }
  try {
    $p = Await ($s.TryGetMediaPropertiesAsync()) $wtProps
    $res.title = [string]$p.Title
    $res.artist = [string]$p.Artist
    $res.album = [string]$p.AlbumTitle
    $res.key = ($res.title + '|' + $res.artist + '|' + $res.album)
  } catch { }
  try { $res.status = $s.GetPlaybackInfo().PlaybackStatus.ToString() } catch { }
  try {
    $tl = $s.GetTimelineProperties()
    $total = $tl.EndTime - $tl.StartTime
    $pos = $tl.Position
    if ($res.status -eq 'Playing') {
      $delta = [DateTimeOffset]::UtcNow - $tl.LastUpdatedTime
      if ($delta.TotalSeconds -gt 0 -and $delta.TotalSeconds -lt 30) { $pos = $pos.Add([TimeSpan]::FromSeconds($delta.TotalSeconds)) }
    }
    $el = $pos - $tl.StartTime
    if ($el.Ticks -lt 0) { $el = [TimeSpan]::Zero }
    if ($total.Ticks -gt 0 -and $el -gt $total) { $el = $total }
    $res.position = [int][Math]::Floor($el.TotalSeconds)
    $res.duration = [int][Math]::Floor([Math]::Max(0, $total.TotalSeconds))
  } catch { }

  # монотонная позиция: плеер иногда отдаёт 0, не даём прогрессу сбрасываться
  try {
    $now2 = [DateTimeOffset]::UtcNow
    if ([string]$res.key -ne $script:posKey) {
      $script:posKey = [string]$res.key
      $script:posVal = [double]$res.position
      $script:posAt = $now2
    } else {
      $elapsed = ($now2 - $script:posAt).TotalSeconds
      $cand = $script:posVal + [Math]::Max(0.0, $elapsed)
      if ($res.position -ge ($cand - 2)) { $script:posVal = [double]$res.position }
      else { $script:posVal = $cand }
      $script:posAt = $now2
      if ($res.duration -gt 0 -and $script:posVal -gt $res.duration) { $script:posVal = $res.duration }
      $res.position = [int][Math]::Floor($script:posVal)
    }
  } catch { }

  return $res
}

function Get-ArtBytes {
  $s = Get-Session
  if (-not $s) { return $null }
  try {
    $p = Await ($s.TryGetMediaPropertiesAsync()) $wtProps
    if (-not $p -or -not $p.Thumbnail) { return $null }
    $key = ([string]$p.Title) + '|' + ([string]$p.Artist) + '|' + ([string]$p.AlbumTitle)
    if ($key -eq $script:artKey -and $script:artBytes) { return $script:artBytes }
    $stream = Await ($p.Thumbnail.OpenReadAsync()) $wtStream
    $net = $asStreamForRead.Invoke($null, @($stream))
    $ms = New-Object System.IO.MemoryStream
    $net.CopyTo($ms)
    $bytes = $ms.ToArray()
    $ms.Dispose(); $net.Dispose()
    if ($bytes.Length -gt 0) {
      $script:artBytes = $bytes
      $script:artKey = $key
      return $bytes
    }
  } catch { }
  return $null
}

function Get-Stats {
  $src = Join-Path $root 'listening.tsv'
  $rows = @()
  if (Test-Path -LiteralPath $src) {
    foreach ($line in Get-Content -LiteralPath $src -Encoding UTF8) {
      if (-not $line.Trim()) { continue }
      $parts = $line.Split("`t")
      if ($parts.Count -lt 4) { continue }
      $ts = [datetime]::MinValue
      try { $ts = [datetime]::ParseExact($parts[0], 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
      $secs = 0
      [void][int]::TryParse($parts[1], [ref]$secs)
      if ($secs -le 0) { continue }
      $rows += [pscustomobject]@{ Ts = $ts; Secs = $secs; Artist = $parts[2]; Title = $parts[3] }
    }
  }
  $today = (Get-Date).Date
  $total = 0; $todaySecs = 0; $week = 0
  $artists = @{}; $tracks = @{}; $days = @{}
  foreach ($r in $rows) {
    $total += $r.Secs
    if ($r.Ts.Date -eq $today) { $todaySecs += $r.Secs }
    if ($r.Ts.Date -ge $today.AddDays(-6)) { $week += $r.Secs }
    $a = if ($r.Artist) { $r.Artist } else { 'Неизвестный' }
    if (-not $artists.ContainsKey($a)) { $artists[$a] = 0 }
    $artists[$a] += $r.Secs
    $t = $a + ' — ' + $r.Title
    if (-not $tracks.ContainsKey($t)) { $tracks[$t] = 0 }
    $tracks[$t] += $r.Secs
    $d = $r.Ts.ToString('yyyy-MM-dd')
    if (-not $days.ContainsKey($d)) { $days[$d] = 0 }
    $days[$d] += $r.Secs
  }
  $chart = @()
  for ($i = 13; $i -ge 0; $i--) {
    $d = $today.AddDays(-$i)
    $k = $d.ToString('yyyy-MM-dd')
    $chart += @{ day = $d.ToString('dd.MM'); secs = $(if ($days.ContainsKey($k)) { $days[$k] } else { 0 }) }
  }
  return @{
    ok      = $true
    total   = $total
    today   = $todaySecs
    week    = $week
    chart   = $chart
    artists = @($artists.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6 | ForEach-Object { @{ name = $_.Key; secs = $_.Value } })
    tracks  = @($tracks.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 12 | ForEach-Object { @{ name = $_.Key; secs = $_.Value } })
  }
}

$html = @'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Музыка — панель</title>
<style>
  :root{--bg:#0d0b12;--panel:#16121f;--line:#2a2237;--text:#f1ecf8;--muted:#9b8fae;--green:#59f28f;--cyan:#6fd8ff;--pink:#ff6b9d;--gold:#f0c060}
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;color:var(--text);font-family:"Segoe UI",system-ui,sans-serif;
    background:radial-gradient(1000px 600px at 10% -10%,rgba(111,216,255,.10),transparent 60%),radial-gradient(900px 600px at 90% 0%,rgba(255,107,157,.10),transparent 55%),var(--bg)}
  .wrap{max-width:1000px;margin:0 auto;padding:28px 18px 60px}
  .hero{position:relative;overflow:hidden;border:1px solid var(--line);border-radius:24px;padding:22px;
    background:linear-gradient(150deg,rgba(30,24,42,.95),rgba(14,12,20,.97));box-shadow:0 30px 80px rgba(0,0,0,.5)}
  .hero-bg{position:absolute;inset:-40px;background-size:cover;background-position:center;opacity:.28;filter:blur(30px) saturate(1.2);transform:scale(1.15)}
  .hero-in{position:relative;display:flex;gap:20px;align-items:center}
  .art{width:170px;height:170px;border-radius:20px;background:#241d31 center/cover no-repeat;flex:none;box-shadow:0 18px 50px rgba(0,0,0,.55)}
  .meta{flex:1;min-width:0}
  .kicker{font-size:10px;letter-spacing:1.6px;text-transform:uppercase;color:var(--cyan)}
  h1{margin:6px 0 4px;font-size:30px;line-height:1.1;letter-spacing:-.6px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .artist{color:var(--muted);font-size:14px}
  .album{color:#6f6382;font-size:12px;margin-top:4px}
  .bar{height:6px;border-radius:99px;background:#2b2439;margin:16px 0 8px;overflow:hidden}
  .bar i{display:block;height:100%;width:0;border-radius:99px;background:linear-gradient(90deg,var(--cyan),var(--green));box-shadow:0 0 16px rgba(111,216,255,.45);transition:width .4s linear}
  .times{display:flex;justify-content:space-between;color:#7e7292;font-size:12px;font-variant-numeric:tabular-nums}
  .controls{display:flex;gap:10px;margin-top:16px}
  button{border:1px solid var(--line);background:#1d1830;color:var(--text);border-radius:12px;padding:10px 18px;font-size:15px;cursor:pointer;transition:.15s}
  button:hover{background:#2a2340;transform:translateY(-1px)}
  button.main{background:linear-gradient(120deg,#59f28f,#6fd8ff);color:#08110c;font-weight:800;border:0}
  .vol{display:flex;align-items:center;gap:10px;margin-top:14px}
  input[type=range]{flex:1;accent-color:#59f28f}
  .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-top:18px}
  .card{background:linear-gradient(160deg,rgba(23,19,33,.96),rgba(14,12,20,.97));border:1px solid var(--line);border-radius:16px;padding:14px 16px}
  .card .k{font-size:10px;letter-spacing:1.4px;text-transform:uppercase;color:var(--muted)}
  .card .v{font-size:24px;font-weight:800;margin-top:4px}
  .grid{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:14px}
  h2{font-size:11px;letter-spacing:1.4px;text-transform:uppercase;color:var(--gold);margin:0 0 10px}
  .chart{display:flex;align-items:flex-end;gap:8px;height:150px}
  .bw{flex:1;display:flex;flex-direction:column;justify-content:flex-end;align-items:center;gap:5px}
  .bw .b{width:100%;border-radius:6px 6px 2px 2px;background:linear-gradient(180deg,var(--cyan),rgba(111,216,255,.15))}
  .bw span{font-size:9px;color:#6f6382}
  .row{display:flex;justify-content:space-between;gap:10px;padding:7px 0;border-bottom:1px dashed var(--line);font-size:13px}
  .row:last-child{border:0}
  .row span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .row b{color:#cfc3dd;white-space:nowrap}
  @media(max-width:720px){.hero-in{flex-direction:column;align-items:flex-start}.art{width:100%;height:220px}.cards,.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="wrap">
  <div class="hero">
    <div class="hero-bg" id="heroBg"></div>
    <div class="hero-in">
      <div class="art" id="art"></div>
      <div class="meta">
        <div class="kicker" id="status">подключение…</div>
        <h1 id="title">—</h1>
        <div class="artist" id="artist"></div>
        <div class="album" id="album"></div>
        <div class="bar"><i id="fill"></i></div>
        <div class="times"><span id="pos">0:00</span><span id="dur">0:00</span></div>
        <div class="controls">
          <button id="prev">◀◀</button>
          <button class="main" id="play">▶</button>
          <button id="next">▶▶</button>
        </div>
        <div class="vol"><span id="volIcon">🔊</span><input id="vol" type="range" min="0" max="100" value="50"><span id="volNum">50</span></div>
      </div>
    </div>
  </div>

  <div class="cards">
    <div class="card"><div class="k">Сегодня</div><div class="v" id="sToday">—</div></div>
    <div class="card"><div class="k">7 дней</div><div class="v" id="sWeek">—</div></div>
    <div class="card"><div class="k">Всего</div><div class="v" id="sTotal">—</div></div>
  </div>

  <div class="card" style="margin-top:14px">
    <h2>По дням</h2>
    <div class="chart" id="chart"></div>
  </div>

  <div class="grid">
    <div class="card"><h2>Топ исполнителей</h2><div id="artists"></div></div>
    <div class="card"><h2>Топ треков</h2><div id="tracks"></div></div>
  </div>
</div>
<script>
const $ = id => document.getElementById(id);
let artKey = '';
let playing = false;

function fmt(s){ s = Math.max(0, Math.floor(s)); const m = Math.floor(s/60); return m + ':' + String(s%60).padStart(2,'0'); }
function dur(sec){ sec = Math.max(0, Math.floor(sec)); const h=Math.floor(sec/3600), m=Math.floor((sec%3600)/60); return h ? (h+' ч '+m+' мин') : (m+' мин'); }

async function refreshNow(){
  try {
    const r = await fetch('/api/now', {cache:'no-store'});
    const d = await r.json();
    if (!d.ok) { $('status').textContent = 'ничего не играет'; $('title').textContent='—'; $('artist').textContent=''; $('album').textContent=''; $('fill').style.width='0%'; return; }
    $('status').textContent = d.status === 'Playing' ? 'сейчас играет' : 'пауза';
    $('title').textContent = d.title || '—';
    $('artist').textContent = d.artist || 'Неизвестный исполнитель';
    $('album').textContent = d.album || 'Сингл';
    const pct = d.duration > 0 ? (d.position / d.duration * 100) : 0;
    $('fill').style.width = pct + '%';
    $('pos').textContent = fmt(d.position);
    $('dur').textContent = fmt(d.duration);
    $('play').textContent = d.status === 'Playing' ? 'II' : '▶';
    playing = d.status === 'Playing';
    if (d.key !== artKey) {
      artKey = d.key || '';
      $('art').style.backgroundImage = 'url(/api/art?k=' + encodeURIComponent(artKey) + ')';
      $('heroBg').style.backgroundImage = 'url(/api/art?k=' + encodeURIComponent(artKey) + ')';
      document.body.style.transition = 'background .6s';
    }
  } catch(e) { $('status').textContent = 'нет связи с сервером'; }
}

async function refreshStats(){
  try {
    const r = await fetch('/api/stats', {cache:'no-store'});
    const d = await r.json();
    $('sToday').textContent = dur(d.today);
    $('sWeek').textContent = dur(d.week);
    $('sTotal').textContent = dur(d.total);
    const max = Math.max(1, ...d.chart.map(x=>x.secs));
    $('chart').innerHTML = d.chart.map(x => '<div class="bw" title="'+dur(x.secs)+'"><div class="b" style="height:'+Math.round(x.secs/max*130)+'px"></div><span>'+x.day+'</span></div>').join('');
    $('artists').innerHTML = (d.artists||[]).map(a => '<div class="row"><span>'+esc(a.name)+'</span><b>'+dur(a.secs)+'</b></div>').join('') || '<div class="row"><span>пусто</span><b></b></div>';
    $('tracks').innerHTML = (d.tracks||[]).map(a => '<div class="row"><span>'+esc(a.name)+'</span><b>'+dur(a.secs)+'</b></div>').join('') || '<div class="row"><span>пусто</span><b></b></div>';
  } catch(e){}
}
function esc(s){ return String(s).replace(/[&<>"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }

async function ctl(action){ await fetch('/api/control?do='+action, {method:'POST'}); setTimeout(refreshNow, 300); }

$('prev').onclick = () => ctl('prev');
$('next').onclick = () => ctl('next');
$('play').onclick = () => ctl(playing ? 'pause' : 'play');
$('vol').oninput = e => { $('volNum').textContent = e.target.value; fetch('/api/volume?set=' + e.target.value, {method:'POST'}); };

async function refreshVol(){
  try { const r = await fetch('/api/volume', {cache:'no-store'}); const d = await r.json(); if (!document.activeElement || document.activeElement.id !== 'vol') { $('vol').value = d.percent; $('volNum').textContent = d.percent; } $('volIcon').textContent = d.muted ? '🔇' : '🔊'; } catch(e){}
}

refreshNow(); refreshStats(); refreshVol();
setInterval(refreshNow, 1500);
setInterval(refreshStats, 10000);
setInterval(refreshVol, 2000);
</script>
</body>
</html>
'@

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch {
  Write-Log ('listen fail: ' + $_.Exception.Message)
  exit 1
}
Write-Log ("web started on http://127.0.0.1:$Port/")

function Send-Bytes($ctx, [byte[]]$bytes, [string]$type) {
  try {
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
  } catch { }
}

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
    $path = $ctx.Request.Url.AbsolutePath
    $q = [System.Web.HttpUtility]::ParseQueryString($ctx.Request.Url.Query)

    switch ($path) {
      '/' {
        Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
      }
      '/api/now' {
        $state = Get-NowState
        Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 4 -Compress))) 'application/json; charset=utf-8'
      }
      '/api/art' {
        $bytes = Get-ArtBytes
        if ($bytes) { Send-Bytes $ctx $bytes 'image/png' }
        else { Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes('')) 'image/png' }
      }
      '/api/stats' {
        $st = Get-Stats
        Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes(($st | ConvertTo-Json -Depth 6 -Compress))) 'application/json; charset=utf-8'
      }
      '/api/volume' {
        $set = $q['set']
        if ($null -ne $set -and $set -ne '') {
          try { [BrickyardAudio.Endpoint]::SetVolumePercent([int]$set) } catch { }
        }
        $pct = [BrickyardAudio.Endpoint]::GetVolumePercent()
        $muted = [BrickyardAudio.Endpoint]::GetMute()
        Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes((@{ percent = $pct; muted = $muted } | ConvertTo-Json -Compress))) 'application/json; charset=utf-8'
      }
      '/api/control' {
        $action = [string]$q['do']
        $s = Get-Session
        if ($s) {
          try {
            switch ($action) {
              'play' { [void](Await ($s.TryPlayAsync()) ([bool])) }
              'pause' { [void](Await ($s.TryPauseAsync()) ([bool])) }
              'next' { [void](Await ($s.TrySkipNextAsync()) ([bool])) }
              'prev' { [void](Await ($s.TrySkipPreviousAsync()) ([bool])) }
            }
          } catch { }
        }
        Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes('{"ok":true}')) 'application/json; charset=utf-8'
      }
      default {
        $ctx.Response.StatusCode = 404
        Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes('not found')) 'text/plain; charset=utf-8'
      }
    }
  } catch {
    Write-Log ('loop: ' + $_.Exception.Message)
  }
}
