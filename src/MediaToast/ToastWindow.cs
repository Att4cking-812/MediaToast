using Color = System.Windows.Media.Color;
using Point = System.Windows.Point;
using Size = System.Windows.Size;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using Path = System.Windows.Shapes.Path;
using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Markup;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace MediaToast;

public sealed class ToastWindow
{
    private readonly Window _w;
    private readonly Border _card;
    private readonly Border _cardBackdrop;
    private readonly Border _coverArt;
    private readonly Border _coverBorder;
    private readonly Border _progressFill;
    private readonly Border _volumeFill;
    private readonly Grid _progressRow;
    private readonly Grid _volumeRow;
    private readonly Grid _coverWrap;
    private readonly Grid _textCol;
    private readonly TextBlock _titleText;
    private readonly TextBlock _artistText;
    private readonly TextBlock _albumText;
    private readonly TextBlock _progressText;
    private readonly TextBlock _volumeText;
    private readonly TextBlock _coverGlyph;
    private readonly Ellipse _ringTrack;
    private readonly Path _ring;
    private readonly StackPanel _eq;
    private readonly Border[] _eqBars;
    private readonly LinearGradientBrush _cardBorderBrush;
    private readonly RotateTransform _borderSpin;
    private readonly RotateTransform _artRotate;
    private readonly ScaleTransform _cardScale;
    private readonly ScaleTransform _artScale;
    private readonly TranslateTransform _cardSlide;
    private readonly TranslateTransform _artSlide;
    private readonly TranslateTransform _titleT;
    private readonly TranslateTransform _artistT;
    private readonly TranslateTransform _albumT;

    private readonly DispatcherTimer _holdTimer;
    private readonly DispatcherTimer _hideTimer;
    private Settings _settings;
    private bool _volumeMode;
    private bool _pauseMode;
    private bool _hiding;
    private bool _eqPlaying;
    private bool _vinyl;
    private bool _vinylSpinning;
    private Color _accent = Color.FromRgb(111, 216, 255);
    private string _artKey = "";

    private static readonly CubicEase EaseOut = new() { EasingMode = EasingMode.EaseOut };
    private static readonly CubicEase EaseIn = new() { EasingMode = EasingMode.EaseIn };

    public bool IsShown => _w.Visibility == Visibility.Visible;
    public bool VolumeMode => _volumeMode;

    public ToastWindow(Settings settings)
    {
        _settings = settings;
        var xaml = Assets.Load("toast.xaml");
        _w = (Window)XamlReader.Parse(xaml);

        _card = Find<Border>("Card");
        _cardBackdrop = Find<Border>("CardBackdrop");
        _coverArt = Find<Border>("CoverArt");
        _coverBorder = Find<Border>("CoverBorder");
        _progressFill = Find<Border>("ProgressFill");
        _volumeFill = Find<Border>("VolumeFill");
        _progressRow = Find<Grid>("ProgressRow");
        _volumeRow = Find<Grid>("VolumeRow");
        _coverWrap = Find<Grid>("CoverWrap");
        _textCol = Find<Grid>("TextCol");
        _titleText = Find<TextBlock>("TitleText");
        _artistText = Find<TextBlock>("ArtistText");
        _albumText = Find<TextBlock>("AlbumText");
        _progressText = Find<TextBlock>("ProgressText");
        _volumeText = Find<TextBlock>("VolumeText");
        _coverGlyph = Find<TextBlock>("CoverGlyph");
        _ringTrack = Find<Ellipse>("RingTrack");
        _ring = Find<Path>("Ring");
        _eq = Find<StackPanel>("Eq");
        _eqBars = new[] { Find<Border>("Eq1"), Find<Border>("Eq2"), Find<Border>("Eq3") };
        _cardBorderBrush = Find<LinearGradientBrush>("CardBorderBrush");
        _borderSpin = Find<RotateTransform>("BorderSpin");
        _artRotate = Find<RotateTransform>("ArtRotate");
        _cardScale = Find<ScaleTransform>("CardScale");
        _artScale = Find<ScaleTransform>("ArtScale");
        _cardSlide = Find<TranslateTransform>("CardSlide");
        _artSlide = Find<TranslateTransform>("ArtSlide");
        _titleT = Find<TranslateTransform>("TitleT");
        _artistT = Find<TranslateTransform>("ArtistT");
        _albumT = Find<TranslateTransform>("AlbumT");

        ApplyCardWidth();

        _holdTimer = new DispatcherTimer();
        _holdTimer.Tick += OnHoldElapsed;
        _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(210) };
        _hideTimer.Tick += OnHideElapsed;

