using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace MyScreenshot;

internal sealed class RecordingSession : IDisposable
{
    private readonly CancellationTokenSource stop = new();

    public RecordingSession(string path, Rectangle area, Rectangle screen)
    {
        Path = path;
        Screen = screen;
        var token = stop.Token;
        Completion = Task.Run(() => Record(path, area, token));
    }

    public string Path { get; }
    public Rectangle Screen { get; }
    public Task<Bitmap> Completion { get; }
    public void Stop() => stop.Cancel();
    public void Dispose() => stop.Dispose();

    private static Bitmap Record(string path, Rectangle area, CancellationToken stop)
    {
        const int fps = 20;
        long frameDuration = TimeSpan.TicksPerSecond / fps;
        double scale = Math.Min(1, Math.Min(1920.0 / Math.Max(area.Width, area.Height), 1080.0 / Math.Min(area.Width, area.Height)));
        int width = Math.Max(2, (int)(area.Width * scale) / 2 * 2);
        int height = Math.Max(2, (int)(area.Height * scale) / 2 * 2);
        string temporary = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path)!,
            "." + System.IO.Path.GetFileNameWithoutExtension(path) + ".recording.mp4");
        Bitmap? thumbnail = null;
        try
        {
            using (var writer = new Mp4Writer(temporary, width, height, fps))
            using (var scaled = new Bitmap(width, height, PixelFormat.Format32bppRgb))
            {
                var clock = Stopwatch.StartNew();
                long time = 0;
                do
                {
                    using var frame = CaptureUtilities.ReadScreen(area, showPointer: true);
                    if (width != area.Width || height != area.Height)
                    {
                        using var graphics = Graphics.FromImage(scaled);
                        graphics.InterpolationMode = InterpolationMode.Bilinear;
                        graphics.DrawImage(frame, 0, 0, width, height);
                    }
                    var current = width == area.Width && height == area.Height ? frame : scaled;
                    thumbnail ??= new Bitmap(current, new Size(Math.Max(1, width * 360 / Math.Max(width, height)),
                                                                  Math.Max(1, height * 360 / Math.Max(width, height))));
                    writer.Append(current, time, frameDuration);
                    long next = time + frameDuration;
                    long delay = next - clock.Elapsed.Ticks;
                    if (delay > 0) stop.WaitHandle.WaitOne(TimeSpan.FromTicks(delay));
                    time = Math.Max(next, clock.Elapsed.Ticks);
                }
                while (!stop.IsCancellationRequested);
                writer.Complete();
            }
            File.Move(temporary, path);
            return thumbnail!;
        }
        catch
        {
            thumbnail?.Dispose();
            if (File.Exists(temporary)) File.Delete(temporary);
            throw;
        }
    }
}

internal sealed unsafe class Mp4Writer : IDisposable
{
    private static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    private static readonly Guid FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    private static readonly Guid PixelAspect = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    private static readonly Guid InterlaceMode = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    private static readonly Guid BitRate = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    private static readonly Guid DefaultStride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
    private static readonly Guid Video = new("73646976-0000-0010-8000-00aa00389b71");
    private static readonly Guid H264 = new("34363248-0000-0010-8000-00aa00389b71");
    private static readonly Guid Nv12 = new("3231564e-0000-0010-8000-00aa00389b71");

    private nint writer;
    private readonly int width;
    private readonly int height;
    private readonly uint stream;
    private bool started;
    private bool com;

    public Mp4Writer(string path, int width, int height, int fps)
    {
        this.width = width;
        this.height = height;
        nint input = 0, output = 0;
        try
        {
            Check(CoInitializeEx(0, 0));
            com = true;
            Check(MFStartup(0x00020070, 0));
            started = true;
            Check(MFCreateSinkWriterFromURL(path, 0, 0, out writer));
            output = CreateType(H264, width, height, fps);
            PutUInt32(output, BitRate, (uint)Math.Clamp(width * height * fps / 8, 450_000, 7_000_000));
            uint index = 0;
            // IMFSinkWriter::AddStream and SetInputMediaType.
            Check(((delegate* unmanaged[Stdcall]<nint, nint, uint*, int>)Slots(writer)[3])(writer, output, &index));
            stream = index;
            input = CreateType(Nv12, width, height, fps);
            PutUInt32(input, DefaultStride, (uint)width);
            Check(((delegate* unmanaged[Stdcall]<nint, uint, nint, nint, int>)Slots(writer)[4])(writer, stream, input, 0));
            Check(((delegate* unmanaged[Stdcall]<nint, int>)Slots(writer)[5])(writer));
        }
        catch
        {
            Release(input);
            Release(output);
            Dispose();
            throw;
        }
        Release(input);
        Release(output);
    }

