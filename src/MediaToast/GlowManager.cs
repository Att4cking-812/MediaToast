using Color = System.Windows.Media.Color;
using Point = System.Windows.Point;
using Size = System.Windows.Size;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace MediaToast;

public sealed class GlowManager
{
    private sealed class Sector
    {
        public Border Border;
        public ScaleTransform Scale;
        public int Index;
    }

    private sealed class Edge
    {
        public string Side;
        public Window Window;
        public List<Sector> Sectors = new();
    }

    private readonly Settings _settings;
    private readonly List<Edge> _edges = new();
    private readonly DispatcherTimer _timer;
    private Color _color = Color.FromRgb(111, 216, 255);
    private Color _secondary = Color.FromRgb(120, 180, 220);

    private bool _built;
    private bool _enabled;
    private bool _paused = true;
    private double _breathT;
    private double _level;
    private double _jolt;
    private double _energy;
    private int _doubleTicks;
    private int _lastBeatCount = -1;
    private string _style = "";

    private static readonly CubicEase EaseOut = new() { EasingMode = EasingMode.EaseOut };

    public GlowManager(Settings settings)
    {
        _settings = settings;
        _style = settings.GlowStyle;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(25) };
        _timer.Tick += OnTick;
    }

    public bool Enabled => _enabled;

    public void SetEnabled(bool on)
    {
        if (on == _enabled) return;
        _enabled = on;
        if (on)
        {
            EnsureBuilt();
            foreach (var edge in _edges)
            {
                edge.Window.BeginAnimation(UIElement.OpacityProperty, null);
                edge.Window.Opacity = 0;
                edge.Window.Visibility = Visibility.Visible;
            }
            _breathT = 0;
            _jolt = 0;
            _lastBeatCount = -1;
            _timer.Start();
            Log.Write("glow on");
        }
        else
        {
            _timer.Stop();
            foreach (var edge in _edges)
            {
                edge.Window.Visibility = Visibility.Hidden;
            }
            Log.Write("glow off");
        }
    }

    public void ApplySettings(Settings settings)
    {
        bool styleChanged = !string.Equals(_style, settings.GlowStyle, StringComparison.OrdinalIgnoreCase);
        _style = settings.GlowStyle;
        if (styleChanged && _built)
        {
            Rebuild();
        }
        if (_enabled)
        {
            EnsureBuilt();
        }
    }

    public void SetColor(Color color)
    {
        _color = color;
        _secondary = ColorUtil.Secondary(color);
        if (!_built) return;
        foreach (var edge in _edges)
        {
            foreach (var sector in edge.Sectors)
            {
                var c = (sector.Index % 2) == 0 ? _color : _secondary;
                if (sector.Border.Background is LinearGradientBrush brush && brush.GradientStops.Count >= 2)
                {
                    brush.GradientStops[0].Color = Color.FromArgb(215, c.R, c.G, c.B);
                    brush.GradientStops[1].Color = Color.FromArgb(0, c.R, c.G, c.B);
                }
            }
        }
    }

    public void SetPlaying(bool playing)
    {
        _paused = !playing;
    }

    private void EnsureBuilt()
    {
        if (_built) return;
        Build();
        _built = true;
    }

    private void Rebuild()
    {
        foreach (var edge in _edges)
        {
            try { edge.Window.Close(); } catch { }
        }
        _edges.Clear();
        Build();
        if (_enabled)
        {
            foreach (var edge in _edges)
            {
                edge.Window.Visibility = Visibility.Visible;
                edge.Window.Opacity = 0;
            }
        }
    }

    private void Build()
    {
        bool strips = string.Equals(_style, "strips", StringComparison.OrdinalIgnoreCase);
        int thick = strips ? 60 : 72;
        int segments = strips ? 1 : 8;

        double sw = SystemParameters.PrimaryScreenWidth;
        double sh = SystemParameters.PrimaryScreenHeight;

        foreach (var side in new[] { "top", "bottom", "left", "right" })
        {
            var win = new Window
            {
                WindowStyle = WindowStyle.None,
                AllowsTransparency = true,
                Background = Brushes.Transparent,
                ShowInTaskbar = false,
                Topmost = true,
                ShowActivated = false,
                Focusable = false,
                IsHitTestVisible = false,
                ResizeMode = ResizeMode.NoResize,
                Opacity = 0
            };

            switch (side)
            {
                case "top":
                    win.Left = 0; win.Top = 0; win.Width = sw; win.Height = thick;
                    break;
                case "bottom":
                    win.Left = 0; win.Top = sh - thick; win.Width = sw; win.Height = thick;
                    break;
                case "left":
                    win.Left = 0; win.Top = 0; win.Width = thick; win.Height = sh;
                    break;
                case "right":
                    win.Left = sw - thick; win.Top = 0; win.Width = thick; win.Height = sh;
                    break;
            }

            var grid = new Grid();
            bool horizontal = side == "top" || side == "bottom";
            var edge = new Edge { Side = side, Window = win };

            for (int i = 0; i < segments; i++)
            {
                var border = new Border
                {
                    RenderTransformOrigin = new Point(0.5, 0.5)
                };
                var brush = new LinearGradientBrush();
                switch (side)
                {
                    case "top":
                        brush.StartPoint = new Point(0.5, 0.0);
                        brush.EndPoint = new Point(0.5, 1.0);
                        break;
                    case "bottom":
                        brush.StartPoint = new Point(0.5, 1.0);
                        brush.EndPoint = new Point(0.5, 0.0);
                        break;
                    case "left":
                        brush.StartPoint = new Point(0.0, 0.5);
                        brush.EndPoint = new Point(1.0, 0.5);
                        break;
                    case "right":
                        brush.StartPoint = new Point(1.0, 0.5);
                        brush.EndPoint = new Point(0.0, 0.5);
                        break;
                }

                var c = (i % 2) == 0 ? _color : _secondary;
                brush.GradientStops.Add(new GradientStop(Color.FromArgb(215, c.R, c.G, c.B), 0.0));
                brush.GradientStops.Add(new GradientStop(Color.FromArgb(0, c.R, c.G, c.B), 1.0));
                border.Background = brush;

                var scale = new ScaleTransform(1, 1);
                border.RenderTransform = scale;

                if (horizontal)
                {
                    grid.ColumnDefinitions.Add(new ColumnDefinition());
                    Grid.SetColumn(border, i);
                }
                else
                {
                    grid.RowDefinitions.Add(new RowDefinition());
                    Grid.SetRow(border, i);
                }

                grid.Children.Add(border);
                edge.Sectors.Add(new Sector { Border = border, Scale = scale, Index = i });
            }

            win.Content = grid;
            win.SourceInitialized += (_, _) => WindowUtil.MakeClickThrough(win);
            win.Show();
            win.Visibility = Visibility.Hidden;
            _edges.Add(edge);
        }
    }

    private void OnTick(object sender, EventArgs e)
    {
        try
        {
            if (_edges.Count == 0) return;
            _breathT += 0.025;

            double level = 0;
            int beatCount = 0;
            double strength = 0.6;
            try
            {
                level = BrickyardBass.BassMeter.Level;
                beatCount = BrickyardBass.BassMeter.BeatCount;
                strength = BrickyardBass.BassMeter.LastStrength;
            }
            catch { }

            if (_lastBeatCount < 0) _lastBeatCount = beatCount;
            if (beatCount != _lastBeatCount)
            {
                _lastBeatCount = beatCount;
                _jolt = 0.55 + 0.45 * strength;
                Flash();
                if (strength > 0.6) _doubleTicks = 3;
            }
            if (_doubleTicks > 0)
            {
                _doubleTicks--;
                if (_doubleTicks == 0) { _jolt = 0.85; Flash(); }
            }
            _jolt *= 0.90;

            if (level > _level) _level = level;
            else _level = _level * 0.90 + level * 0.10;

            double period = Period();
            _energy = _energy * 0.995 + _level * 0.005;

            double op = 0;
            if (!_paused)
            {
                var offsets = new[] { 0.0, 0.34, 0.18, 0.52 };
                double breath = 0.5 + 0.5 * Math.Sin(2.0 * Math.PI * (_breathT + offsets[0]) / period);
                op = 0.10 + 0.36 * breath + _level * 0.20 + _jolt * 0.65;
                if (op < 0.01) op = 0;
                if (op > 1.0) op = 1.0;
                foreach (var edge in _edges)
                {
                    edge.Window.Opacity = op;
                }
            }
            else
            {
                foreach (var edge in _edges) edge.Window.Opacity = 0;
            }
        }
        catch { }
    }

    private double Period()
    {
        double basePeriod = 3.2;
        switch ((_settings.GlowPreset ?? "neon").ToLowerInvariant())
        {
            case "calm": basePeriod = 4.6; break;
            case "fire": basePeriod = 2.2; break;
            case "auto":
                if (_energy > 0.62) basePeriod = 2.2;
                else if (_energy < 0.28) basePeriod = 4.4;
                else basePeriod = 3.2;
                break;
            default: basePeriod = 3.2; break;
        }
        double b = _settings.BreathSeconds;
        if (b > 0.5 && b < 12) basePeriod = basePeriod * (b / 3.2);
        return basePeriod;
    }

    private void Flash()
    {
        foreach (var edge in _edges)
        {
            bool horizontal = edge.Side == "top" || edge.Side == "bottom";
            if (edge.Sectors.Count <= 1)
            {
                var b = edge.Sectors[0].Border;
                var a = new DoubleAnimation(0.75, 1.0, TimeSpan.FromMilliseconds(140))
                {
                    AutoReverse = true,
                    EasingFunction = EaseOut
                };
                b.BeginAnimation(UIElement.OpacityProperty, a);
                continue;
            }

            foreach (var sector in edge.Sectors)
            {
                var delay = TimeSpan.FromMilliseconds(sector.Index * 8);
                var dur = TimeSpan.FromMilliseconds(90);
                var grow = new DoubleAnimation(1.0, 1.38, dur)
                {
                    AutoReverse = true,
                    BeginTime = delay,
                    EasingFunction = EaseOut
                };
                var wide = new DoubleAnimation(1.0, 1.18, dur)
                {
                    AutoReverse = true,
                    BeginTime = delay,
                    EasingFunction = EaseOut
                };
                if (horizontal)
                {
                    sector.Scale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
                    sector.Scale.BeginAnimation(ScaleTransform.ScaleXProperty, wide);
                }
                else
                {
                    sector.Scale.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
                    sector.Scale.BeginAnimation(ScaleTransform.ScaleYProperty, wide);
                }
            }
        }
    }

    public void Shutdown()
    {
        try { _timer.Stop(); } catch { }
        foreach (var edge in _edges)
        {
            try { edge.Window.Close(); } catch { }
        }
        _edges.Clear();
        _built = false;
    }
}
