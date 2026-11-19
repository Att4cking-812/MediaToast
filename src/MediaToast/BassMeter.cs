using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace BrickyardBass {
    // Захват системного звука (WASAPI loopback) и выделение баса.
    // Даёт живой уровень и точные удары даже там, где микшерный метр «замерзает».
    public static class BassMeter {
        private const int AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;
        private const int AUDCLNT_BUFFERFLAGS_SILENT = 0x00000002;
        private const int CLSCTX_INPROC_SERVER = 1;

        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IMMDeviceEnumerator {
            int EnumAudioEndpoints(int flow, int mask, out IntPtr devices);
            int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
        }

        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IMMDevice {
            int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
            int OpenPropertyStore(int access, out IntPtr store);
            int GetId(out IntPtr id);
            int GetState(out int state);
        }

        [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IAudioClient {
            int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
            int GetBufferSize(out uint frames);
            int GetStreamLatency(out long latency);
            int GetCurrentPadding(out uint padding);
            int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
            int GetMixFormat(out IntPtr format);
            int GetDevicePeriod(out long defaultPeriod, out long minPeriod);
            int Start();
            int Stop();
            int Reset();
            int SetEventHandle(IntPtr evt);
            int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
        }

        [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IAudioCaptureClient {
            int GetBuffer(out IntPtr data, out uint frames, out uint flags, out long devicePosition, out long qpcPosition);
            int ReleaseBuffer(uint frames);
            int GetNextPacketSize(out uint frames);
        }

        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        internal class MMDeviceEnumeratorComObject { }

        private static Thread worker;
        private static volatile bool running = false;
        private static volatile bool ready = false;
        private static string lastError = "";
        private static volatile float level = 0f;
        private static volatile float strengthValue = 0f;
        private static int beatCount = 0;
        private static long lastBeatTicks = 0;

        public static bool IsRunning { get { return ready; } }
        public static string LastError { get { return lastError; } }
        public static float Level { get { return level; } }
        public static float LastStrength { get { return strengthValue; } }
        public static int BeatCount { get { return Interlocked.CompareExchange(ref beatCount, 0, 0); } }
        public static long LastBeatTicks { get { return Interlocked.Read(ref lastBeatTicks); } }

        public static void Start() {
            if (running) return;
            running = true;
            worker = new Thread(Loop);
            worker.IsBackground = true;
            worker.Name = "BassMeter";
            worker.Start();
        }

        public static void Stop() {
            running = false;
        }

        [DllImport("ole32.dll")]
        private static extern int CoInitializeEx(IntPtr pvReserved, int coInit);
        [DllImport("ole32.dll")]
        private static extern void CoUninitialize();
        [DllImport("ole32.dll")]
        private static extern void CoTaskMemFree(IntPtr pv);

        private static void Loop() {
            IAudioClient client = null;
            IAudioCaptureClient capture = null;
            IntPtr formatPtr = IntPtr.Zero;
            try {
                int hr = CoInitializeEx(IntPtr.Zero, 0);
                if (hr < 0) { lastError = "CoInitializeEx " + hr; return; }

                var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                IMMDevice device;
                hr = enumerator.GetDefaultAudioEndpoint(0, 1, out device);
                if (hr < 0 || device == null) { lastError = "no device " + hr; return; }

                Guid iid = typeof(IAudioClient).GUID;
                object clientObj;
                hr = device.Activate(ref iid, CLSCTX_INPROC_SERVER, IntPtr.Zero, out clientObj);
                if (hr < 0 || clientObj == null) { lastError = "activate " + hr; return; }
                client = (IAudioClient)clientObj;

                hr = client.GetMixFormat(out formatPtr);
                if (hr < 0) { lastError = "mix format " + hr; return; }

                int rate = Marshal.ReadInt32(formatPtr, 4);
                short channels = Marshal.ReadInt16(formatPtr, 2);
                short bits = Marshal.ReadInt16(formatPtr, 14);
                if (rate <= 0 || channels <= 0) { lastError = "bad format"; return; }

                hr = client.Initialize(0, AUDCLNT_STREAMFLAGS_LOOPBACK, 0, 0, formatPtr, IntPtr.Zero);
                if (hr < 0) { lastError = "initialize " + hr; return; }

                Guid capIid = typeof(IAudioCaptureClient).GUID;
                object capObj;
                hr = client.GetService(ref capIid, out capObj);
                if (hr < 0 || capObj == null) { lastError = "capture service " + hr; return; }
                capture = (IAudioCaptureClient)capObj;

                hr = client.Start();
                if (hr < 0) { lastError = "start " + hr; return; }

                ready = true;
                lastError = "";

                double alpha = 1.0 - Math.Exp(-2.0 * Math.PI * 120.0 / rate);
                float a = (float)Math.Max(0.0001, Math.Min(1.0, alpha));
                float lp1 = 0f, lp2 = 0f;
                float env = 0f, slow = 0f;
                float[] buffer = new float[0];
                long prevBeat = 0;

                while (running) {
                    uint packet;
                    if (capture.GetNextPacketSize(out packet) < 0) break;
                    if (packet == 0) { Thread.Sleep(3); continue; }

                    while (packet > 0 && running) {
                        IntPtr data;
                        uint frames;
                        uint flags;
                        long devPos, qpcPos;
                        if (capture.GetBuffer(out data, out frames, out flags, out devPos, out qpcPos) < 0) break;

                        double sumSq = 0.0;
                        int total = 0;
                        if (frames > 0 && (flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0 && data != IntPtr.Zero && bits == 32) {
                            int need = (int)frames * channels;
                            if (buffer.Length < need) buffer = new float[need];
                            Marshal.Copy(data, buffer, 0, need);
                            for (int i = 0; i < frames; i++) {
                                int idx = i * channels;
                                float mono = 0f;
                                for (int c = 0; c < channels; c++) mono += buffer[idx + c];
                                mono /= channels;
                                lp1 += a * (mono - lp1);
                                lp2 += a * (lp1 - lp2);
                                sumSq += lp2 * lp2;
                                total++;
                            }
                        }
                        capture.ReleaseBuffer(frames);

                        float rms = (total > 0) ? (float)Math.Sqrt(sumSq / total) : 0f;

                        // быстрая атака, мягкий спад
                        if (rms > env) env += (rms - env) * 0.85f;
                        else env = env * 0.86f + rms * 0.14f;
                        slow = slow * 0.986f + env * 0.014f;

                        float db = 20f * (float)Math.Log10(env + 0.0000001f);
                        float lvl = (db + 58f) / 45f;
                        if (lvl < 0f) lvl = 0f;
                        if (lvl > 1f) lvl = 1f;
                        level = lvl;

                        long nowTicks = DateTime.UtcNow.Ticks;
                        long msSince = prevBeat > 0 ? (nowTicks - prevBeat) / TimeSpan.TicksPerMillisecond : 9999;
                        if (env > slow * 1.30f + 0.002f && env > 0.004f && msSince > 110) {
                            float ratio = env / (slow + 0.000001f);
                            float strength = (ratio - 1.15f) / 1.1f;
                            if (strength < 0f) strength = 0f;
                            if (strength > 1f) strength = 1f;
                            strengthValue = strength;
                            prevBeat = nowTicks;
                            Interlocked.Exchange(ref lastBeatTicks, nowTicks);
                            Interlocked.Increment(ref beatCount);
                        }

                        if (capture.GetNextPacketSize(out packet) < 0) break;
                    }
                }
            } catch (Exception ex) {
                lastError = ex.Message;
            } finally {
                try { if (client != null) client.Stop(); } catch { }
                try { if (formatPtr != IntPtr.Zero) CoTaskMemFree(formatPtr); } catch { }
                try { if (capture != null && Marshal.IsComObject(capture)) Marshal.ReleaseComObject(capture); } catch { }
                try { if (client != null && Marshal.IsComObject(client)) Marshal.ReleaseComObject(client); } catch { }
                try { CoUninitialize(); } catch { }
                ready = false;
            }
        }
    }
}
