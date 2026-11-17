using System.Diagnostics;
using System.Text.Json;
using Microsoft.Win32;

namespace MyScreenshot;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, @"Local\MyScreenshot.Windows", out bool first);
        if (!first) return;
        using var app = new ScreenshotApp();
        Application.Run(app);
    }
}

internal enum ScreenshotFormat { Png, Jpeg, Pdf }

internal sealed class Preferences
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "MyScreenshot";
    private static readonly string SettingsFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Name, "settings.json");

    public static string DefaultFolder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Мой Скриншот");

    public ScreenshotFormat Format { get; set; }
    public string? CustomFolder { get; set; }
    public bool StartupConfigured { get; set; }
    public bool PreviewDragLearned { get; set; }

    public string Folder => CustomFolder ?? DefaultFolder;

    public static Preferences Read()
    {
        try
        {
            var settings = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(SettingsFile));
            if (settings is null) return new();
            if (!Enum.IsDefined(settings.Format)) settings.Format = ScreenshotFormat.Png;
            if (settings.CustomFolder is { } folder && !Path.IsPathFullyQualified(folder)) settings.CustomFolder = null;
            return settings;
        }
        catch (IOException) { return new(); }
        catch (JsonException) { return new(); }
        catch (UnauthorizedAccessException) { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(SettingsFile)!);
        var temporary = SettingsFile + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this));
        File.Move(temporary, SettingsFile, true);
    }

    public void PrepareFolder()
    {
        if (CustomFolder is null) Directory.CreateDirectory(DefaultFolder);
        else if (!Directory.Exists(CustomFolder)) throw new DirectoryNotFoundException("Папка сохранения недоступна: " + CustomFolder);
    }

    public string FilePath(string prefix, string extension)
    {
        PrepareFolder();
        var name = $"{prefix} {DateTime.Now:yyyy-MM-dd HH.mm.ss.fff}.{extension}";
        return Path.Combine(Folder, name);
    }

    public static bool StartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return string.Equals(key?.GetValue(Name) as string, $"\"{Application.ExecutablePath}\"", StringComparison.OrdinalIgnoreCase);
    }

    public void SetStartup(bool active)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (active) key.SetValue(Name, $"\"{Application.ExecutablePath}\"");
        else key.DeleteValue(Name, false);
        StartupConfigured = true;
        Save();
    }
}

internal sealed class ScreenshotApp : ApplicationContext
{
    private const string Name = "Мой Скриншот";
    private readonly Preferences preferences = Preferences.Read();
    private readonly ContextMenuStrip menu = new();
    private readonly NotifyIcon tray;
    private readonly Icon icon = CaptureUtilities.CreateCameraIcon(Color.FromArgb(33, 107, 201));
    private readonly Icon recordingIcon = CaptureUtilities.CreateCameraIcon(Color.Firebrick);
    private readonly HotKeyWindow hotKey;
    private SelectionWindow? selection;
    private CapturePreview? preview;
    private RecordingSession? recording;
    private RecordingShade? shade;
    private string? lastFile;
    private bool stopping;
    private bool quitting;

    public ScreenshotApp()
    {
        tray = new NotifyIcon { Icon = icon, Text = Name, ContextMenuStrip = menu, Visible = true };
        tray.MouseDoubleClick += (_, e) => { if (e.Button == MouseButtons.Left) CaptureArea(); };
        menu.Opening += (_, _) => PopulateMenu();
        PopulateMenu();
        hotKey = new HotKeyWindow(CaptureArea);
        if (!preferences.StartupConfigured)
        {
            try { preferences.SetStartup(true); }
            catch (Exception error) { Report("Автозапуск", error); }
        }
        if (!hotKey.Registered)
            tray.ShowBalloonTip(4000, Name, "Ctrl+Shift+A занято. Захват области доступен в меню.", ToolTipIcon.Info);
    }

