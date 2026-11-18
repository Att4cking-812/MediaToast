# MusicStats — собирает статистику прослушивания из listening.tsv
# и рисует страницу stats.html рядом со скриптом.
# Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File MusicStats.ps1

param(
  [switch]$NoOpen
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = $PSScriptRoot
$src = Join-Path $root 'listening.tsv'
$out = Join-Path $root 'stats.html'

function Format-Duration([double]$seconds) {
  $s = [int][Math]::Round($seconds)
  if ($s -lt 60) { return ($s.ToString() + ' с') }
  $h = [int][Math]::Floor($s / 3600)
  $m = [int][Math]::Floor(($s % 3600) / 60)
  if ($h -gt 0) { return ($h.ToString() + ' ч ' + $m.ToString() + ' мин') }
  return ($m.ToString() + ' мин')
}

$rows = @()
if (Test-Path -LiteralPath $src) {
  try {
    foreach ($line in Get-Content -LiteralPath $src -Encoding UTF8) {
      if (-not $line.Trim()) { continue }
      $parts = $line.Split("`t")
      if ($parts.Count -lt 4) { continue }
      $ts = [datetime]::MinValue
      try { $ts = [datetime]::ParseExact($parts[0], 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
      $secs = 0
      [void][int]::TryParse($parts[1], [ref]$secs)
      if ($secs -le 0) { continue }
      $rows += [pscustomobject]@{ Ts = $ts; Secs = [double]$secs; Artist = $parts[2]; Title = $parts[3] }
    }
  } catch { }
}

$today = (Get-Date).Date
$weekAgo = $today.AddDays(-6)
$totalSecs = 0.0
$todaySecs = 0.0
$weekSecs = 0.0
$artists = @{}
$tracks = @{}
$days = @{}

foreach ($r in $rows) {
  $totalSecs += $r.Secs
  if ($r.Ts.Date -eq $today) { $todaySecs += $r.Secs }
  if ($r.Ts.Date -ge $weekAgo) { $weekSecs += $r.Secs }

  $a = if ($r.Artist) { $r.Artist } else { 'Неизвестный исполнитель' }
  if (-not $artists.ContainsKey($a)) { $artists[$a] = 0.0 }
  $artists[$a] += $r.Secs

  $t = $a + ' — ' + $r.Title
  if (-not $tracks.ContainsKey($t)) { $tracks[$t] = 0.0 }
  $tracks[$t] += $r.Secs

  $d = $r.Ts.ToString('yyyy-MM-dd')
  if (-not $days.ContainsKey($d)) { $days[$d] = 0.0 }
  $days[$d] += $r.Secs
}

$topArtists = $artists.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6
$topTracks = $tracks.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 12

# график за 14 дней
$chart = @()
$maxDay = 1.0
for ($i = 13; $i -ge 0; $i--) {
  $d = $today.AddDays(-$i)
  $key = $d.ToString('yyyy-MM-dd')
  $val = if ($days.ContainsKey($key)) { $days[$key] } else { 0.0 }
  if ($val -gt $maxDay) { $maxDay = $val }
  $chart += [pscustomobject]@{ Date = $d; Value = $val }
}

function HtmlEnc([string]$s) {
  if ($null -eq $s) { return '' }
  return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

$bars = ''
$barIndex = 0
foreach ($c in $chart) {
  $h = if ($maxDay -gt 0) { [int][Math]::Round(($c.Value / $maxDay) * 132) } else { 0 }
  if ($c.Value -gt 0 -and $h -lt 4) { $h = 4 }
  $label = $c.Date.ToString('dd.MM')
  $tip = $label + ': ' + (Format-Duration $c.Value)
  $delay = ($barIndex * 0.035)
  $bars += ('<div class="bar-wrap" title="' + $tip + '"><div class="bar" style="height:' + $h + 'px;animation-delay:' + $delay.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + 's"></div><span>' + $c.Date.ToString('dd') + '</span></div>')
  $barIndex++
}

$artistRows = ''
if ($topArtists) {
  foreach ($a in $topArtists) {
    $artistRows += ('<div class="row"><span class="row-name">' + (HtmlEnc $a.Key) + '</span><b>' + (Format-Duration $a.Value) + '</b></div>')
  }
} else {
  $artistRows = '<div class="empty">Пока нет данных — послушай музыку, и тут появятся цифры.</div>'
}

$trackRows = ''
if ($topTracks) {
  foreach ($t in $topTracks) {
    $trackRows += ('<div class="row"><span class="row-name">' + (HtmlEnc $t.Key) + '</span><b>' + (Format-Duration $t.Value) + '</b></div>')
  }
} else {
  $trackRows = '<div class="empty">Пусто.</div>'
}

$html = @"
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Музыка — статистика</title>
<style>
  :root{--bg:#0e0c14;--panel:#171321;--line:#2b2339;--text:#efe9f8;--muted:#9c8fae;--green:#59f28f;--cyan:#6fd8ff;--pink:#ff6b9d;--gold:#f0c060}
  *{box-sizing:border-box}
  body{margin:0;background:radial-gradient(900px 520px at 8% -8%,rgba(255,107,157,.12),transparent 60%),radial-gradient(820px 520px at 92% 0%,rgba(111,216,255,.10),transparent 55%),var(--bg);color:var(--text);font-family:"Segoe UI",system-ui,sans-serif}
  .wrap{max-width:1000px;margin:0 auto;padding:34px 20px 70px}
  header{border:1px solid var(--line);border-radius:20px;padding:20px 24px;background:linear-gradient(150deg,rgba(30,24,40,.95),rgba(15,13,20,.96));box-shadow:0 22px 60px rgba(0,0,0,.45)}
  h1{margin:0;font-size:26px;letter-spacing:-.4px}
  .sub{color:var(--muted);font-size:13px;margin-top:5px}
  .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-top:18px}
  .card{background:linear-gradient(160deg,rgba(23,19,33,.96),rgba(15,13,20,.97));border:1px solid var(--line);border-radius:16px;padding:16px 18px}
  .card .k{font-size:10px;letter-spacing:1.4px;text-transform:uppercase;color:var(--muted)}
  .card .v{font-size:26px;font-weight:800;margin-top:6px}
  .card .v.cyan{color:var(--cyan)} .card .v.green{color:var(--green)} .card .v.gold{color:var(--gold)}
  .grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-top:16px}
  h2{font-size:12px;letter-spacing:1.4px;text-transform:uppercase;color:var(--gold);margin:0 0 12px}
  .chart{display:flex;align-items:flex-end;gap:8px;height:170px;padding-top:8px}
  .bar-wrap{flex:1;display:flex;flex-direction:column;justify-content:flex-end;align-items:center;gap:6px}
  .bar{width:100%;border-radius:6px 6px 2px 2px;background:linear-gradient(180deg,var(--cyan),rgba(111,216,255,.15));box-shadow:0 0 14px rgba(111,216,255,.25);transform-origin:bottom;animation:grow .75s cubic-bezier(.2,.7,.3,1) both}
  @keyframes grow{from{transform:scaleY(.03);opacity:.4}to{transform:scaleY(1);opacity:1}}
  @keyframes fadeUp{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
  header,.card{animation:fadeUp .55s ease both}
  .cards .card:nth-child(2){animation-delay:.08s}
  .cards .card:nth-child(3){animation-delay:.16s}
  .bar-wrap span{font-size:10px;color:#6f6382}
  .row{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px dashed var(--line);font-size:14px}
  .row:last-child{border-bottom:0}
  .row-name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .row b{color:#cfc3dd;font-weight:700;white-space:nowrap}
  .empty{color:var(--muted);font-size:13px}
  footer{margin-top:22px;color:var(--muted);font-size:12px;border-top:1px solid var(--line);padding-top:14px}
  @media(max-width:760px){.cards{grid-template-columns:1fr}.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Статистика прослушивания</h1>
    <div class="sub">Локальные данные: собираются, пока работает плашка. Ничего никуда не уходит.</div>
    <div class="cards">
      <div class="card"><div class="k">Сегодня</div><div class="v cyan">$(Format-Duration $todaySecs)</div></div>
      <div class="card"><div class="k">Последние 7 дней</div><div class="v green">$(Format-Duration $weekSecs)</div></div>
      <div class="card"><div class="k">Всего</div><div class="v gold">$(Format-Duration $totalSecs)</div></div>
    </div>
  </header>

  <div class="card" style="margin-top:16px">
    <h2>По дням (14 дней)</h2>
    <div class="chart">$bars</div>
  </div>

  <div class="grid">
    <div class="card">
      <h2>Топ исполнителей</h2>
      $artistRows
    </div>
    <div class="card">
      <h2>Топ треков</h2>
      $trackRows
    </div>
  </div>

  <footer>Обновлено: $(Get-Date -Format 'dd.MM.yyyy HH:mm') · записей: $($rows.Count) · файл: listening.tsv</footer>
</div>
</body>
</html>
"@

[IO.File]::WriteAllText($out, $html, (New-Object Text.UTF8Encoding($false)))
Write-Output ('stats written: ' + $out + ' (' + $html.Length + ' chars, ' + $rows.Count + ' rows)')

if (-not $NoOpen) { Start-Process $out }