    public void Append(Bitmap frame, long time, long duration)
    {
        nint buffer = 0, sample = 0;
        uint length = (uint)(width * height * 3 / 2);
        try
        {
            Check(MFCreateMemoryBuffer(length, out buffer));
            byte* pixels = null;
            // IMFMediaBuffer::Lock, Unlock, SetCurrentLength.
            Check(((delegate* unmanaged[Stdcall]<nint, byte**, uint*, uint*, int>)Slots(buffer)[3])(buffer, &pixels, null, null));
            try { ConvertToNv12(frame, pixels); }
            finally { Check(((delegate* unmanaged[Stdcall]<nint, int>)Slots(buffer)[4])(buffer)); }
            Check(((delegate* unmanaged[Stdcall]<nint, uint, int>)Slots(buffer)[6])(buffer, length));

            Check(MFCreateSample(out sample));
            // IMFSample::AddBuffer, SetSampleTime, SetSampleDuration.
            Check(((delegate* unmanaged[Stdcall]<nint, nint, int>)Slots(sample)[42])(sample, buffer));
            Check(((delegate* unmanaged[Stdcall]<nint, long, int>)Slots(sample)[36])(sample, time));
            Check(((delegate* unmanaged[Stdcall]<nint, long, int>)Slots(sample)[38])(sample, duration));
            Check(((delegate* unmanaged[Stdcall]<nint, uint, nint, int>)Slots(writer)[6])(writer, stream, sample));
        }
        finally
        {
            Release(sample);
            Release(buffer);
        }
    }

    public void Complete() => Check(((delegate* unmanaged[Stdcall]<nint, int>)Slots(writer)[11])(writer));

    private void ConvertToNv12(Bitmap frame, byte* target)
    {
        var bitmap = frame.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
        try
        {
            byte* chroma = target + width * height;
            for (int y = 0; y < height; y += 2)
            {
                byte* upper = (byte*)bitmap.Scan0 + y * bitmap.Stride;
                byte* lower = upper + bitmap.Stride;
                byte* y0 = target + y * width;
                byte* y1 = y0 + width;
                for (int x = 0; x < width; x += 2)
                {
                    y0[x] = Luma(upper);
                    y0[x + 1] = Luma(upper + 4);
                    y1[x] = Luma(lower);
                    y1[x + 1] = Luma(lower + 4);
                    int b = (upper[0] + upper[4] + lower[0] + lower[4]) / 4;
                    int g = (upper[1] + upper[5] + lower[1] + lower[5]) / 4;
                    int r = (upper[2] + upper[6] + lower[2] + lower[6]) / 4;
                    *chroma++ = (byte)(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
                    *chroma++ = (byte)(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
                    upper += 8;
                    lower += 8;
                }
            }
        }
        finally { frame.UnlockBits(bitmap); }
    }

    private static byte Luma(byte* bgr) =>
        (byte)(((66 * bgr[2] + 129 * bgr[1] + 25 * bgr[0] + 128) >> 8) + 16);

    private static nint CreateType(Guid subtype, int width, int height, int fps)
    {
        Check(MFCreateMediaType(out nint type));
        try
        {
            PutGuid(type, MajorType, Video);
            PutGuid(type, Subtype, subtype);
            PutUInt32(type, InterlaceMode, 2);
            PutPair(type, FrameSize, width, height);
            PutPair(type, FrameRate, fps, 1);
            PutPair(type, PixelAspect, 1, 1);
            return type;
        }
        catch { Release(type); throw; }
    }

    private static nint* Slots(nint value) => *(nint**)value;
    // IMFMediaType begins with the IMFAttributes vtable.
    private static void PutGuid(nint obj, Guid key, Guid value) =>
        Check(((delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)Slots(obj)[24])(obj, &key, &value));
    private static void PutUInt32(nint obj, Guid key, uint value) =>
        Check(((delegate* unmanaged[Stdcall]<nint, Guid*, uint, int>)Slots(obj)[21])(obj, &key, value));
    private static void PutPair(nint obj, Guid key, int high, int low) =>
        Check(((delegate* unmanaged[Stdcall]<nint, Guid*, ulong, int>)Slots(obj)[22])(obj, &key, ((ulong)high << 32) | (uint)low));

    public void Dispose()
    {
        Release(writer);
        writer = 0;
        if (started) { MFShutdown(); started = false; }
        if (com) { CoUninitialize(); com = false; }
    }

    private static void Release(nint value)
    {
        if (value != 0) ((delegate* unmanaged[Stdcall]<nint, uint>)Slots(value)[2])(value);
    }

    private static void Check(int result)
    {
        if (result < 0) Marshal.ThrowExceptionForHR(result);
    }

    [DllImport("ole32.dll")] private static extern int CoInitializeEx(nint reserved, uint apartment);
    [DllImport("ole32.dll")] private static extern void CoUninitialize();
    [DllImport("mfplat.dll")] private static extern int MFStartup(uint version, uint flags);
    [DllImport("mfplat.dll")] private static extern int MFShutdown();
    [DllImport("mfplat.dll")] private static extern int MFCreateMediaType(out nint mediaType);
    [DllImport("mfplat.dll")] private static extern int MFCreateSample(out nint sample);
    [DllImport("mfplat.dll")] private static extern int MFCreateMemoryBuffer(uint maxLength, out nint buffer);
    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int MFCreateSinkWriterFromURL(string output, nint byteStream, nint attributes, out nint writer);
}
