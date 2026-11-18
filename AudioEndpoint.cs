using System;
using System.Runtime.InteropServices;

namespace BrickyardAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject { }

    internal enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
    internal enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppDevice);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioEndpointVolume {        int RegisterControlChangeNotify(IntPtr pNotify);
        int UnregisterControlChangeNotify(IntPtr pNotify);
        int GetChannelCount(out uint pnChannelCount);
        int SetMasterVolumeLevel(float fLevelDB, Guid pguidEventContext);
        int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
        int GetMasterVolumeLevel(out float pfLevelDB);
        int GetMasterVolumeLevelScalar(out float pfLevel);
        int SetChannelVolumeLevel(uint nChannel, float fLevelDB, Guid pguidEventContext);
        int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, Guid pguidEventContext);
        int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
        int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
        int SetMute(bool bMute, Guid pguidEventContext);
        int GetMute(out bool pbMute);
        int GetVolumeStepInfo(out uint pnStep, out uint pnStepCount);
        int VolumeStepUp(Guid pguidEventContext);
        int VolumeStepDown(Guid pguidEventContext);
        int QueryHardwareSupport(out uint pdwHardwareSupportMask);
        int GetVolumeRange(out float pflVolumeMindB, out float pflVolumeMaxdB, out float pflVolumeIncrementdB);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioMeterInformation {
        int GetPeakValue(out float pfPeak);
    }

    public static class Endpoint {
        private static IAudioEndpointVolume _vol;
        private static IAudioMeterInformation _meter;

        private static IAudioMeterInformation Meter() {
            if (_meter != null) return _meter;
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice device;
            enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device);
            Guid iid = typeof(IAudioMeterInformation).GUID;
            object o;
            device.Activate(ref iid, 1, IntPtr.Zero, out o);
            _meter = (IAudioMeterInformation)o;
            return _meter;
        }

        public static float GetPeak() {
            try {
                float peak;
                Meter().GetPeakValue(out peak);
                if (peak < 0f) peak = 0f;
                if (peak > 1f) peak = 1f;
                return peak;
            } catch { _meter = null; return 0f; }
        }

        private static IAudioEndpointVolume Vol() {
            if (_vol != null) return _vol;
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice device;
            enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device);
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            object o;
            device.Activate(ref iid, 1, IntPtr.Zero, out o);
            _vol = (IAudioEndpointVolume)o;
            return _vol;
        }

        public static int GetVolumePercent() {
            try {
                float level;
                Vol().GetMasterVolumeLevelScalar(out level);
                return (int)Math.Round(level * 100);
            } catch { _vol = null; return -1; }
        }

        public static bool GetMute() {
            try { bool m; Vol().GetMute(out m); return m; } catch { _vol = null; return false; }
        }

        public static void SetVolumePercent(int percent) {
            if (percent < 0) percent = 0;
            if (percent > 100) percent = 100;
            float level = percent / 100f;
            Guid ctx = Guid.Empty;
            Vol().SetMasterVolumeLevelScalar(level, ctx);
        }
    }
}
