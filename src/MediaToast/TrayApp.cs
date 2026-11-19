using System;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using WinForms = System.Windows.Forms;
using Color = System.Windows.Media.Color;
using Point = System.Windows.Point;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using Application = System.Windows.Application;

namespace MediaToast;

public sealed class TrayApp
{
    private readonly ToastApp _app;
    private readonly Window _w;
    private readonly Border _card;
    private readonly Border _headerHit;
    private readonly Border _coverArt;
    private readonly TextBlock _coverGlyph;
    private readonly TextBlock _titleText;
    private readonly TextBlock _artistText;
    private readonly TextBlock _albumText;
    private readonly Border _fill;
    private readonly TextBlock _timeText;
    private readonly Border _prevBtn;
    private readonly Border _playBtn;
    private readonly Border _nextBtn;
    private readonly TextBlock _playGlyph;
    private readonly Slider _volumeSlider;
    private readonly TextBlock _volText;
    private readonly TextBlock _volGlyph;
    private readonly ScaleTransform _prevScale;
    private readonly ScaleTransform _playScale;
    private readonly ScaleTransform _nextScale;
    private readonly TranslateTransform _panelShift;

    private readonly Border _pillToast;
    private readonly Border _pillAuto;
    private readonly Border _pillGlow;
    private readonly Border _pillStats;
    private readonly Border _pillWeb;
    private readonly Border _pillVinyl;
    private readonly Border _pillPreset;
    private readonly Border _pillTheme;
    private readonly Border _pillStyle;
    private readonly Border _pillSource;
    private readonly TextBlock _toastState;
    private readonly TextBlock _autoState;
    private readonly TextBlock _glowState;
    private readonly TextBlock _vinylState;
    private readonly TextBlock _presetState;
    private readonly TextBlock _themeState;
    private readonly TextBlock _styleState;
    private readonly TextBlock _sourceState;
    private readonly Border _toastDot;
    private readonly Border _autoDot;
    private readonly Border _glowDot;
    private readonly Border _vinylDot;

    private readonly WinForms.NotifyIcon _notify;
    private readonly DispatcherTimer _timer;
    private bool _syncing;
    private DateTime _lastHide = DateTime.MinValue;
    private DateTime _lastPresetClick = DateTime.MinValue;

    private static readonly CubicEase EaseOut = new() { EasingMode = EasingMode.EaseOut };
    private static readonly CubicEase EaseIn = new() { EasingMode = EasingMode.EaseIn };

    private static string PresetName(string preset) => preset switch
    {
        "neon-calm" => "неон — спокойный",
        "neon-hard" => "неон — агрессивный",
        _ => "неон — универсальный"
    };

    private static string ThemeName(string theme) => theme switch
    {
        "minimal" => "минимал",
        "glass" => "стекло",
        _ => "неон"
    };

    private static string StyleName(string style) => style == "strips" ? "полосы" : "сектора";

