using Application = System.Windows.Application;
using System;
using System.Threading;
using System.Windows;

namespace MediaToast;

public static class Program
{
    private static Mutex _mutex;

    [STAThread]
    public static void Main(string[] args)
    {
        _mutex = new Mutex(true, @"Local\BrickyardMediaToast3", out bool created);
        if (!created) return;

        var app = new Application
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown
        };
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write("unhandled: " + e.Exception);
            e.Handled = true;
        };

        ToastApp controller = null;
        try
        {
            controller = new ToastApp();
        }
        catch (Exception ex)
        {
            Log.Write("startup: " + ex);
            System.Windows.MessageBox.Show("MediaToast не смог запуститься:\n" + ex.Message, "MediaToast");
            return;
        }

        var wantPanel = Array.IndexOf(args, "--panel") >= 0;
        var wantWeb = Array.IndexOf(args, "--web") >= 0;
        var wantServer = Array.IndexOf(args, "--server") >= 0;
        if (wantPanel) app.Dispatcher.BeginInvoke(new Action(() => controller.ShowTrayPanel()));
        if (wantServer) app.Dispatcher.BeginInvoke(new Action(() => controller.StartWebServer()));
        if (wantWeb) app.Dispatcher.BeginInvoke(new Action(() => controller.OpenWeb()));

        try
        {
            app.Run();
        }
        finally
        {
            try { controller.Shutdown(); } catch { }
            try { _mutex.ReleaseMutex(); } catch { }
        }
    }
}