    private void PopulateMenu()
    {
        foreach (ToolStripItem item in menu.Items.OfType<ToolStripItem>().ToArray()) item.Dispose();
        menu.Items.Clear();
        bool canCapture = selection is null;
        Add("Скриншот области", CaptureArea, canCapture).ShortcutKeyDisplayString = "Ctrl+Shift+A";
        Add("Скриншот экрана", () => Capture(false, false), canCapture);
        menu.Items.Add(new ToolStripSeparator());
        if (recording is null)
        {
            Add("Записать область экрана", () => Capture(true, true), canCapture);
            Add("Записать весь экран", () => Capture(true, false), canCapture);
        }
        else Add(stopping ? "Сохранение видео…" : "Остановить запись", () => _ = StopRecording(), !stopping);
        menu.Items.Add(new ToolStripSeparator());
        Add("Показать последний файл", () => CaptureUtilities.Reveal(lastFile!), File.Exists(lastFile));
        Add("Открыть папку сохранения", () => Run(() => { preferences.PrepareFolder(); CaptureUtilities.Open(preferences.Folder); }));
        var formats = new ToolStripMenuItem("Формат снимков");
        foreach (var format in Enum.GetValues<ScreenshotFormat>())
        {
            var item = new ToolStripMenuItem(format.ToString().ToUpperInvariant()) { Checked = preferences.Format == format };
            item.Click += (_, _) => Run(() => { preferences.Format = format; preferences.Save(); });
            formats.DropDownItems.Add(item);
        }
        menu.Items.Add(formats);
        menu.Items.Add(new ToolStripSeparator());
        Add("Настройки…", ShowSettings);
        Add("Запускать при входе", () => Run(() => preferences.SetStartup(!Preferences.StartupEnabled())))
            .Checked = Preferences.StartupEnabled();
        Add("Выйти", () => _ = Quit());
    }

    private ToolStripMenuItem Add(string label, Action action, bool enabled = true)
    {
        var item = new ToolStripMenuItem(label) { Enabled = enabled };
        item.Click += (_, _) => action();
        menu.Items.Add(item);
        return item;
    }

    private void CaptureArea()
    {
        if (selection is { } existing) { existing.Close(); return; }
        Capture(false, true);
    }

    private void Capture(bool video, bool area) => Run(() =>
    {
        if (selection is not null || quitting || video && recording is not null) return;
        ClosePreview();
        var bounds = Screen.FromPoint(Cursor.Position).Bounds;
        if (!area && video) { StartRecording(bounds, bounds); return; }
        using var frame = CaptureUtilities.ReadScreen(bounds);
        if (!area) { SaveScreenshot(frame, bounds, false); return; }
        selection = new SelectionWindow((Bitmap)frame.Clone(), bounds, video);
        using var window = selection;
        try
        {
            if (window.ShowDialog() != DialogResult.OK) return;
            if (video) StartRecording(window.SelectedArea, bounds);
            else
            {
                using var annotated = window.RenderSelection();
                SaveScreenshot(annotated, bounds, window.CopyRequested);
            }
        }
        finally { selection = null; }
    });

    private void SaveScreenshot(Bitmap image, Rectangle screen, bool copy)
    {
        var extension = preferences.Format switch
        {
            ScreenshotFormat.Png => "png",
            ScreenshotFormat.Jpeg => "jpg",
            _ => "pdf"
        };
        string path = preferences.FilePath("Скриншот", extension);
        CaptureUtilities.SaveImage(image, path, preferences.Format);
        lastFile = path;
        bool copied = false;
        try
        {
            if (copy) { Clipboard.SetImage(image); copied = true; }
        }
        catch (System.Runtime.InteropServices.ExternalException error) { Report("Буфер обмена", error); }

        ShowPreview(path, image, screen, copied);
    }