    public TrayApp(ToastApp app)
    {
        _app = app;

        _w = (Window)XamlReader.Parse(Assets.Load("tray.xaml"));
        _card = Find<Border>("Card");
        _headerHit = Find<Border>("HeaderHit");
        _coverArt = Find<Border>("CoverArt");
        _coverGlyph = Find<TextBlock>("CoverGlyph");
        _titleText = Find<TextBlock>("TitleText");
        _artistText = Find<TextBlock>("ArtistText");
        _albumText = Find<TextBlock>("AlbumText");
        _fill = Find<Border>("Fill");
        _timeText = Find<TextBlock>("TimeText");
        _prevBtn = Find<Border>("PrevBtn");
        _playBtn = Find<Border>("PlayBtn");
        _nextBtn = Find<Border>("NextBtn");
        _playGlyph = Find<TextBlock>("PlayGlyph");
        _volumeSlider = Find<Slider>("VolumeSlider");
        _volText = Find<TextBlock>("VolText");
        _volGlyph = Find<TextBlock>("VolGlyph");
        _prevScale = Find<ScaleTransform>("PrevScale");
        _playScale = Find<ScaleTransform>("PlayScale");
        _nextScale = Find<ScaleTransform>("NextScale");
        _panelShift = Find<TranslateTransform>("PanelShift");

        _pillToast = Find<Border>("PillToast");
        _pillAuto = Find<Border>("PillAuto");
        _pillGlow = Find<Border>("PillGlow");
        _pillStats = Find<Border>("PillStats");
        _pillWeb = Find<Border>("PillWeb");
        _pillVinyl = Find<Border>("PillVinyl");
        _pillPreset = Find<Border>("PillPreset");
        _pillTheme = Find<Border>("PillTheme");
        _pillStyle = Find<Border>("PillStyle");
        _toastState = Find<TextBlock>("ToastState");
        _autoState = Find<TextBlock>("AutoState");
        _glowState = Find<TextBlock>("GlowState");
        _vinylState = Find<TextBlock>("VinylState");
        _presetState = Find<TextBlock>("PresetState");
        _pillSource = Find<Border>("PillSource");
        _sourceState = Find<TextBlock>("SourceState");
        _themeState = Find<TextBlock>("ThemeState");
        _styleState = Find<TextBlock>("StyleState");
        _toastDot = Find<Border>("ToastDot");
        _autoDot = Find<Border>("AutoDot");
        _glowDot = Find<Border>("GlowDot");
        _vinylDot = Find<Border>("VinylDot");

        _w.Deactivated += (_, _) => HidePanel();
        _w.Show();
        _w.Visibility = Visibility.Hidden;
        _w.Opacity = 0;

        _headerHit.MouseLeftButtonUp += (_, _) => CopyTrack();
        _prevBtn.MouseLeftButtonUp += (_, _) => _app.SkipPrevious();
        _nextBtn.MouseLeftButtonUp += (_, _) => _app.SkipNext();
        _playBtn.MouseLeftButtonUp += (_, _) => { _app.TogglePlayPause(); Refresh(); };
        _volumeSlider.ValueChanged += OnVolumeChanged;

        _pillToast.MouseLeftButtonUp += (_, _) => { _app.ToggleToast(); Refresh(); };
        _pillAuto.MouseLeftButtonUp += (_, _) => { Autostart.Set(!Autostart.Enabled); Refresh(); };
        _pillGlow.MouseLeftButtonUp += (_, _) => { _app.ToggleGlow(); Refresh(); };
        _pillStats.MouseLeftButtonUp += (_, _) => { _app.OpenWeb(); HidePanel(); };
        _pillWeb.MouseLeftButtonUp += (_, _) => { _app.OpenWeb(); HidePanel(); };
        _pillVinyl.MouseLeftButtonUp += (_, _) => { _app.ToggleVinyl(); Refresh(); };
        _pillPreset.MouseLeftButtonUp += (_, _) =>
        {
            if ((DateTime.UtcNow - _lastPresetClick).TotalMilliseconds < 250) return;
            _lastPresetClick = DateTime.UtcNow;
            var order = new[] { "neon-calm", "neon-hard", "neon-universal" };
            var i = Array.IndexOf(order, _app.Settings.GlowPreset);
            _app.SetGlowPreset(order[(i + 1 + order.Length) % order.Length]);
            Refresh();
        };
        _pillSource.MouseLeftButtonUp += (_, _) =>
        {
            var sources = BrickyardBass.BassMeter.GetAvailableSources();
            var current = _app.Settings.GlowSource ?? "system";
            var i = sources.IndexOf(current);
            var next = sources[(i + 1 + sources.Count) % sources.Count];
            _app.SetGlowSource(next);
            Refresh();
        };
        _pillTheme.MouseLeftButtonUp += (_, _) =>
        {
            var order = new[] { "neon", "minimal", "glass" };
            var i = Array.IndexOf(order, _app.Settings.CardTheme);
            _app.SetCardTheme(order[(i + 1 + order.Length) % order.Length]);
            Refresh();
        };
        _pillStyle.MouseLeftButtonUp += (_, _) =>
        {
            var order = new[] { "sectors", "strips" };
            var i = Array.IndexOf(order, _app.Settings.GlowStyle);
            _app.SetGlowStyle(order[(i + 1 + order.Length) % order.Length]);
            Refresh();
        };

        AddHoverScale(_prevBtn, _prevScale);
        AddHoverScale(_playBtn, _playScale);
        AddHoverScale(_nextBtn, _nextScale);
        AddHoverTint(_prevBtn, Color.FromRgb(30, 26, 42), Color.FromRgb(42, 35, 64));
        AddHoverTint(_nextBtn, Color.FromRgb(30, 26, 42), Color.FromRgb(42, 35, 64));
        AddHoverTint(_playBtn, Color.FromRgb(35, 30, 49), Color.FromRgb(49, 40, 74));
        foreach (var pill in new[] { _pillToast, _pillAuto, _pillGlow, _pillStats, _pillWeb, _pillVinyl, _pillPreset, _pillSource, _pillTheme, _pillStyle })
        {
            AddHoverTint(pill, Color.FromRgb(23, 19, 34), Color.FromRgb(34, 28, 51));
        }

        _notify = new WinForms.NotifyIcon();
        try
        {
            var asm = typeof(TrayApp).Assembly;
            using var stream = asm.GetManifestResourceStream("MediaToast.Assets.App.ico");
            if (stream != null) _notify.Icon = new System.Drawing.Icon(stream);
            else _notify.Icon = System.Drawing.SystemIcons.Application;
        }
        catch
        {
            _notify.Icon = System.Drawing.SystemIcons.Application;
        }
        _notify.Text = "MediaToast — управление музыкой";
        _notify.Visible = true;
        _notify.MouseClick += (_, e) =>
        {
            if (e.Button != WinForms.MouseButtons.Left) return;
            if (_w.Visibility == Visibility.Visible) HidePanel();
            else ShowPanel();
        };

        var menu = new WinForms.ContextMenuStrip();
        var miOpen = menu.Items.Add("Открыть панель");
        miOpen.Click += (_, _) => ShowPanel();
        var miToast = menu.Items.Add("Плашка вкл/выкл");
        miToast.Click += (_, _) => { _app.ToggleToast(); Refresh(); };
        var miGlow = menu.Items.Add("Подсветка краёв вкл/выкл");
        miGlow.Click += (_, _) => { _app.ToggleGlow(); Refresh(); };
        var miWeb = menu.Items.Add("Веб-панель и статистика");
        miWeb.Click += (_, _) => _app.OpenWeb();
        menu.Items.Add(new WinForms.ToolStripSeparator());
        var miExit = menu.Items.Add("Выход");
        miExit.Click += (_, _) => _app.Shutdown();
        _notify.ContextMenuStrip = menu;

        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _timer.Tick += (_, _) => { if (_w.Visibility == Visibility.Visible) Refresh(); };
        _timer.Start();
    }