        _w.SourceInitialized += (_, _) => WindowUtil.MakeClickThrough(_w);
        _w.Show();
        _w.Visibility = Visibility.Hidden;
        _w.Opacity = 0;

        var spin = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(7))
        {
            RepeatBehavior = RepeatBehavior.Forever
        };
        _borderSpin.BeginAnimation(RotateTransform.AngleProperty, spin);

        var blur = new BlurEffect { Radius = 18, KernelType = KernelType.Gaussian };
        _cardBackdrop.Effect = blur;
    }

    private T Find<T>(string name) where T : class
    {
        var value = _w.FindName(name) as T;
        if (value == null) throw new InvalidOperationException("xaml element not found: " + name);
        return value;
    }

    private void ApplyCardWidth()
    {
        var width = _settings.CardWidth;
        if (width < 260) width = 260;
        if (width > 720) width = 720;
        _card.Width = width;
    }

    public void ApplySettings(Settings settings)
    {
        _settings = settings;
        ApplyCardWidth();
        _coverWrap.Visibility = string.Equals(settings.CardTheme, "minimal", StringComparison.OrdinalIgnoreCase)
            ? Visibility.Collapsed : Visibility.Visible;
        ApplyTheme(_accent);
    }

    private void Position()
    {
        var area = SystemParameters.WorkArea;
        _w.Left = area.Left + _settings.CardLeft;
        _w.Top = area.Top + _settings.CardTop;
    }

    public void ShowTrack(TrackInfo track, bool pause = false)
    {
        _volumeMode = false;
        _pauseMode = pause;
        _textCol.BeginAnimation(UIElement.OpacityProperty, null);
        _textCol.Opacity = 1;

        if (track != null && !string.IsNullOrEmpty(track.Title))
        {
            _titleText.Text = track.Title;
            _artistText.Text = string.IsNullOrEmpty(track.Artist) ? "Неизвестный исполнитель" : track.Artist;
            _albumText.Text = pause ? "Пауза" : (string.IsNullOrEmpty(track.Album) ? "Сингл" : track.Album);
            _progressRow.Visibility = Visibility.Visible;
            _volumeRow.Visibility = Visibility.Collapsed;
            SetArt(track.Art);
            UpdateProgress(track);
        }
        else
        {
            _titleText.Text = "Громкость";
            _artistText.Text = "";
            _albumText.Text = "";
            _progressRow.Visibility = Visibility.Collapsed;
            _volumeRow.Visibility = Visibility.Visible;
            SetArt(null);
            UpdateVolumeBar(Audio.VolumePercent, Audio.Muted);
        }

        PresentFresh();
        StartHold(pause ? 2200 : 5600);
        Log.Write("show " + (pause ? "pause" : "track") + " " + _titleText.Text);
    }

    public void ShowVolume(TrackInfo track)
    {
        _volumeMode = true;
        _pauseMode = false;

        if (track != null && !string.IsNullOrEmpty(track.Title))
        {
            _titleText.Text = track.Title;
            _artistText.Text = string.IsNullOrEmpty(track.Artist) ? "Неизвестный исполнитель" : track.Artist;
            _albumText.Text = "Громкость";
            _progressRow.Visibility = Visibility.Collapsed;
            _volumeRow.Visibility = Visibility.Visible;
            SetArt(track.Art);
            UpdateVolumeBar(Audio.VolumePercent, Audio.Muted);
        }
        else
        {
            _titleText.Text = "Громкость";
            _artistText.Text = "Ничего не играет";
            _albumText.Text = "";
            _progressRow.Visibility = Visibility.Collapsed;
            _volumeRow.Visibility = Visibility.Visible;
            SetArt(null);
            UpdateVolumeBar(Audio.VolumePercent, Audio.Muted);
        }

        var fresh = !IsShown;
        Position();
        if (fresh)
        {
            _w.Visibility = Visibility.Visible;
        }
        _hiding = false;
        _hideTimer.Stop();
        AnimateShow(fresh);
        StartHold(2200);
    }

    private void PresentFresh()
    {
        Position();
        var fresh = !IsShown;
        if (fresh) _w.Visibility = Visibility.Visible;
        _hiding = false;
        _hideTimer.Stop();
        AnimateShow(fresh);
    }

    public void RefreshTrack(TrackInfo track)
    {
        if (track == null || string.IsNullOrEmpty(track.Title)) return;
        CrossfadeText(
            track.Title,
            string.IsNullOrEmpty(track.Artist) ? "Неизвестный исполнитель" : track.Artist,
            string.IsNullOrEmpty(track.Album) ? "Сингл" : track.Album);
        FadeArt(track.Art);
        UpdateProgress(track);
        _holdTimer.Stop();
        _holdTimer.Interval = TimeSpan.FromMilliseconds(5600);
        _holdTimer.Start();
    }

    private void StartHold(int ms)
    {
        _holdTimer.Stop();
        _holdTimer.Interval = TimeSpan.FromMilliseconds(ms);
        _holdTimer.Start();
    }

    private void OnHoldElapsed(object sender, EventArgs e)
    {
        _holdTimer.Stop();
        if (_hiding) return;
        _hiding = true;
        AnimateHide();
        _hideTimer.Start();
    }

    private void OnHideElapsed(object sender, EventArgs e)
    {
        _hideTimer.Stop();
        _w.Visibility = Visibility.Hidden;
        _w.BeginAnimation(Window.OpacityProperty, null);
        _hiding = false;
    }

    private void AnimateShow(bool fresh)
    {
        _w.BeginAnimation(Window.OpacityProperty, null);
        var from = _w.Opacity;
        if (double.IsNaN(from)) from = 0;
        var fade = Anim(from, 1.0, fresh ? 260 : 140, EaseOut);
        _w.BeginAnimation(Window.OpacityProperty, fade);

        if (!fresh) return;

        var dur = TimeSpan.FromMilliseconds(260);
        _cardSlide.BeginAnimation(TranslateTransform.XProperty, Anim(-26, 0, 260, EaseOut));
        _cardScale.BeginAnimation(ScaleTransform.ScaleXProperty, Anim(0.93, 1, 260, EaseOut));
        _cardScale.BeginAnimation(ScaleTransform.ScaleYProperty, Anim(0.93, 1, 260, EaseOut));
        _coverArt.BeginAnimation(UIElement.OpacityProperty, Anim(0, 1, 320, EaseOut));
        _artScale.BeginAnimation(ScaleTransform.ScaleXProperty, Anim(1.08, 1, 420, EaseOut));
        _artScale.BeginAnimation(ScaleTransform.ScaleYProperty, Anim(1.08, 1, 420, EaseOut));

        var stagger = new (FrameworkElement el, TranslateTransform tr, int delay)[]
        {
            (_titleText, _titleT, 0),
            (_artistText, _artistT, 70),
            (_albumText, _albumT, 140),
            (_progressRow, null, 210)
        };
        foreach (var item in stagger)
        {
            var op = Anim(0, 1, 230, EaseOut);
            op.BeginTime = TimeSpan.FromMilliseconds(item.delay);
            item.el.BeginAnimation(UIElement.OpacityProperty, op);
            if (item.tr != null)
            {
                var ty = Anim(9, 0, 260, EaseOut);
                ty.BeginTime = TimeSpan.FromMilliseconds(item.delay);
                item.tr.BeginAnimation(TranslateTransform.YProperty, ty);
            }
        }
    }

    private void AnimateHide()
    {
        var fade = Anim(1, 0, 200, EaseIn);
        _w.BeginAnimation(Window.OpacityProperty, fade);
        _cardSlide.BeginAnimation(TranslateTransform.XProperty, Anim(0, -18, 200, EaseIn));
        _cardScale.BeginAnimation(ScaleTransform.ScaleXProperty, Anim(1, 0.96, 200, EaseIn));
        _cardScale.BeginAnimation(ScaleTransform.ScaleYProperty, Anim(1, 0.96, 200, EaseIn));
    }

    private static DoubleAnimation Anim(double from, double to, int ms, IEasingFunction ease = null)
    {
        var a = new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(ms));
        if (ease != null) a.EasingFunction = ease;
        return a;
    }

    public void HideNow()
    {
        _holdTimer.Stop();
        _hideTimer.Stop();
        _w.BeginAnimation(Window.OpacityProperty, null);
        _w.Visibility = Visibility.Hidden;
        _hiding = false;
    }

    private void CrossfadeText(string title, string artist, string album)
    {
        _titleText.Text = title;
        _artistText.Text = artist;
        _albumText.Text = album;
        foreach (var el in new FrameworkElement[] { _titleText, _artistText, _albumText })
        {
            el.BeginAnimation(UIElement.OpacityProperty, null);
            el.Opacity = 1;
        }
        _textCol.BeginAnimation(UIElement.OpacityProperty, null);
        _textCol.BeginAnimation(UIElement.OpacityProperty, Anim(0.35, 1, 180, EaseOut));
    }

    public void SetArt(BitmapImage art)
    {
        if (art != null)
        {
            var brush = new ImageBrush(art) { Stretch = Stretch.UniformToFill };
            _coverArt.Background = brush;
            _coverGlyph.Visibility = Visibility.Collapsed;
        }
        else
        {
            _coverArt.Background = Brushes.Transparent;
            _coverGlyph.Visibility = Visibility.Visible;
        }
    }

    public void FadeArt(BitmapImage art)
    {
        SetArt(art);
        _coverArt.BeginAnimation(UIElement.OpacityProperty, null);
        _coverArt.BeginAnimation(UIElement.OpacityProperty, Anim(0.35, 1, 170, EaseOut));

        _artSlide.BeginAnimation(TranslateTransform.XProperty, null);
        _artSlide.BeginAnimation(TranslateTransform.XProperty, Anim(48, 0, 260, EaseOut));

        if (!_vinyl)
        {
            _artScale.BeginAnimation(ScaleTransform.ScaleXProperty, Anim(1.06, 1, 220, EaseOut));
            _artScale.BeginAnimation(ScaleTransform.ScaleYProperty, Anim(1.06, 1, 220, EaseOut));
        }
    }

    public void UpdateProgress(TrackInfo track)
    {
        if (track == null || track.Duration <= TimeSpan.Zero)
        {
            _progressText.Text = "—:—";
            _ring.Visibility = Visibility.Collapsed;
            _ringTrack.Visibility = Visibility.Collapsed;
            return;
        }

        _progressRow.Visibility = Visibility.Visible;
        var position = track.PositionNow();
        if (position < TimeSpan.Zero) position = TimeSpan.Zero;
        if (position > track.Duration) position = track.Duration;

        double available = Math.Max(0, _progressRow.ActualWidth - 104);
        if (available <= 0) available = 160;
        double ratio = track.Duration.TotalSeconds <= 0 ? 0 : position.TotalSeconds / track.Duration.TotalSeconds;
        double target = Math.Max(0, Math.Min(available, available * ratio));

        var from = _progressFill.ActualWidth;
        if (double.IsNaN(from)) from = 0;
        var anim = new DoubleAnimation(from, target, TimeSpan.FromMilliseconds(260));
        _progressFill.BeginAnimation(FrameworkElement.WidthProperty, anim);
        _progressText.Text = FormatTime(position) + " — " + FormatTime(track.Duration);
        UpdateRing(ratio, _accent);
    }

    public static string FormatTime(TimeSpan value)
    {
        if (value < TimeSpan.Zero) value = TimeSpan.Zero;
        return ((int)value.TotalMinutes) + ":" + value.Seconds.ToString("00");
    }

    private void UpdateRing(double ratio, Color color)
    {
        try
        {
            if (ratio <= 0.0005 || ratio > 1.0)
            {
                _ring.Visibility = Visibility.Collapsed;
                _ringTrack.Visibility = Visibility.Collapsed;
                return;
            }
            _ringTrack.Visibility = Visibility.Visible;
            const double size = 84.0;
            double c = size / 2.0;
            double r = size / 2.0 - 2.0;
            double startDeg = -90.0;
            double endDeg = -90.0 + 360.0 * ratio;
            double a1 = startDeg * Math.PI / 180.0;
            double a2 = endDeg * Math.PI / 180.0;
            var p1 = new Point(c + r * Math.Cos(a1), c + r * Math.Sin(a1));
            var p2 = new Point(c + r * Math.Cos(a2), c + r * Math.Sin(a2));
            bool large = (endDeg - startDeg) > 180.0;

            var geo = new StreamGeometry();
            using (var ctx = geo.Open())
            {
                ctx.BeginFigure(p1, false, false);
                ctx.ArcTo(p2, new Size(r, r), 0, large, SweepDirection.Clockwise, true, false);
            }
            geo.Freeze();
            _ring.Data = geo;
            _ring.Stroke = new SolidColorBrush(color);
            _ring.Visibility = Visibility.Visible;
        }
        catch { }
    }

    public void UpdateVolumeBar(int percent, bool muted)
    {
        if (percent < 0)
        {
            _volumeRow.Visibility = Visibility.Collapsed;
            return;
        }
        _volumeRow.Visibility = Visibility.Visible;
        double available = Math.Max(0, _volumeRow.ActualWidth - 44);
        if (available <= 0) available = 172;
        double target = muted ? 0 : Math.Max(0, Math.Min(available, available * percent / 100.0));
        var from = _volumeFill.ActualWidth;
        if (double.IsNaN(from)) from = 0;
        var anim = Anim(from, target, 140, EaseOut);
        _volumeFill.BeginAnimation(FrameworkElement.WidthProperty, anim);

        if (muted)
        {
            _volumeText.Text = "выкл";
            _volumeText.Foreground = Brushes.Tomato;
            _volumeFill.Background = Brushes.Tomato;
        }
        else
        {
            _volumeText.Text = percent + "%";
            _volumeText.Foreground = new SolidColorBrush(Color.FromRgb(182, 168, 198));
            _volumeFill.Background = percent >= 60 ? new SolidColorBrush(Color.FromRgb(89, 242, 143))
                : percent >= 25 ? new SolidColorBrush(Color.FromRgb(240, 192, 96))
                : new SolidColorBrush(Color.FromRgb(255, 122, 107));
        }
    }

    public void SetEqualizer(bool playing)
    {
        if (_eqPlaying == playing) return;
        _eqPlaying = playing;
        try
        {
            if (playing)
            {
                var tops = new[] { 14.0, 9.0, 16.0 };
                var durations = new[] { 420, 560, 360 };
                for (int i = 0; i < _eqBars.Length; i++)
                {
                    var anim = new DoubleAnimation(3, tops[i], TimeSpan.FromMilliseconds(durations[i]))
                    {
                        AutoReverse = true,
                        RepeatBehavior = RepeatBehavior.Forever,
                        EasingFunction = EaseOut
                    };
                    _eqBars[i].BeginAnimation(FrameworkElement.HeightProperty, anim);
                }
            }
            else
            {
                var heights = new[] { 4.0, 8.0, 6.0 };
                for (int i = 0; i < _eqBars.Length; i++)
                {
                    _eqBars[i].BeginAnimation(FrameworkElement.HeightProperty, null);
                    _eqBars[i].Height = heights[i];
                }
            }
        }
        catch { }
    }

    public void SetAccent(Color color, BitmapImage art, string artKey)
    {
        _accent = color;
        ApplyTheme(color);
        ApplyBorder(color);
        if (art != null && artKey != _artKey)
        {
            _artKey = artKey;
            ApplyBackdrop(art);
        }
    }

    private void ApplyTheme(Color color)
    {
        try
        {
            int alpha = string.Equals(_settings.CardTheme, "glass", StringComparison.OrdinalIgnoreCase) ? 200 : 255;
            int mixR = (int)(22 * 0.68 + color.R * 0.32);
            int mixG = (int)(18 * 0.68 + color.G * 0.32);
            int mixB = (int)(28 * 0.68 + color.B * 0.32);
            var deep = Color.FromArgb((byte)alpha, 15, 12, 21);

            var bg = new LinearGradientBrush
            {
                StartPoint = new Point(0, 0),
                EndPoint = new Point(1, 1)
            };
            bg.GradientStops.Add(new GradientStop(Color.FromArgb((byte)alpha, (byte)mixR, (byte)mixG, (byte)mixB), 0));
            bg.GradientStops.Add(new GradientStop(deep, 0.55));
            bg.GradientStops.Add(new GradientStop(Color.FromArgb((byte)alpha, (byte)(mixR * 0.7), (byte)(mixG * 0.7), (byte)(mixB * 0.7)), 1));
            var spin = new RotateTransform { CenterX = 0.5, CenterY = 0.5 };
            bg.RelativeTransform = spin;
            _card.Background = bg;

            var spinAnim = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(26)) { RepeatBehavior = RepeatBehavior.Forever };
            spin.BeginAnimation(RotateTransform.AngleProperty, spinAnim);

            var ringGlow = new DropShadowEffect
            {
                BlurRadius = 12,
                ShadowDepth = 0,
                Opacity = 0.75,
                Color = color
            };
            _ring.Effect = ringGlow;
            _ring.StrokeThickness = 2.8;

            var titleBrush = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 0) };
            titleBrush.GradientStops.Add(new GradientStop(Color.FromRgb(255, 255, 255), 0));
            var lite = Color.FromRgb(
                (byte)(255 * 0.55 + color.R * 0.45),
                (byte)(255 * 0.55 + color.G * 0.45),
                (byte)(255 * 0.55 + color.B * 0.45));
            titleBrush.GradientStops.Add(new GradientStop(lite, 1));
            _titleText.Foreground = titleBrush;

            var fillGlow = new DropShadowEffect
            {
                BlurRadius = 8,
                ShadowDepth = 0,
                Opacity = 0.65,
                Color = color
            };
            _progressFill.Effect = fillGlow;
            _volumeFill.Effect = fillGlow;
        }
        catch { }
    }

    private void ApplyBorder(Color color)
    {
        try
        {
            _cardBorderBrush.GradientStops[0].Color = Color.FromArgb(70, color.R, color.G, color.B);
            _cardBorderBrush.GradientStops[1].Color = Color.FromArgb(170, color.R, color.G, color.B);
            _cardBorderBrush.GradientStops[2].Color = Color.FromArgb(36, color.R, color.G, color.B);
        }
        catch { }
    }

    private void ApplyBackdrop(BitmapImage art)
    {
        try
        {
            if (art == null)
            {
                _cardBackdrop.Opacity = 0;
                return;
            }
            var brush = new ImageBrush(art) { Stretch = Stretch.UniformToFill };
            _cardBackdrop.Background = brush;
            var fade = Anim(0, 0.55, 520);
            _cardBackdrop.BeginAnimation(UIElement.OpacityProperty, fade);
        }
        catch { }
    }

    public void SetVinyl(bool on)
    {
        if (on == _vinyl) return;
        _vinyl = on;
        if (on)
        {
            _coverBorder.CornerRadius = new CornerRadius(38);
            _coverArt.CornerRadius = new CornerRadius(38);
            if (_eqPlaying)
            {
                StartVinylSpin();
            }
        }
        else
        {
            _coverBorder.CornerRadius = new CornerRadius(12);
            _coverArt.CornerRadius = new CornerRadius(12);
            _artRotate.BeginAnimation(RotateTransform.AngleProperty, null);
            _artRotate.Angle = 0;
            _vinylSpinning = false;
        }
    }

    public void SetPlayingForVinyl(bool playing)
    {
        if (!_vinyl) return;
        if (playing && !_vinylSpinning) StartVinylSpin();
        else if (!playing && _vinylSpinning)
        {
            _artRotate.BeginAnimation(RotateTransform.AngleProperty, null);
            _vinylSpinning = false;
        }
    }

    private void StartVinylSpin()
    {
        var spin = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(8)) { RepeatBehavior = RepeatBehavior.Forever };
        _artRotate.BeginAnimation(RotateTransform.AngleProperty, spin);
        _vinylSpinning = true;
    }
}
