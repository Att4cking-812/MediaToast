using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace MediaToast;

public static class WindowUtil
{
    private const int GwlExStyle = -20;
    private const long WsExTransparent = 0x20;
    private const long WsExToolWindow = 0x80;
    private const long WsExNoActivate = 0x08000000;
    private const long WsExLayered = 0x00080000;

    [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
    private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLong")]
    private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    private static long GetEx(IntPtr hWnd)
    {
        return IntPtr.Size == 8
            ? GetWindowLongPtr64(hWnd, GwlExStyle).ToInt64()
            : GetWindowLong32(hWnd, GwlExStyle);
    }

    private static void SetEx(IntPtr hWnd, long value)
    {
        if (IntPtr.Size == 8) SetWindowLongPtr64(hWnd, GwlExStyle, new IntPtr(value));
        else SetWindowLong32(hWnd, GwlExStyle, (int)value);
    }

    public static void MakeClickThrough(Window window)
    {
        try
        {
            var helper = new WindowInteropHelper(window);
            var h = helper.Handle;
            if (h == IntPtr.Zero) return;
            long ex = GetEx(h);
            ex |= WsExTransparent | WsExToolWindow | WsExNoActivate | WsExLayered;
            SetEx(h, ex);
        }
        catch { }
    }
}
