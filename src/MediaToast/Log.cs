using System;
using System.IO;
using System.Text;

namespace MediaToast;

public static class Log
{
    private static readonly object Sync = new();
    private static readonly string FilePath = Path.Combine(Settings.DataDir, "toast.log");

    public static void Write(string message)
    {
        try
        {
            lock (Sync)
            {
                Directory.CreateDirectory(Settings.DataDir);
                File.AppendAllText(FilePath, "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + message + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch { }
    }
}
