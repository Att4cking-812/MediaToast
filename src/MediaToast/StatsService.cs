using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace MediaToast;

public sealed class StatsService
{
    public sealed class DayPoint
    {
        public string day { get; set; }
        public int secs { get; set; }
    }

    public sealed class NamedTime
    {
        public string name { get; set; }
        public int secs { get; set; }
    }

    public sealed class Result
    {
        public bool ok { get; set; } = true;
        public int total { get; set; }
        public int today { get; set; }
        public int week { get; set; }
        public List<DayPoint> chart { get; set; } = new();
        public List<NamedTime> artists { get; set; } = new();
        public List<NamedTime> tracks { get; set; } = new();
    }

    public static Result Get()
    {
        var rows = new List<(DateTime Ts, int Secs, string Artist, string Title)>();
        try
        {
            if (File.Exists(Stats.FilePath))
            {
                foreach (var line in File.ReadAllLines(Stats.FilePath))
                {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    var parts = line.Split('\t');
                    if (parts.Length < 4) continue;
                    if (!DateTime.TryParseExact(parts[0], "yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var ts)) continue;
                    if (!int.TryParse(parts[1], out var secs) || secs <= 0) continue;
                    rows.Add((ts, secs, parts[2], parts[3]));
                }
            }
        }
        catch (Exception ex)
        {
            Log.Write("stats read: " + ex.Message);
        }

        var today = DateTime.Today;
        int total = 0, todaySecs = 0, week = 0;
        var artists = new Dictionary<string, int>();
        var tracks = new Dictionary<string, int>();
        var days = new Dictionary<string, int>();

        foreach (var row in rows)
        {
            total += row.Secs;
            if (row.Ts.Date == today) todaySecs += row.Secs;
            if (row.Ts.Date >= today.AddDays(-6)) week += row.Secs;

            var artist = string.IsNullOrEmpty(row.Artist) ? "Неизвестный" : row.Artist;
            artists[artist] = artists.TryGetValue(artist, out var a) ? a + row.Secs : row.Secs;

            var track = artist + " — " + row.Title;
            tracks[track] = tracks.TryGetValue(track, out var t) ? t + row.Secs : row.Secs;

            var day = row.Ts.ToString("yyyy-MM-dd");
            days[day] = days.TryGetValue(day, out var d) ? d + row.Secs : row.Secs;
        }

        var result = new Result { total = total, today = todaySecs, week = week };
        for (int i = 13; i >= 0; i--)
        {
            var d = today.AddDays(-i);
            var key = d.ToString("yyyy-MM-dd");
            result.chart.Add(new DayPoint { day = d.ToString("dd.MM"), secs = days.TryGetValue(key, out var s) ? s : 0 });
        }

        result.artists = artists.OrderByDescending(x => x.Value).Take(6)
            .Select(x => new NamedTime { name = x.Key, secs = x.Value }).ToList();
        result.tracks = tracks.OrderByDescending(x => x.Value).Take(12)
            .Select(x => new NamedTime { name = x.Key, secs = x.Value }).ToList();
        return result;
    }
}
