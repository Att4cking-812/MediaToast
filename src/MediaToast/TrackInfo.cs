using System;
using System.Windows.Media.Imaging;

namespace MediaToast;

public sealed class TrackInfo
{
    public string Title = "";
    public string Artist = "";
    public string Album = "";
    public string Key = "";
    public string Status = "";
    public bool Playing;
    public byte[] ArtBytes;
    public BitmapImage Art;
    public TimeSpan Position;
    public TimeSpan Duration;
    public double Rate = 1.0;
    public DateTime PositionAt = DateTime.UtcNow;

    public TimeSpan PositionNow()
    {
        if (!Playing || Rate <= 0.01) return Position;
        var extra = (DateTime.UtcNow - PositionAt).TotalSeconds * Rate;
        var pos = Position + TimeSpan.FromSeconds(extra);
        if (Duration > TimeSpan.Zero && pos > Duration) pos = Duration;
        if (pos < TimeSpan.Zero) pos = TimeSpan.Zero;
        return pos;
    }

    public bool HasArt => Art != null;
}
