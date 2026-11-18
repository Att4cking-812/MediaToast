# Как это устроено

Коротко о внутренностях и о граблях, на которые я наступил.

## Поток данных

```
GSMTC (Windows.Media.Control)  ->  трек, исполнитель, альбом, обложка
IAudioEndpointVolume (CoreAudio) ->  мастер-громкость и mute
```

Оба источника опрашиваются таймерами `DispatcherTimer` на UI-потоке:

| Таймер | Интервал | Зачем |
|---|---|---|
| media | 950 мс | смена трека, статус, обложка |
| volume | 260 мс | громкость и mute |
| progress | 250 мс | плавная полоска времени |
| reconnect | 45 с | переподключение к менеджеру сессий |
| hold | по событию | через сколько спрятать карточку |
| hide | 210 мс | завершение анимации ухода |

## WinRT из PowerShell 5.1

`IAsyncOperation` нельзя просто так дождаться: у объекта `__ComObject` нет `.Status`, а `System.WindowsRuntimeSystemExtensions` не загружен по умолчанию.

```powershell
[void][System.Reflection.Assembly]::Load('System.Runtime.WindowsRuntime, Version=4.0.0.0, ...')
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
```

Обложка: `RandomAccessStreamReference.OpenReadAsync()` возвращает COM-объект, у которого нет `Dispose()`, а `AsStreamForRead($stream)` не биндится. Рабочий вариант — взять метод через рефлексию:

```powershell
$asStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod(
  'AsStreamForRead', [Type[]]@([Windows.Storage.Streams.IInputStream, ...]))
$net = $asStreamForRead.Invoke($null, @($stream))
```

## Позиция трека

SMTC отдаёт `Position` только в моменты паузы/перемотки. Если показывать как есть — время вечно стоит на `0:00`.

Поэтому:

```powershell
$position = $timeline.Position
if (playing) {
  $delta = [DateTimeOffset]::UtcNow - $timeline.LastUpdatedTime
  $position = $position.Add([TimeSpan]::FromSeconds($delta.TotalSeconds * $playbackRate))
}
```

## Анимации

WPF `DoubleAnimation` + `CubicEase`:

- появление: `Opacity 0→1`, `TranslateTransform.X -26→0`, `ScaleTransform 0.93→1`, 260 мс;
- уход: обратно, 200 мс;
- обложка: отдельный фейд 320 мс и зум `1.08→1` за 420 мс;
- полоски: анимация `Width` (140 мс громкость, 260 мс прогресс).

Анимация появления запускается **только** при переходе из скрытого состояния, иначе при быстрых шагах громкости карточка мигает.

## Один экземпляр

```powershell
$mutex = New-Object System.Threading.Mutex($false, 'Local\BrickyardMediaToast')
if (-not $mutex.WaitOne(0)) { exit 0 }
```

Плюс `toast.pid`, чтобы установщик и скрипт остановки знали, кого гасить.

## Ограничения

- PowerShell + WPF дают ~170–200 МБ рабочей памяти. Для C#-варианта хватило бы 15–20 МБ, но пришлось бы тащить `Windows.winmd` и компилятор.