    private T Find<T>(string name) where T : class
    {
        var value = _w.FindName(name) as T;
        if (value == null) throw new InvalidOperationException("tray element not found: " + name);
        return value;
    }

    private void OnVolumeChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_syncing) return;
        int value = (int)Math.Round(e.NewValue);
        _volText.Text = value.ToString();
        _app.SetVolume(value);
    }

    private void CopyTrack()
    {
        var track = _app.Current;
        if (track == null || string.IsNullOrEmpty(track.Title)) return;
        try
        {
            var text = string.IsNullOrEmpty(track.Artist) ? track.Title : track.Artist + " — " + track.Title;
            System.Windows.Clipboard.SetText(text);
        }
        catch { }
    }

    private void Refresh()
    {
        var track = _app.Current;
        if (track == null || string.IsNullOrEmpty(track.Title))
        {
            _titleText.Text = "Ничего не играет";
            _artistText.Text = "";
            _albumText.Text = "";
            _timeText.Text = "—:—";
            _fill.Width = 0;
            _playGlyph.Text = "▶";
            SetCover(null);
        }
        else
        {
            _titleText.Text = track.Title;
            _artistText.Text = string.IsNullOrEmpty(track.Artist) ? "Неизвестный исполнитель" : track.Artist;
            _albumText.Text = string.IsNullOrEmpty(track.Album) ? "Сингл" : track.Album;
            _playGlyph.Text = track.Playing ? "II" : "▶";

            if (track.Duration > TimeSpan.Zero)
            {
                var pos = track.PositionNow();
                double ratio = Math.Max(0, Math.Min(1, pos.TotalSeconds / track.Duration.TotalSeconds));
                _fill.Width = Math.Max(0, Math.Min(320, 320 * ratio));
                _timeText.Text = ToastWindow.FormatTime(pos) + " / " + ToastWindow.FormatTime(track.Duration);
            }
            else
            {
                _timeText.Text = "—:—";
                _fill.Width = 0;
            }

            if (track.Art != null) SetCover(track.Art);
            else SetCover(null);

            try
            {
                var txt = "♪ " + track.Title;
                if (txt.Length > 60) txt = txt.Substring(0, 60);
                _notify.Text = txt;
            }
            catch { }
        }

        SyncVolume();
        UpdatePills();
    }

    private void SetCover(BitmapImage art)
    {
        if (art != null)
        {
            _coverArt.Background = new ImageBrush(art) { Stretch = Stretch.UniformToFill };
            _coverArt.Opacity = 1;
            _coverGlyph.Visibility = Visibility.Collapsed;
        }
        else
        {
            _coverArt.Opacity = 0;
            _coverGlyph.Visibility = Visibility.Visible;
        }
    }

    private void SyncVolume()
    {
        try
        {
            int v = Audio.VolumePercent;
            if (v >= 0)
            {
                _syncing = true;
                _volumeSlider.Value = v;
                _volText.Text = v.ToString();
                _syncing = false;
            }
            _volGlyph.Text = Audio.Muted ? "🔇" : "🔊";
        }
        catch { }
    }

    private void UpdatePills()
    {
        var s = _app.Settings;

        SetState(_toastState, _toastDot, s.ToastOn, s.ToastOn ? "вкл" : "выкл");
        SetState(_autoState, _autoDot, Autostart.Enabled, Autostart.Enabled ? "вкл" : "выкл");
        SetState(_glowState, _glowDot, s.GlowOn, s.GlowOn ? "вкл — в цвет обложки" : "выкл");
        SetState(_vinylState, _vinylDot, s.VinylOn, s.VinylOn ? "вкл — круг крутится" : "выкл");
        _presetState.Text = PresetName(s.GlowPreset);
        _sourceState.Text = SourceLabel(s.GlowSource);
        _themeState.Text = ThemeName(s.CardTheme);
        _styleState.Text = StyleName(s.GlowStyle);
    }

    private static string SourceLabel(string source)
    {
        if (string.IsNullOrEmpty(source) || source == "system") return "система";
        var active = BrickyardBass.BassMeter.ActiveSource;
        var name = SourceDisplayName(source);
        if (active == source) return name;
        if (active == "system") return name + " → система";
        return name + " (нет)";
    }

    private static string SourceDisplayName(string source)
    {
        switch ((source ?? "").ToLowerInvariant())
        {
            case "firefox": return "Firefox (браузер)";
            case "chrome": return "Chrome (браузер)";
            case "msedge": return "Edge (браузер)";
            case "brave": return "Brave (браузер)";
            case "opera": return "Opera (браузер)";
            case "vivaldi": return "Vivaldi (браузер)";
            case "youtube": return "YouTube";
            case "browser": return "Браузер";
            default: return source;
        }
    }

    private static void SetState(TextBlock text, Border dot, bool on, string label)
    {
        text.Text = label;
        var color = on ? Color.FromRgb(89, 242, 143) : Color.FromRgb(135, 122, 154);
        text.Foreground = new SolidColorBrush(color);
        dot.Background = new SolidColorBrush(on ? color : Color.FromRgb(58, 49, 72));
    }

    public void ShowPanel()
    {
        if (DateTime.UtcNow - _lastHide < TimeSpan.FromMilliseconds(220)) return;
        Refresh();
        _w.Visibility = Visibility.Visible;
        _w.Opacity = 0;
        _w.UpdateLayout();
        var area = SystemParameters.WorkArea;
        _w.Left = area.Right - _w.ActualWidth - 14;
        _w.Top = area.Bottom - _w.ActualHeight - 14;
        if (_w.Top < area.Top) _w.Top = area.Top + 14;

        var fade = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(170)) { EasingFunction = EaseOut };
        _w.BeginAnimation(Window.OpacityProperty, fade);
        var slide = new DoubleAnimation(18, 0, TimeSpan.FromMilliseconds(200)) { EasingFunction = EaseOut };
        _panelShift.BeginAnimation(TranslateTransform.YProperty, slide);
    }

    private void HidePanel()
    {
        if (_w.Visibility != Visibility.Visible) return;
        _lastHide = DateTime.UtcNow;
        var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(130)) { EasingFunction = EaseIn };
        fade.Completed += (_, _) => { try { _w.Visibility = Visibility.Hidden; } catch { } };
        _w.BeginAnimation(Window.OpacityProperty, fade);
        var slide = new DoubleAnimation(0, 12, TimeSpan.FromMilliseconds(130)) { EasingFunction = EaseIn };
        _panelShift.BeginAnimation(TranslateTransform.YProperty, slide);
    }

    private void AddHoverScale(FrameworkElement element, ScaleTransform scale)
    {
        element.MouseEnter += (_, _) =>
        {
            var a = new DoubleAnimation(1, 1.06, TimeSpan.FromMilliseconds(120)) { EasingFunction = EaseOut };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        };
        element.MouseLeave += (_, _) =>
        {
            var a = new DoubleAnimation(1.06, 1, TimeSpan.FromMilliseconds(120)) { EasingFunction = EaseOut };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        };
    }

    private static void AddHoverTint(Border element, Color from, Color to)
    {
        var normal = new SolidColorBrush(from);
        var hover = new SolidColorBrush(to);
        element.MouseEnter += (_, _) => element.Background = hover;
        element.MouseLeave += (_, _) => element.Background = normal;
    }

    public void Dispose()
    {
        try { _timer.Stop(); } catch { }
        try { _notify.Visible = false; _notify.Dispose(); } catch { }
        try { _w.Close(); } catch { }
    }
}

public static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "MediaToast";

    private static string ExePath
    {
        get
        {
            try
            {
                return Environment.ProcessPath ?? System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName;
            }
            catch
            {
                return "";
            }
        }
    }

    public static bool Enabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(ValueName) != null;
            }
            catch { return false; }
        }
    }

    public static void Set(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, true);
            if (key == null) return;
            if (on) key.SetValue(ValueName, "\"" + ExePath + "\"");
            else key.DeleteValue(ValueName, false);
        }
        catch (Exception ex)
        {
            Log.Write("autostart: " + ex.Message);
        }
    }
}
