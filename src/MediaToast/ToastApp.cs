using Application = System.Windows.Application;
using System;
using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace MediaToast;

public sealed class ToastApp
{
    private readonly Settings _settings;
    private readonly ToastWindow _toast;
    private readonly GlowManager _glow;
    private readonly MediaWatcher _media;
    private readonly Stats _stats = new();
    private readonly DispatcherTimer _progressTimer;
    private readonly DispatcherTimer _volumeTimer;
    private readonly WebServer _web;
    private readonly TrayApp _tray;

    private TrackInfo _lastTrack;
    private TrackInfo _lastGood;
    private DateTime _lastGoodAt = DateTime.MinValue;
    private string _lastKey = "";
    private string _lastStatus = "";
    private string _shownKey = "";
    private DateTime _shownAt = DateTime.MinValue;
    private string _tintKey = "";
    private string _decodedKey = "";
    private BitmapImage _decodedArt;

    private int _lastVolume = -1;
    private bool _lastMute;
    private string _lastVolKey = "";
    private DateTime _lastVolAt = DateTime.MinValue;
    private DateTime _lastBassCheck = DateTime.MinValue;

    public Settings Settings => _settings;
    public TrackInfo Current => _lastTrack ?? _lastGood;

    public ToastApp()
    {
        _settings = Settings.Load();
        _toast = new ToastWindow(_settings);
        _glow = new GlowManager(_settings);
        _media = new MediaWatcher(OnMedia);

        try
        {
            BrickyardBass.BassMeter.SetSource(_settings.GlowSource ?? "system");
            System.Threading.Thread.Sleep(350);
            Log.Write("bass meter: source=" + (_settings.GlowSource ?? "system") + " active=" + BrickyardBass.BassMeter.ActiveSource + " running=" + BrickyardBass.BassMeter.IsRunning + " error=" + BrickyardBass.BassMeter.LastError);
        }
        catch (Exception ex)
        {
            Log.Write("bass meter fail: " + ex.Message);
        }

        _progressTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _progressTimer.Tick += OnProgressTick;
        _volumeTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(260) };
        _volumeTimer.Tick += OnVolumeTick;

        _toast.SetVinyl(_settings.VinylOn);
        _toast.SetPinned(_settings.ToastPinned);
        _glow.SetEnabled(_settings.GlowOn);
        _web = new WebServer(this);
        _tray = new TrayApp(this);
        _media.Start();
        _progressTimer.Start();
        _volumeTimer.Start();

