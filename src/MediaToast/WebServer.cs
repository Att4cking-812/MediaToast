using System;
using System.IO;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace MediaToast;

public sealed class WebServer : IDisposable
{
    private readonly ToastApp _app;
    private HttpListener _listener;
    private CancellationTokenSource _cts;
    private string _posKey = "";
    private double _posVal;
    private DateTime _posAt = DateTime.UtcNow;

    public int Port { get; set; } = 8765;
    public bool Running => _listener != null && _listener.IsListening;

    public WebServer(ToastApp app)
    {
        _app = app;
    }

    public bool Start()
    {
        if (Running) return true;
        for (int port = 8765; port <= 8775; port++)
        {
            try
            {
                var listener = new HttpListener();
                listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
                listener.Start();
                _listener = listener;
                Port = port;
                _cts = new CancellationTokenSource();
                _ = Task.Run(() => Loop(_cts.Token));
                Log.Write("web started on " + port);
                return true;
            }
            catch (Exception ex)
            {
                Log.Write("web try " + port + ": " + ex.Message);
                try { _listener?.Close(); } catch { }
                _listener = null;
            }
        }
        return false;
    }

    private async Task Loop(CancellationToken token)
    {
        while (!token.IsCancellationRequested && _listener != null && _listener.IsListening)
        {
            HttpListenerContext ctx;
            try
            {
                ctx = await _listener.GetContextAsync();
            }
            catch
            {
                break;
            }
            _ = Task.Run(() => Handle(ctx));
        }
    }

    private void Handle(HttpListenerContext ctx)
    {
        try
        {
            var path = ctx.Request.Url.AbsolutePath.ToLowerInvariant();
            switch (path)
            {
                case "/":
                case "/index.html":
                    WriteText(ctx, Assets.Load("web.html"), "text/html; charset=utf-8");
                    break;
                case "/api/now":
                    WriteNow(ctx);
                    break;
                case "/api/stats":
                    WriteJson(ctx, StatsService.Get());
                    break;
                case "/api/art":
                    WriteArt(ctx);
                    break;
                case "/api/control":
                    HandleControl(ctx);
                    break;
                case "/api/volume":
                    HandleVolume(ctx);
                    break;
                default:
                    ctx.Response.StatusCode = 404;
                    ctx.Response.Close();
                    break;
            }
        }
        catch (Exception ex)
        {
            Log.Write("web handle: " + ex.Message);
            try { ctx.Response.Abort(); } catch { }
        }
    }

    private void WriteNow(HttpListenerContext ctx)
    {
        var track = _app.Current;
        if (track == null || string.IsNullOrEmpty(track.Title))
        {
            WriteJson(ctx, new { ok = false });
            return;
        }

        var key = track.Title + "|" + track.Artist + "|" + track.Album;
        double pos = Math.Max(0, track.PositionNow().TotalSeconds);
        double dur = Math.Max(0, track.Duration.TotalSeconds);
        var now = DateTime.UtcNow;

        if (key != _posKey)
        {
            _posKey = key;
            _posVal = pos;
            _posAt = now;
        }
        else if (track.Playing)
        {
            var cand = _posVal + Math.Max(0, (now - _posAt).TotalSeconds);
            if (pos >= cand - 2) _posVal = pos;
            else _posVal = cand;
            _posAt = now;
            if (dur > 0 && _posVal > dur) _posVal = dur;
            pos = _posVal;
        }
        else
        {
            _posVal = pos;
            _posAt = now;
        }

        WriteJson(ctx, new
        {
            ok = true,
            title = track.Title,
            artist = track.Artist,
            album = track.Album,
            status = track.Status,
            position = (int)Math.Floor(pos),
            duration = (int)Math.Floor(dur),
            key
        });
    }

    private void WriteArt(HttpListenerContext ctx)
    {
        var bytes = _app.Current?.ArtBytes;
        if (bytes == null || bytes.Length == 0)
        {
            ctx.Response.StatusCode = 404;
            ctx.Response.Close();
            return;
        }

        string type = "image/jpeg";
        if (bytes.Length > 3)
        {
            if (bytes[0] == 0x89 && bytes[1] == 0x50) type = "image/png";
            else if (bytes[0] == 0x52 && bytes[1] == 0x49) type = "image/webp";
        }

        ctx.Response.ContentType = type;
        ctx.Response.Headers["Cache-Control"] = "no-store";
        ctx.Response.ContentLength64 = bytes.Length;
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.Close();
    }

    private void HandleControl(HttpListenerContext ctx)
    {
        var action = (ctx.Request.QueryString["do"] ?? "").ToLowerInvariant();
        var track = _app.Current;
        bool playing = track != null && track.Playing;

        switch (action)
        {
            case "prev": _app.SkipPrevious(); break;
            case "next": _app.SkipNext(); break;
            case "play": if (!playing) _app.TogglePlayPause(); break;
            case "pause": if (playing) _app.TogglePlayPause(); break;
            case "toggle": _app.TogglePlayPause(); break;
        }
        WriteJson(ctx, new { ok = true });
    }

    private void HandleVolume(HttpListenerContext ctx)
    {
        var set = ctx.Request.QueryString["set"];
        if (!string.IsNullOrEmpty(set) && int.TryParse(set, out var value))
        {
            _app.SetVolume(value);
        }
        WriteJson(ctx, new { percent = Audio.VolumePercent, muted = Audio.Muted });
    }

    private static void WriteJson(HttpListenerContext ctx, object value)
    {
        var json = JsonSerializer.Serialize(value);
        var bytes = Encoding.UTF8.GetBytes(json);
        ctx.Response.ContentType = "application/json; charset=utf-8";
        ctx.Response.Headers["Cache-Control"] = "no-store";
        ctx.Response.ContentLength64 = bytes.Length;
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.Close();
    }

    private static void WriteText(HttpListenerContext ctx, string text, string type)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        ctx.Response.ContentType = type;
        ctx.Response.Headers["Cache-Control"] = "no-store";
        ctx.Response.ContentLength64 = bytes.Length;
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.Close();
    }

    public void Dispose()
    {
        try { _cts?.Cancel(); } catch { }
        try { _listener?.Stop(); _listener?.Close(); } catch { }
        _listener = null;
    }
}