    private void StartRecording(Rectangle region, Rectangle screen)
    {
        var path = preferences.FilePath("Запись экрана", "mp4");
        if (region != screen) shade = new RecordingShade(screen, region);
        try
        {
            recording = new RecordingSession(path, region, screen);
            tray.Icon = recordingIcon;
            tray.Text = "Мой Скриншот — запись экрана";
            _ = ObserveRecording(recording);
        }
        catch
        {
            shade?.Dispose();
            shade = null;
            throw;
        }
    }

    private async Task ObserveRecording(RecordingSession session)
    {
        try
        {
            using var thumbnail = await session.Completion;
            lastFile = session.Path;
            if (!quitting) ShowPreview(session.Path, thumbnail, session.Screen, false);
        }
        catch (Exception error) { Report("Не удалось записать экран", error); }
        finally
        {
            session.Dispose();
            if (recording == session) recording = null;
            shade?.Dispose();
            shade = null;
            stopping = false;
            tray.Icon = icon;
            tray.Text = Name;
        }
    }

    private async Task StopRecording()
    {
        if (recording is not { } session) return;
        if (!stopping)
        {
            stopping = true;
            session.Stop();
        }
        try { await session.Completion; }
        catch { /* ObserveRecording reports the failure. */ }
    }

    private void ShowPreview(string path, Bitmap image, Rectangle screen, bool copied)
    {
        ClosePreview();
        var current = new CapturePreview(path, image, Screen.FromRectangle(screen).WorkingArea, copied, !preferences.PreviewDragLearned);
        preview = current;
        current.FormClosed += (_, _) => { if (preview == current) preview = null; };
        current.Show();
        if (!preferences.PreviewDragLearned)
        {
            preferences.PreviewDragLearned = true;
            Run(preferences.Save);
        }
    }

    private void ClosePreview() { preview?.Close(); preview = null; }

    private void ShowSettings() => Run(() =>
    {
        using var window = new Form
        {
            Text = "Настройки — " + Name, ClientSize = new Size(535, 150),
            StartPosition = FormStartPosition.CenterScreen, FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false, MinimizeBox = false
        };
        var header = new Label { Text = "Папка для снимков и видео", AutoSize = true, Location = new Point(18, 20) };
        var path = new TextBox { Text = preferences.Folder, ReadOnly = true, Bounds = new Rectangle(18, 45, 497, 25) };
        var choose = new Button { Text = "Выбрать папку…", Bounds = new Rectangle(18, 88, 140, 31) };
        var reset = new Button { Text = "По умолчанию", Bounds = new Rectangle(170, 88, 140, 31), Enabled = preferences.CustomFolder is not null };
        choose.Click += (_, _) => Run(() =>
        {
            using var picker = new FolderBrowserDialog { Description = header.Text, SelectedPath = preferences.Folder, UseDescriptionForTitle = true };
            if (picker.ShowDialog(window) != DialogResult.OK) return;
            preferences.CustomFolder = picker.SelectedPath;
            preferences.Save();
            path.Text = preferences.Folder;
            reset.Enabled = true;
        });
        reset.Click += (_, _) => Run(() =>
        {
            preferences.CustomFolder = null;
            preferences.Save();
            path.Text = preferences.Folder;
            reset.Enabled = false;
        });
        window.Controls.AddRange([header, path, choose, reset]);
        window.ShowDialog();
    });

    private async Task Quit()
    {
        if (quitting) return;
        quitting = true;
        ClosePreview();
        selection?.Close();
        await StopRecording();
        ExitThread();
    }

    private void Run(Action action)
    {
        try { action(); }
        catch (Exception error) { Report(Name, error); }
    }

    private void Report(string title, Exception error)
    {
        Debug.WriteLine(error);
        tray.ShowBalloonTip(5000, title, error.Message, ToolTipIcon.Error);
    }

    protected override void ExitThreadCore()
    {
        tray.Visible = false;
        base.ExitThreadCore();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            hotKey.Dispose();
            tray.Dispose();
            menu.Dispose();
            icon.Dispose();
            recordingIcon.Dispose();
        }
        base.Dispose(disposing);
    }
}