        Log.Write("started v3 card=" + _settings.CardWidth + " glow=" + _settings.GlowOn + " style=" + _settings.GlowStyle);
    }

    private void OnMedia(TrackInfo track)
    {
        try
        {
            if (track != null && !string.IsNullOrEmpty(track.Title))
            {
                _lastTrack = track;
                _lastGood = track;
                _lastGoodAt = DateTime.UtcNow;

                if (track.ArtBytes != null)
                {
                    track.Art = DecodeArt(track);
                    if (track.Art != null) _lastTrack.Art = track.Art;
                }
                else if (_decodedKey == track.Key)
                {
                    track.Art = _decodedArt;
                }

                bool playing = track.Playing;

                if (track.Key != _lastKey)
                {
                    _lastKey = track.Key;
                    if (_settings.ToastOn && ShouldShow(track))
                    {
                        if (!_toast.IsShown || _toast.VolumeMode) _toast.ShowTrack(track);
                        else _toast.RefreshTrack(track);
                    }
                }
                else if (playing && _lastStatus != "Playing" && _settings.ToastOn)
                {
                    if (_settings.ToastPinned || ShouldShow(track)) _toast.ShowTrack(track);
                }
                else if (!playing && track.Status == "Paused" && _lastStatus == "Playing" && _settings.ToastOn
                         && (track.Art != null || !string.IsNullOrEmpty(track.Artist) || track.Duration.TotalSeconds >= 20))
                {
                    _toast.ShowTrack(track, pause: true);
                }

                _lastStatus = track.Status;
                _toast.SetEqualizer(playing);
                _toast.SetPlayingForVinyl(playing);
                _glow.SetPlaying(playing);

                if (track.Art != null && _tintKey != track.Key)
                {
                    _tintKey = track.Key;
                    var color = ColorUtil.GetArtColor(track.Art);
                    _toast.SetAccent(color, track.Art, track.Key);
                    _glow.SetColor(color);
                }

                _stats.Track(track, playing);
            }
            else
            {
                _lastStatus = "";
                _glow.SetPlaying(false);
                _stats.Track(null, false);
            }
        }
        catch (Exception ex)
        {
            Log.Write("media tick: " + ex.Message);
        }
    }

    private BitmapImage DecodeArt(TrackInfo track)
    {
        if (_decodedKey == track.Key && _decodedArt != null) return _decodedArt;
        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.DecodePixelWidth = 600;
            bmp.StreamSource = new MemoryStream(track.ArtBytes);
            bmp.EndInit();
            bmp.Freeze();
            _decodedKey = track.Key;
            _decodedArt = bmp;
            return bmp;
        }
        catch (Exception ex)
        {
            Log.Write("art decode: " + ex.ToString());
            return null;
        }
    }

    private bool ShouldShow(TrackInfo track)
    {
        var key = (track.Title + "|" + track.Artist).ToLowerInvariant();
        var now = DateTime.UtcNow;
        if (key != _shownKey || (now - _shownAt).TotalMinutes > 10)
        {
            _shownKey = key;
            _shownAt = now;
            return true;
        }
        return false;
    }

    private void OnProgressTick(object sender, EventArgs e)
    {
        try
        {
            if ((DateTime.UtcNow - _lastBassCheck).TotalSeconds > 5)
            {
                _lastBassCheck = DateTime.UtcNow;
                if (!BrickyardBass.BassMeter.IsRunning)
                {
                    BrickyardBass.BassMeter.Start();
                }
            }

            if (_settings.ToastOn && _settings.ToastPinned && !_toast.IsShown && _lastTrack != null
                && !string.IsNullOrEmpty(_lastTrack.Title) && (_lastStatus == "Playing" || _lastStatus == "Paused"))
            {
                _toast.ShowTrack(_lastTrack, _lastStatus == "Paused");
            }

            if (_lastTrack != null && !_toast.VolumeMode && _toast.IsShown && _lastStatus == "Playing")
            {
                _toast.UpdateProgress(_lastTrack);
            }
        }
        catch { }
    }

    private void OnVolumeTick(object sender, EventArgs e)
    {
        try
        {
            int percent = Audio.VolumePercent;
            if (percent < 0) return;
            bool muted = Audio.Muted;
            bool changed = (_lastVolume >= 0 && percent != _lastVolume) || (muted != _lastMute);
            if (changed)
            {
                var key = "vol|" + percent + "|" + (muted ? 1 : 0);
                var now = DateTime.UtcNow;
                if (key != _lastVolKey || (now - _lastVolAt).TotalMilliseconds > 1200)
                {
                    _lastVolKey = key;
                    _lastVolAt = now;
                    _toast.ShowVolume(_lastTrack ?? _lastGood);
                }
            }
            _lastVolume = percent;
            _lastMute = muted;
        }
        catch { }
    }

    public async void TogglePlayPause()
    {
        try
        {
            var s = _media;
            await s.TogglePlayPauseAsync();
        }
        catch (Exception ex) { Log.Write("toggle: " + ex.Message); }
    }

    public async void SkipNext()
    {
        try { await _media.SkipNextAsync(); } catch { }
    }

    public async void SkipPrevious()
    {
        try { await _media.SkipPreviousAsync(); } catch { }
    }

    public void SetVolume(int percent)
    {
        try { Audio.SetVolume(percent); } catch { }
    }

    public void SetMuted(bool muted)
    {
        try { Audio.SetMuted(muted); } catch { }
    }

    public void ToggleGlow()
    {
        _settings.GlowOn = !_settings.GlowOn;
        _settings.Save();
        _glow.SetEnabled(_settings.GlowOn);
        if (_settings.GlowOn && _lastTrack?.Art != null)
        {
            _glow.SetColor(ColorUtil.GetArtColor(_lastTrack.Art));
        }
    }

    public bool ToastOn => _settings.ToastOn;

    public void ToggleToast()
    {
        if (!_settings.ToastOn)
        {
            _settings.ToastOn = true;
            _settings.ToastPinned = false;
        }
        else if (!_settings.ToastPinned)
        {
            _settings.ToastPinned = true;
        }
        else
        {
            _settings.ToastOn = false;
            _settings.ToastPinned = false;
        }
        _settings.Save();
        _toast.SetPinned(_settings.ToastPinned);
        if (!_settings.ToastOn)
        {
            _toast.HideNow();
        }
        else if (_lastTrack != null && !string.IsNullOrEmpty(_lastTrack.Title))
        {
            _toast.ShowTrack(_lastTrack, _lastStatus == "Paused");
        }
        Log.Write("toast " + (_settings.ToastOn ? (_settings.ToastPinned ? "pinned" : "auto") : "off"));
    }

    public void SetGlowPreset(string preset)
    {
        _settings.GlowPreset = preset;
        _settings.Save();
        _glow.ApplySettings(_settings);
    }

    public void SetGlowSource(string source)
    {
        _settings.GlowSource = string.IsNullOrWhiteSpace(source) ? "system" : source.Trim();
        _settings.Save();
        BrickyardBass.BassMeter.SetSource(_settings.GlowSource);
        Log.Write("glow source=" + _settings.GlowSource + " active=" + BrickyardBass.BassMeter.ActiveSource + " error=" + BrickyardBass.BassMeter.LastError);
    }

    public bool StartWebServer()
    {
        return _web.Start();
    }

    public void OpenWeb()
    {
        try
        {
            if (!_web.Start())
            {
                Log.Write("web failed to start");
                return;
            }
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("http://127.0.0.1:" + _web.Port + "/")
            {
                UseShellExecute = true
            });
        }
        catch (Exception ex)
        {
            Log.Write("open web: " + ex.Message);
        }
    }

    public void ToggleVinyl()
    {
        _settings.VinylOn = !_settings.VinylOn;
        _settings.Save();
        _toast.SetVinyl(_settings.VinylOn);
        _toast.SetPlayingForVinyl(_lastStatus == "Playing");
    }

    public void ApplySettings(Settings s)
    {
        s.Save();
        _toast.ApplySettings(s);
        _glow.ApplySettings(s);
        _glow.SetEnabled(s.GlowOn);
        _toast.SetVinyl(s.VinylOn);
        _toast.SetPinned(s.ToastPinned);
        _toast.SetPlayingForVinyl(_lastStatus == "Playing");
    }

    public void SetGlowStyle(string style)
    {
        _settings.GlowStyle = style;
        _settings.Save();
        _glow.ApplySettings(_settings);
    }

    public void SetCardTheme(string theme)
    {
        _settings.CardTheme = theme;
        _settings.Save();
        _toast.ApplySettings(_settings);
    }

    public void ShowTrayPanel()
    {
        _tray.ShowPanel();
    }

    public void ShowVolume()
    {
        _toast.ShowVolume(_lastTrack ?? _lastGood);
    }

    public void HideToast()
    {
        _toast.HideNow();
    }

    public void Shutdown()
    {
        try { _progressTimer.Stop(); _volumeTimer.Stop(); } catch { }
        try { _media.Stop(); } catch { }
        try { _tray.Dispose(); } catch { }
        try { _web.Dispose(); } catch { }
        try { _glow.Shutdown(); } catch { }
        try { _stats.Flush(); } catch { }
        try { _settings.Save(); } catch { }
        Log.Write("shutdown");
        Application.Current.Shutdown();
    }
}
