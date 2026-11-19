using Application = System.Windows.Application;
using System;
using System.IO;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace MediaToast;

public sealed class MediaWatcher
{
    private readonly Action<TrackInfo> _onUpdate;
    private readonly Dictionary<string, byte[]> _artCache = new();
    private CancellationTokenSource _cts;
    private GlobalSystemMediaTransportControlsSessionManager _manager;
    private GlobalSystemMediaTransportControlsSession _session;
    private DateTime _lastManagerTry = DateTime.MinValue;

    public MediaWatcher(Action<TrackInfo> onUpdate)
    {
        _onUpdate = onUpdate;
    }

    public async System.Threading.Tasks.Task TogglePlayPauseAsync()
    {
        try
        {
            var s = _session ?? _manager?.GetCurrentSession();
            if (s != null) await s.TryTogglePlayPauseAsync();
        }
        catch (Exception ex) { Log.Write("toggle: " + ex.Message); }
    }

    public async System.Threading.Tasks.Task SkipNextAsync()
    {
        try
        {
            var s = _session ?? _manager?.GetCurrentSession();
            if (s != null) await s.TrySkipNextAsync();
        }
        catch (Exception ex) { Log.Write("next: " + ex.Message); }
    }

    public async System.Threading.Tasks.Task SkipPreviousAsync()
    {
        try
        {
            var s = _session ?? _manager?.GetCurrentSession();
            if (s != null) await s.TrySkipPreviousAsync();
        }
        catch (Exception ex) { Log.Write("prev: " + ex.Message); }
    }

    public void Start()
    {
        _cts = new CancellationTokenSource();
        _ = Task.Run(() => Loop(_cts.Token));
    }

    public void Stop()
    {
        try { _cts?.Cancel(); } catch { }
    }

    private async Task Loop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TrackInfo track = null;
            try
            {
                if (_manager == null && (DateTime.UtcNow - _lastManagerTry).TotalSeconds > 20)
                {
                    _lastManagerTry = DateTime.UtcNow;
                    _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
                    Log.Write("session manager ready");
                }

                if (_manager != null)
                {
                    track = await ReadTrackAsync();
                }
            }
            catch (Exception ex)
            {
                Log.Write("media read: " + ex.Message);
                _manager = null;
            }

            try
            {
                var app = Application.Current;
                if (app != null)
                {
                    await app.Dispatcher.InvokeAsync(() => _onUpdate(track));
                }
            }
            catch { }

            try { await Task.Delay(900, token); } catch { }
        }
    }

    private async Task<TrackInfo> ReadTrackAsync()
    {
        var session = _manager.GetCurrentSession();
        if (session == null) return null;

        _session = session;
        var props = await session.TryGetMediaPropertiesAsync();
        if (props == null) return null;

        var info = session.GetPlaybackInfo();
        var status = info != null ? info.PlaybackStatus.ToString() : "Closed";
        var playing = status == "Playing";

        var timeline = session.GetTimelineProperties();
        var total = timeline.EndTime - timeline.StartTime;
        var position = timeline.Position;
        double rate = 1.0;
        try
        {
            if (info != null)
            {
                var r = info.PlaybackRate;
                if (r.HasValue && r.Value > 0.01) rate = r.Value;
            }
        }
        catch { }

        if (playing && total > TimeSpan.Zero)
        {
            var elapsed = DateTimeOffset.Now - timeline.LastUpdatedTime;
            if (elapsed.TotalSeconds > 0 && elapsed.TotalSeconds < 30)
            {
                position += TimeSpan.FromSeconds(elapsed.TotalSeconds * rate);
            }
        }

        if (position < timeline.StartTime) position = timeline.StartTime;
        if (total > TimeSpan.Zero && position > timeline.EndTime) position = timeline.EndTime;

        var title = props.Title ?? "";
        var artist = props.Artist ?? "";
        var album = props.AlbumTitle ?? "";
        var key = (title + "|" + artist).ToLowerInvariant();

        var track = new TrackInfo
        {
            Title = title,
            Artist = artist,
            Album = album,
            Key = key,
            Status = status,
            Playing = playing,
            Rate = playing ? rate : 0.0,
            Position = position - timeline.StartTime,
            Duration = total > TimeSpan.Zero ? total : TimeSpan.Zero,
            PositionAt = DateTime.UtcNow
        };

        if (track.Position < TimeSpan.Zero) track.Position = TimeSpan.Zero;
        if (track.Duration > TimeSpan.Zero && track.Position > track.Duration) track.Position = track.Duration;

        if (_artCache.TryGetValue(key, out var cached) && cached != null)
        {
            track.ArtBytes = cached;
        }
        else if (props.Thumbnail != null)
        {
            try
            {
                using var stream = await props.Thumbnail.OpenReadAsync();
                var size = (uint)stream.Size;
                if (size > 0 && size < 12 * 1024 * 1024)
                {
                    var bytes = new byte[size];
                    using var reader = new DataReader(stream.GetInputStreamAt(0));
                    await reader.LoadAsync(size);
                    reader.ReadBytes(bytes);
                    reader.Dispose();
                    track.ArtBytes = bytes;
                    if (_artCache.Count > 12) _artCache.Clear();
                    _artCache[key] = bytes;
                }
                stream.Dispose();
            }
            catch (Exception ex)
            {
                Log.Write("art: " + ex.Message);
            }
        }

        return track;
    }
}
