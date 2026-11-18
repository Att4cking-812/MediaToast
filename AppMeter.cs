using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace BrickyardAudio {
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionManager2 {
        int GetAudioSessionControl(IntPtr a, int b, out IntPtr c);
        int GetSimpleAudioVolume(IntPtr a, int b, out IntPtr c);
        int GetSessionEnumerator(out IAudioSessionEnumerator enumerator);
        int RegisterSessionNotification(IntPtr n);
        int UnregisterSessionNotification(IntPtr n);
        int RegisterDuckNotification(string s, IntPtr n);
        int UnregisterDuckNotification(IntPtr n);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionEnumerator {
        int GetCount(out int count);
        int GetSession(int index, out IAudioSessionControl control);
    }

    [ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl {
        int GetState(out int state);
        int GetDisplayName(out IntPtr name);
        int SetDisplayName(string name, IntPtr ctx);
        int GetIconPath(out IntPtr path);
        int SetIconPath(string path, IntPtr ctx);
        int GetGroupingParam(out Guid p);
        int SetGroupingParam(ref Guid p, IntPtr ctx);
        int RegisterAudioSessionNotification(IntPtr n);
        int UnregisterAudioSessionNotification(IntPtr n);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl2 {
        int GetState(out int state);
        int GetDisplayName(out IntPtr name);
        int SetDisplayName(string name, IntPtr ctx);
        int GetIconPath(out IntPtr path);
        int SetIconPath(string path, IntPtr ctx);
        int GetGroupingParam(out Guid p);
        int SetGroupingParam(ref Guid p, IntPtr ctx);
        int RegisterAudioSessionNotification(IntPtr n);
        int UnregisterAudioSessionNotification(IntPtr n);
        int GetSessionIdentifier(out IntPtr id);
        int GetSessionInstanceIdentifier(out IntPtr id);
        int GetProcessId(out uint pid);
        int IsSystemSoundsSession();
        int SetDuckingPreference(bool enable);
    }

    public static class AppMeter {
        private static readonly string[] Hints = new string[] {
            "yandex", "музыка", "music", "spotify", "aimp", "vlc", "foobar", "winamp", "itunes", "musicbee"
        };

        private static bool Matches(string name) {
            if (string.IsNullOrEmpty(name)) return false;
            string low = name.ToLowerInvariant();
            for (int i = 0; i < Hints.Length; i++) {
                if (low.Contains(Hints[i])) return true;
            }
            return false;
        }

        public static float GetMusicPeak() {
            float best = 0f;
            bool foundApp = false;
            try {
                var enumeratorDevice = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                IMMDevice device;
                enumeratorDevice.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device);

                Guid iid = typeof(IAudioSessionManager2).GUID;
                object mgrObj;
                device.Activate(ref iid, 1, IntPtr.Zero, out mgrObj);
                var mgr = (IAudioSessionManager2)mgrObj;

                IAudioSessionEnumerator sessions;
                mgr.GetSessionEnumerator(out sessions);
                int count;
                sessions.GetCount(out count);

                for (int i = 0; i < count; i++) {
                    IAudioSessionControl ctl;
                    if (sessions.GetSession(i, out ctl) != 0) continue;

                    uint pid = 0;
                    var ctl2 = ctl as IAudioSessionControl2;
                    if (ctl2 != null) {
                        try { ctl2.GetProcessId(out pid); } catch { pid = 0; }
                    }

                    string procName = "";
                    if (pid > 0) {
                        try { procName = Process.GetProcessById((int)pid).ProcessName; } catch { procName = ""; }
                    }

                    if (!Matches(procName)) continue;

                    var meter = ctl as IAudioMeterInformation;
                    if (meter == null) continue;
                    float peak = 0f;
                    try { meter.GetPeakValue(out peak); } catch { peak = 0f; }
                    foundApp = true;
                    if (peak > best) best = peak;
                }
            } catch { }

            if (!foundApp) {
                // нет отдельной сессии плеера — берём общий пик устройства
                try { return Endpoint.GetPeak(); } catch { return 0f; }
            }
            return best;
        }
    }
}
