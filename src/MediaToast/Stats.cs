using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace MediaToast;

public sealed class Stats
{
    public static readonly string FilePath = Path.Combine(Settings.DataDir, "listening.tsv");

    static Stats()
    {
        try
        {
            if (!File.Exists(FilePath))
            {
                var legacy = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "MediaToast", "listening.tsv");
                if (File.Exists(legacy))
                {
                    Directory.CreateDirectory(Settings.DataDir);
                    File.Copy(legacy, FilePath, false);
                    Log.Write("listening history migrated from v2");
                }
            }
        }
        catch (Exception ex)
        {
            Log.Write("listening migrate: " + ex.Message);
        }
    }

    private string _key = "";
    private string _artist = "";
    private string _title = "";
    private double _accum;
    private DateTime _last = DateTime.UtcNow;

    public void Track(TrackInfo track, bool playing)
    {
        var now = DateTime.UtcNow;
        double delta = (now - _last).TotalSeconds;
        _last = now;
        if (delta < 0 || delta > 10) delta = 0;

        if (!playing || track == null || string.IsNullOrEmpty(track.Title))
        {
            if (_accum >= 1)
            {
                WriteChunk(_accum);
                _accum = 0;
            }
            return;
        }

        var key = track.Title + "|" + track.Artist;
        if (key != _key)
        {
            if (_accum >= 1) WriteChunk(_accum);
            _key = key;
            _artist = track.Artist ?? "";
            _title = track.Title ?? "";
            _accum = 0;
        }

        _accum += delta;
        if (_accum >= 30)
        {
            WriteChunk(30);
            _accum -= 30;
        }
    }

    private void WriteChunk(double seconds)
    {
        if (seconds < 1 || (string.IsNullOrEmpty(_artist) && string.IsNullOrEmpty(_title))) return;
        try
        {
            Directory.CreateDirectory(Settings.DataDir);
            var stamp = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);
            var line = stamp + "\t" + (int)Math.Round(seconds) + "\t" + _artist + "\t" + _title;
            File.AppendAllText(FilePath, line + Environment.NewLine, new UTF8Encoding(false));
        }
        catch (Exception ex)
        {
            Log.Write("stats write: " + ex.Message);
        }
    }

    public void Flush()
    {
        if (_accum >= 1)
        {
            WriteChunk(_accum);
            _accum = 0;
        }
    }
}
