using System;

namespace MediaToast;

public static class Audio
{
    public static int VolumePercent => BrickyardAudio.Endpoint.GetVolumePercent();

    public static bool Muted => BrickyardAudio.Endpoint.GetMute();

    public static void SetVolume(int percent) => BrickyardAudio.Endpoint.SetVolumePercent(percent);

    public static void SetMuted(bool muted) => BrickyardAudio.Endpoint.SetMute(muted);
}
