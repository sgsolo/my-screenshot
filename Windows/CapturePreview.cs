using System.Diagnostics;
using System.Drawing.Drawing2D;

namespace MyScreenshot;

internal sealed class CapturePreview : Form
{
    private readonly string path;
    private readonly Bitmap thumbnail;
    private readonly PictureBox picture;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 16 };
    private readonly Stopwatch clock = new();
    private readonly Point destination;
    private Point? pressed;
    private bool moved;
    private bool dismissing;
    private bool slide;

    public CapturePreview(string path, Bitmap image, Rectangle workArea, bool copied, bool showDragHelp)
    {
        this.path = path;
        double scale = Math.Min(170.0 / image.Width, 108.0 / image.Height);
        var imageSize = new Size(Math.Max(1, (int)(image.Width * scale)), Math.Max(1, (int)(image.Height * scale)));
        thumbnail = new Bitmap(image, imageSize);
        var pictureSize = new Size(Math.Max(60, imageSize.Width), Math.Max(44, imageSize.Height));
        bool notes = copied || showDragHelp;
        ClientSize = new Size(pictureSize.Width + 12 + (notes ? 232 : 0), Math.Max(pictureSize.Height + 12, notes ? 86 : 0));
        FormBorderStyle = FormBorderStyle.None;
        AutoScaleMode = AutoScaleMode.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Text = "Мой Скриншот";
        BackColor = Color.FromArgb(35, 39, 50);
        ForeColor = Color.White;

        picture = new PictureBox
        {
            Bounds = new Rectangle(ClientSize.Width - pictureSize.Width - 6, (ClientSize.Height - pictureSize.Height) / 2, pictureSize.Width, pictureSize.Height),
            Image = thumbnail, SizeMode = PictureBoxSizeMode.CenterImage, Cursor = Cursors.Hand,
            AccessibleName = "Открыть сохранённый файл"
        };
        picture.MouseDown += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            pressed = e.Location;
            moved = false;
            timer.Stop();
            picture.Capture = true;
        };
        picture.MouseMove += MoveThumbnail;
        picture.MouseUp += ReleaseThumbnail;
        picture.MouseWheel += (_, e) => { if (e.Delta < 0 && ModifierKeys.HasFlag(Keys.Shift)) Dismiss(true); };
        Controls.Add(picture);

        int y = 14;
        if (copied)
        {
            AddNote("Скопировано в буфер обмена", "Ctrl+V — вставить", y);
            y += 38;
        }
        if (showDragHelp) AddNote("Перетащите миниатюру", "В чат или другое приложение", y);

        using var outline = new GraphicsPath();
        outline.AddRoundedRectangle(new RectangleF(0, 0, ClientSize.Width, ClientSize.Height), new SizeF(9, 9));
        Region = new Region(outline);
        destination = new Point(workArea.Right - Width - 18, workArea.Bottom - Height - 18);
        Location = new Point(destination.X + 18, destination.Y);
        Opacity = 0.01;
        timer.Tick += (_, _) => Animate();
        Shown += (_, _) => { clock.Restart(); timer.Start(); };
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle |= 0x08000080;
            return parameters;
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x020E && unchecked((short)((long)message.WParam >> 16)) > 0) Dismiss(true);
        base.WndProc(ref message);
    }

    private void AddNote(string title, string detail, int y)
    {
        Controls.Add(new Label { Text = title, Location = new Point(12, y), Size = new Size(222, 19) });
        Controls.Add(new Label { Text = detail, Location = new Point(12, y + 18), Size = new Size(222, 18), ForeColor = Color.LightGray });
    }

    private void MoveThumbnail(object? sender, MouseEventArgs e)
    {
        if (pressed is not { } start || e.Button != MouseButtons.Left) return;
        int dx = e.X - start.X, dy = Math.Abs(e.Y - start.Y);
        if (Math.Abs(dx) + dy < 4) return;
        moved = true;
        if (dx >= dy && dx < 48 && picture.ClientRectangle.Contains(e.Location)) return;

        Point origin = picture.PointToScreen(start);
        pressed = null;
        picture.Capture = false;
        var data = new DataObject(DataFormats.FileDrop, new[] { path });
        var effect = picture.DoDragDrop(data, DragDropEffects.Copy);
        Point end = Cursor.Position;
        if (effect != DragDropEffects.None) Close();
        else if (end.X - origin.X >= 16 && end.X - origin.X > Math.Abs(end.Y - origin.Y) * 1.25) Dismiss(true);
        else RestartTimeout();
    }

    private void ReleaseThumbnail(object? sender, MouseEventArgs e)
    {
        if (pressed is not { } start) return;
        pressed = null;
        picture.Capture = false;
        int dx = e.X - start.X, dy = Math.Abs(e.Y - start.Y);
        if (dx >= 16 && dx > dy * 1.25) { Dismiss(true); return; }
        if (moved || !picture.ClientRectangle.Contains(e.Location)) { RestartTimeout(); return; }
        Close();
        try
        {
            CaptureUtilities.Reveal(path);
            CaptureUtilities.Open(path);
        }
        catch (Exception error) { MessageBox.Show(error.Message, "Мой Скриншот"); }
    }

    private void RestartTimeout()
    {
        clock.Restart();
        timer.Start();
    }

    private void Dismiss(bool moveRight)
    {
        if (dismissing) return;
        dismissing = true;
        slide = moveRight;
        clock.Restart();
        timer.Start();
    }

    private void Animate()
    {
        double elapsed = clock.Elapsed.TotalMilliseconds;
        if (dismissing)
        {
            double progress = elapsed / 175;
            if (progress >= 1) { Close(); return; }
            Opacity = 1 - progress;
            if (slide) Left = destination.X + (int)(Width * progress);
            return;
        }
        double fadeIn = Math.Clamp(elapsed / 200, 0.01, 1);
        Opacity = fadeIn;
        Left = destination.X + (int)(18 * (1 - fadeIn));
        if (elapsed >= 5000) Dismiss(false);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            timer.Dispose();
            thumbnail.Dispose();
        }
        base.Dispose(disposing);
    }
}
