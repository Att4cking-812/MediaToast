using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace BrickyardBass {
    // Захват звука: весь системный микс (loopback) или отдельное приложение
    // через Windows process loopback. Выделяет бас и считает удары.
    public static class BassMeter {
        private const int AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;
        private const int AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM = unchecked((int)0x80000000);
        private const int AUDCLNT_BUFFERFLAGS_SILENT = 0x00000002;
        private const int CLSCTX_INPROC_SERVER = 1;
        private const int VT_BLOB = 65;
        private const string PROCESS_LOOPBACK_DEVICE = "VAD\\Process_Loopback";

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

        private static readonly Guid CLSID_MMDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");

        private static IMMDeviceEnumerator CreateDeviceEnumerator() {
            var type = Type.GetTypeFromCLSID(CLSID_MMDeviceEnumerator);
            return (IMMDeviceEnumerator)Activator.CreateInstance(type);
        }

        [ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IActivateAudioInterfaceCompletionHandler {
            [PreserveSig] int ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation);
        }

        [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IActivateAudioInterfaceAsyncOperation {
            [PreserveSig] int GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BLOB {
            public int cbSize;
            public IntPtr pBlobData;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct PROPVARIANT {
            [FieldOffset(0)] public ushort vt;
            [FieldOffset(8)] public BLOB blob;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
            public uint TargetProcessId;
            public int ProcessLoopbackMode;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct AUDIOCLIENT_ACTIVATION_PARAMS {
            public int ActivationType;
            public AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WAVEFORMATEX {
            public ushort wFormatTag;
            public ushort nChannels;
            public uint nSamplesPerSec;
            public uint nAvgBytesPerSec;
            public ushort nBlockAlign;
            public ushort wBitsPerSample;
            public ushort cbSize;
        }

        [DllImport("mmdevapi.dll", ExactSpelling = true, PreserveSig = true)]
        private static extern int ActivateAudioInterfaceAsync(
            [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
            ref Guid riid,
            ref PROPVARIANT activationParams,
            [MarshalAs(UnmanagedType.Interface)] IActivateAudioInterfaceCompletionHandler completionHandler,
            out IActivateAudioInterfaceAsyncOperation activationOperation);

        [DllImport("ole32.dll")]
        private static extern int CoInitializeEx(IntPtr pvReserved, int coInit);
        [DllImport("ole32.dll")]
        private static extern void CoUninitialize();
        [DllImport("ole32.dll")]
        private static extern void CoTaskMemFree(IntPtr pv);

        private static readonly object sync = new();
        private static Thread worker;
        private static int generation;
        private static volatile bool ready = false;
        private static string lastError = "";
        private static volatile float level = 0f;
        private static volatile float strengthValue = 0f;
        private static int beatCount = 0;
        private static long lastBeatTicks = 0;
        private static string sourceName = "system";
        private static string activeSource = "";
        private static DateTime lastStart = DateTime.MinValue;

        public static bool IsRunning { get { return ready; } }
        public static string LastError { get { return lastError; } }
        public static float Level { get { return level; } }
        public static float LastStrength { get { return strengthValue; } }
        public static int BeatCount { get { return Interlocked.CompareExchange(ref beatCount, 0, 0); } }
        public static long LastBeatTicks { get { return Interlocked.Read(ref lastBeatTicks); } }
        public static string Source { get { return sourceName; } }
        public static string ActiveSource { get { return activeSource; } }

        public static void Start() {
            lock (sync) {
                if (worker != null && worker.IsAlive) return;
                if ((DateTime.UtcNow - lastStart).TotalSeconds < 3) return;
                lastStart = DateTime.UtcNow;
                StartLocked(sourceName);
            }
        }

        public static void Stop() {
            lock (sync) {
                Interlocked.Increment(ref generation);
                worker = null;
            }
            ready = false;
        }

        public static void SetSource(string name) {
            name = string.IsNullOrWhiteSpace(name) ? "system" : name.Trim();
            lock (sync) {
                if (name == sourceName && worker != null && worker.IsAlive) return;
                sourceName = name;
                Interlocked.Increment(ref generation);
                var old = worker;
                worker = null;
                try { old?.Join(1200); } catch { }
                lastStart = DateTime.UtcNow;
                StartLocked(name);
            }
        }

        private static void StartLocked(string source) {
            int gen = Interlocked.Increment(ref generation);
            ready = false;
            var t = new Thread(() => Loop(gen, source));
            t.IsBackground = true;
            t.Name = "BassMeter";
            worker = t;
            t.Start();
        }

        public static List<string> GetAvailableSources() {
            var result = new List<string> { "system" };
            var hints = new string[] { "яндекс", "yandex", "spotify", "aimp", "vlc", "foobar", "musicbee", "itunes", "winamp", "firefox", "chrome", "msedge", "brave", "opera", "vivaldi", "youtube", "browser" };
            foreach (var p in Process.GetProcesses()) {
                try {
                    var n = p.ProcessName;
                    var low = n.ToLowerInvariant();
                    if (low.Contains("rpc") || low.Contains("helper") || low.Contains("service") || low.Contains("webview") || low.Contains("crashpad")) continue;
                    bool match = false;
                    for (int i = 0; i < hints.Length; i++) {
                        if (low.Contains(hints[i])) { match = true; break; }
                    }
                    if (match && !result.Contains(n)) result.Add(n);
                } catch { }
            }
            return result;
        }

        private static int FindProcessPid(string name) {
            foreach (var p in Process.GetProcesses()) {
                try { if (string.Equals(p.ProcessName, name, StringComparison.OrdinalIgnoreCase)) return p.Id; }
                catch { }
            }
            return 0;
        }

        private static bool IsCurrent(int gen) {
            return Volatile.Read(ref generation) == gen;
        }

        private static void Loop(int gen, string requestedSource) {
            IAudioClient client = null;
            IAudioCaptureClient capture = null;
            IntPtr formatPtr = IntPtr.Zero;
            bool mixFormat = false;
            int pid = 0;
            try {
                int hr = CoInitializeEx(IntPtr.Zero, 0);
                if (hr < 0) { lastError = "CoInitializeEx " + hr; return; }

                string source = requestedSource;
                int rate = 0;
                short channels = 0;
                short bits = 0;

                if (source != "system") {
                    pid = FindProcessPid(source);
                    if (pid <= 0) {
                        lastError = "process not found: " + source;
                        return;
                    } else if (!TryCreateProcessClient(pid, out client, out formatPtr, out rate, out channels, out bits)) {
                        source = "system";
                        client = null;
                        formatPtr = IntPtr.Zero;
                    }
                }

                int flags = AUDCLNT_STREAMFLAGS_LOOPBACK;
                if (source == "system") {
                    pid = 0;
                    var enumerator = CreateDeviceEnumerator();
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
                    mixFormat = true;

                    rate = Marshal.ReadInt32(formatPtr, 4);
                    channels = Marshal.ReadInt16(formatPtr, 2);
                    bits = Marshal.ReadInt16(formatPtr, 14);
                    if (rate <= 0 || channels <= 0) { lastError = "bad format"; return; }
                } else {
                    flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM;
                }

                hr = client.Initialize(0, flags, 0, 0, formatPtr, IntPtr.Zero);
                if (hr < 0) { lastError = "initialize " + hr; return; }

                Guid capIid = typeof(IAudioCaptureClient).GUID;
                object capObj;
                hr = client.GetService(ref capIid, out capObj);
                if (hr < 0 || capObj == null) { lastError = "capture service " + hr; return; }
                capture = (IAudioCaptureClient)capObj;

                hr = client.Start();
                if (hr < 0) { lastError = "start " + hr; return; }

                activeSource = source;
                ready = true;
                lastError = "";

                double alpha = 1.0 - Math.Exp(-2.0 * Math.PI * 120.0 / rate);
                float a = (float)Math.Max(0.0001, Math.Min(1.0, alpha));
                float lp1 = 0f, lp2 = 0f;
                float env = 0f, slow = 0f;
                float[] fbuffer = new float[0];
                short[] sbuffer = new short[0];
                long prevBeat = 0;
                DateTime lastPidCheck = DateTime.UtcNow;

                while (IsCurrent(gen)) {
                    if (pid > 0 && (DateTime.UtcNow - lastPidCheck).TotalSeconds > 2) {
                        lastPidCheck = DateTime.UtcNow;
                        try { Process.GetProcessById(pid); }
                        catch { lastError = "source process exited"; break; }
                    }

                    uint packet;
                    if (capture.GetNextPacketSize(out packet) < 0) break;
                    if (packet == 0) { Thread.Sleep(3); continue; }

                    while (packet > 0 && IsCurrent(gen)) {
                        IntPtr data;
                        uint frames;
                        uint flagsBuf;
                        long devPos, qpcPos;
                        if (capture.GetBuffer(out data, out frames, out flagsBuf, out devPos, out qpcPos) < 0) break;

                        double sumSq = 0.0;
                        int total = 0;
                        bool silent = (flagsBuf & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
                        if (frames > 0 && !silent && data != IntPtr.Zero) {
                            int need = (int)frames * channels;
                            if (bits == 32) {
                                if (fbuffer.Length < need) fbuffer = new float[need];
                                Marshal.Copy(data, fbuffer, 0, need);
                                for (int i = 0; i < frames; i++) {
                                    int idx = i * channels;
                                    float mono = 0f;
                                    for (int c = 0; c < channels; c++) mono += fbuffer[idx + c];
                                    mono /= channels;
                                    lp1 += a * (mono - lp1);
                                    lp2 += a * (lp1 - lp2);
                                    sumSq += lp2 * lp2;
                                    total++;
                                }
                            } else if (bits == 16) {
                                if (sbuffer.Length < need) sbuffer = new short[need];
                                Marshal.Copy(data, sbuffer, 0, need);
                                for (int i = 0; i < frames; i++) {
                                    int idx = i * channels;
                                    float mono = 0f;
                                    for (int c = 0; c < channels; c++) mono += sbuffer[idx + c] / 32768f;
                                    mono /= channels;
                                    lp1 += a * (mono - lp1);
                                    lp2 += a * (lp1 - lp2);
                                    sumSq += lp2 * lp2;
                                    total++;
                                }
                            }
                        }
                        capture.ReleaseBuffer(frames);

                        float rms = (total > 0) ? (float)Math.Sqrt(sumSq / total) : 0f;

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
                try {
                    if (formatPtr != IntPtr.Zero) {
                        if (mixFormat) CoTaskMemFree(formatPtr);
                        else Marshal.FreeHGlobal(formatPtr);
                    }
                } catch { }
                try { if (capture != null && Marshal.IsComObject(capture)) Marshal.ReleaseComObject(capture); } catch { }
                try { if (client != null && Marshal.IsComObject(client)) Marshal.ReleaseComObject(client); } catch { }
                try { CoUninitialize(); } catch { }
                if (IsCurrent(gen)) {
                    ready = false;
                    activeSource = "";
                }
            }
        }

        private static bool TryCreateProcessClient(int pid, out IAudioClient client, out IntPtr formatPtr, out int rate, out short channels, out short bits) {
            client = null;
            formatPtr = IntPtr.Zero;
            rate = 44100;
            channels = 2;
            bits = 16;

            IntPtr paramsPtr = IntPtr.Zero;
            try {
                var p = new AUDIOCLIENT_ACTIVATION_PARAMS {
                    ActivationType = 1,
                    ProcessLoopbackParams = new AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
                        TargetProcessId = (uint)pid,
                        ProcessLoopbackMode = 0
                    }
                };
                int size = Marshal.SizeOf<AUDIOCLIENT_ACTIVATION_PARAMS>();
                paramsPtr = Marshal.AllocHGlobal(size);
                Marshal.StructureToPtr(p, paramsPtr, false);

                var pv = new PROPVARIANT {
                    vt = VT_BLOB,
                    blob = new BLOB { cbSize = size, pBlobData = paramsPtr }
                };

                var handler = new ActivationHandler();
                Guid iid = typeof(IAudioClient).GUID;
                IActivateAudioInterfaceAsyncOperation op;
                int hr = ActivateAudioInterfaceAsync(PROCESS_LOOPBACK_DEVICE, ref iid, ref pv, handler, out op);
                if (hr < 0) { lastError = "activation call " + hr; return false; }
                if (!handler.Done.Wait(3000)) { lastError = "activation timeout"; return false; }
                if (handler.Result < 0 || handler.Client == null) {
                    lastError = "activation 0x" + handler.Result.ToString("X8");
                    return false;
                }

                client = (IAudioClient)handler.Client;

                var fmt = new WAVEFORMATEX {
                    wFormatTag = 1,
                    nChannels = 2,
                    nSamplesPerSec = 44100,
                    nAvgBytesPerSec = 44100 * 4,
                    nBlockAlign = 4,
                    wBitsPerSample = 16,
                    cbSize = 0
                };
                formatPtr = Marshal.AllocHGlobal(Marshal.SizeOf<WAVEFORMATEX>());
                Marshal.StructureToPtr(fmt, formatPtr, false);
                return true;
            } catch (Exception ex) {
                lastError = "process loopback: " + ex.Message;
                try { if (formatPtr != IntPtr.Zero) Marshal.FreeHGlobal(formatPtr); } catch { }
                formatPtr = IntPtr.Zero;
                client = null;
                return false;
            } finally {
                if (paramsPtr != IntPtr.Zero) {
                    try { Marshal.FreeHGlobal(paramsPtr); } catch { }
                }
            }
        }

        [ComVisible(true)]
        public sealed class ActivationHandler : IActivateAudioInterfaceCompletionHandler {
            public readonly ManualResetEventSlim Done = new ManualResetEventSlim(false);
            public int Result = -1;
            public object Client;

            public int ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation) {
                try {
                    int hr = activateOperation.GetActivateResult(out int activateResult, out object activated);
                    Result = hr < 0 ? hr : activateResult;
                    Client = activated;
                } catch (Exception ex) {
                    Result = ex.HResult;
                }
                Done.Set();
                return 0;
            }
        }
    }
}
