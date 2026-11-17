using System.Diagnostics;
using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace MyScreenshot;

internal static class CaptureUtilities
{
    public static Bitmap ReadScreen(Rectangle region, bool showPointer = false)
    {
        var image = new Bitmap(region.Width, region.Height, PixelFormat.Format32bppRgb);
        try
        {
            using var graphics = Graphics.FromImage(image);
            Native.CopyDesktop(graphics, region);
            if (showPointer) Native.PaintCursor(graphics, region);
            return image;
        }
        catch { image.Dispose(); throw; }
    }

    public static Icon CreateCameraIcon(Color color)
    {
        using var bitmap = new Bitmap(32, 32);
        using var graphics = Graphics.FromImage(bitmap);
        using var fill = new SolidBrush(color);
        using var pen = new Pen(Color.White, 2.2f);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.FillEllipse(fill, 0, 0, 31, 31);
        graphics.DrawRectangle(pen, 6, 10, 19, 14);
        graphics.DrawEllipse(pen, 12, 13, 7, 7);
        graphics.DrawLine(pen, 11, 8, 19, 8);
        var handle = bitmap.GetHicon();
        try { using var borrowed = Icon.FromHandle(handle); return (Icon)borrowed.Clone(); }
        finally { Native.DestroyIcon(handle); }
    }

    public static void Open(string path)
    {
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true })?.Dispose();
    }

    public static void Reveal(string path)
    {
        Process.Start("explorer.exe", $"/select,\"{path}\"")?.Dispose();
    }

    public static void SaveImage(Bitmap image, string path, ScreenshotFormat format)
    {
        var temp = path + ".tmp";
        try
        {
            using (var output = new FileStream(temp, FileMode.CreateNew))
            {
                switch (format)
                {
                    case ScreenshotFormat.Png: image.Save(output, ImageFormat.Png); break;
                    case ScreenshotFormat.Jpeg: SaveJpeg(image, output, 92L); break;
                    case ScreenshotFormat.Pdf:
                        using (var jpeg = new MemoryStream())
                        {
                            SaveJpeg(image, jpeg, 97L);
                            ScreenshotPdf.Write(output, jpeg.ToArray(), image.Width, image.Height);
                        }
                        break;
                }
            }
            File.Move(temp, path);
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
        }
    }

    private static void SaveJpeg(Bitmap image, Stream output, long quality)
    {
        var encoder = ImageCodecInfo.GetImageEncoders().First(codec => codec.FormatID == ImageFormat.Jpeg.Guid);
        using var options = new EncoderParameters(1);
        options.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
        image.Save(output, encoder, options);
    }
}

internal static class ScreenshotPdf
{
    public static void Write(Stream output, byte[] jpeg, int width, int height)
    {
        var offsets = new long[6];
        void Text(string value) => output.Write(Encoding.ASCII.GetBytes(value));
        void Begin(int id)
        {
            offsets[id] = output.Position;
            Text(FormattableString.Invariant($"{id} 0 obj\n"));
        }
        void End() => Text("\nendobj\n");

        Text("%PDF-1.4\n");
        Begin(1);
        Text("<< /Type /Catalog /Pages 2 0 R >>");
        End();
        Begin(2);
        Text("<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
        End();
        Begin(3);
        Text(FormattableString.Invariant($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>"));
        End();
        Begin(4);
        Text(FormattableString.Invariant($"<< /Type /XObject /Subtype /Image /Width {width} /Height {height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {jpeg.Length} >>\nstream\n"));
        output.Write(jpeg);
        Text("\nendstream");
        End();
        Begin(5);
        var commands = FormattableString.Invariant($"q {width} 0 0 {height} 0 0 cm /Im0 Do Q\n");
        Text(FormattableString.Invariant($"<< /Length {commands.Length} >>\nstream\n{commands}endstream"));
        End();
        var xref = output.Position;
        Text("xref\n0 6\n0000000000 65535 f \n");
        for (int i = 1; i < offsets.Length; i++) Text(FormattableString.Invariant($"{offsets[i]:D10} 00000 n \n"));
        Text(FormattableString.Invariant($"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"));
    }
}

internal sealed class HotKeyWindow : NativeWindow, IDisposable
{
    public bool Registered { get; }
    private readonly Action capture;

    public HotKeyWindow(Action capture)
    {
        this.capture = capture;
        CreateHandle(new CreateParams { Caption = "MyScreenshot Hotkey", Parent = new IntPtr(-3) });
        Registered = Native.RegisterHotKey(Handle, 1, 0x4006, (uint)Keys.A);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x0312 && message.WParam == 1) capture();
        else base.WndProc(ref message);
    }

    public void Dispose()
    {
        if (Registered) Native.UnregisterHotKey(Handle, 1);
        DestroyHandle();
    }
}

internal sealed class RecordingShade : IDisposable
{
    private readonly List<Form> windows = new();

    public RecordingShade(Rectangle screen, Rectangle region)
    {
        try
        {
            Add(Rectangle.FromLTRB(screen.Left, screen.Top, screen.Right, region.Top));
            Add(Rectangle.FromLTRB(screen.Left, region.Bottom, screen.Right, screen.Bottom));
            Add(Rectangle.FromLTRB(screen.Left, region.Top, region.Left, region.Bottom));
            Add(Rectangle.FromLTRB(region.Right, region.Top, screen.Right, region.Bottom));
        }
        catch { Dispose(); throw; }
    }

    private void Add(Rectangle bounds)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0) return;
        var overlay = new ShadeWindow
        {
            Bounds = bounds, StartPosition = FormStartPosition.Manual, FormBorderStyle = FormBorderStyle.None,
            TopMost = true, ShowInTaskbar = false, BackColor = Color.Black, Opacity = 0.34
        };
        windows.Add(overlay);
        Native.SetWindowDisplayAffinity(overlay.Handle, 0x11);
        overlay.Show();
    }

    public void Dispose()
    {
        foreach (var window in windows) window.Dispose();
        windows.Clear();
    }

    private sealed class ShadeWindow : Form
    {
        protected override bool ShowWithoutActivation => true;
        protected override CreateParams CreateParams
        {
            get
            {
                var parameters = base.CreateParams;
                parameters.ExStyle |= 0x08000020;
                return parameters;
            }
        }
    }
}

internal static partial class Native
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Box { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct CursorInfo { public int Size, Flags; public nint Cursor; public Point Position; }

    [StructLayout(LayoutKind.Sequential)]
    private struct IconInfo { public int IsIcon, HotspotX, HotspotY; public nint Mask, Color; }

    [DllImport("user32.dll")] private static extern bool GetCursorInfo(ref CursorInfo value);
    [DllImport("user32.dll")] private static extern bool GetIconInfo(nint icon, out IconInfo value);
    [DllImport("user32.dll")] private static extern bool DrawIconEx(nint dc, int x, int y, nint icon, int width, int height, uint step, nint brush, uint flags);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint GetDC(nint window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(nint window, nint dc);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern bool BitBlt(nint destination, int x, int y, int width, int height,
        nint source, int sourceX, int sourceY, uint operation);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint handle);

    public static void CopyDesktop(Graphics graphics, Rectangle region)
    {
        const uint sourceCopy = 0x00CC0020;
        const uint captureLayeredWindows = 0x40000000;
        nint desktop = GetDC(0);
        if (desktop == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            nint target = graphics.GetHdc();
            try
            {
                if (!BitBlt(target, 0, 0, region.Width, region.Height, desktop, region.X, region.Y, sourceCopy | captureLayeredWindows))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { graphics.ReleaseHdc(target); }
        }
        finally { ReleaseDC(0, desktop); }
    }

    public static void PaintCursor(Graphics graphics, Rectangle region)
    {
        var cursor = new CursorInfo { Size = Marshal.SizeOf<CursorInfo>() };
        if (!GetCursorInfo(ref cursor) || (cursor.Flags & 1) == 0 || !region.Contains(cursor.Position)) return;
        if (!GetIconInfo(cursor.Cursor, out var icon)) return;
        try
        {
            nint dc = graphics.GetHdc();
            try
            {
                DrawIconEx(dc, cursor.Position.X - region.X - icon.HotspotX, cursor.Position.Y - region.Y - icon.HotspotY,
                    cursor.Cursor, 0, 0, 0, 0, 3);
            }
            finally { graphics.ReleaseHdc(dc); }
        }
        finally
        {
            if (icon.Mask != 0) DeleteObject(icon.Mask);
            if (icon.Color != 0) DeleteObject(icon.Color);
        }
    }

    private delegate bool EnumerateWindow(nint window, nint data);

    [DllImport("user32.dll")] public static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(nint window, uint affinity);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumerateWindow callback, nint data);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] private static extern int ReadBounds(nint window, uint attribute, out Box value, uint size);
    [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] private static extern int ReadAttribute(nint window, uint attribute, out uint value, uint size);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out Box value);

    public static (List<Rectangle> Windows, Rectangle Focused) WindowBounds(Rectangle screen)
    {
        var windows = new List<Rectangle>();
        var foreground = GetForegroundWindow();
        var focused = Rectangle.Empty;
        EnumWindows((handle, _) =>
        {
            if (!IsWindowVisible(handle) || IsIconic(handle)) return true;
            if (ReadAttribute(handle, 14, out uint cloaked, 4) == 0 && cloaked != 0) return true;
            if (ReadBounds(handle, 9, out Box box, 16) != 0 && !GetWindowRect(handle, out box)) return true;
            var region = Rectangle.Intersect(Rectangle.FromLTRB(box.Left, box.Top, box.Right, box.Bottom), screen);
            if (region.Width < 32 || region.Height < 32 || region == screen && handle != foreground) return true;
            region.Offset(-screen.X, -screen.Y);
            windows.Add(region);
            if (handle == foreground) focused = region;
            return true;
        }, 0);
        return (windows, focused);
    }
}
