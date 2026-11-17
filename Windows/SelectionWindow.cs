using System.Drawing.Drawing2D;
using System.Globalization;
using System.Drawing.Imaging;

namespace MyScreenshot;

internal sealed class SelectionWindow : Form
{
    private enum Tool { Arrow, Pen, Line, Rectangle, Ellipse, Text, Eraser }
    [Flags]
    private enum Edge { None = 0, Left = 1, Top = 2, Right = 4, Bottom = 8 }

    private readonly Bitmap frame;
    private readonly Rectangle display;
    private readonly bool video;
    private readonly int minimum;
    private readonly List<Rectangle> windows;
    private readonly ToolStrip toolbar = new() { GripStyle = ToolStripGripStyle.Hidden, Dock = DockStyle.None, CanOverflow = false };
    private readonly ToolStripTextBox input = new() { Width = 145, Visible = false };
    private readonly ToolStripLabel dimensions = new();
    private readonly Dictionary<Tool, ToolStripButton> tools = new();
    private readonly List<Annotation> annotations = new();
    private Rectangle selected;
    private Rectangle suggestion;
    private Rectangle original;
    private Point pressed;
    private Tool choice = Tool.Arrow;
    private Color color = Color.FromArgb(245, 56, 60);
    private Annotation? drawing;
    private Edge resizing;
    private bool selecting;
    private bool moving;

    public SelectionWindow(Bitmap frame, Rectangle display, bool video)
    {
        this.frame = frame;
        this.display = display;
        this.video = video;
        minimum = video ? 32 : 8;
        (windows, var focused) = Native.WindowBounds(display);
        var cursor = new Point(Cursor.Position.X - display.X, Cursor.Position.Y - display.Y);
        suggestion = focused.Contains(cursor) ? focused : WindowAt(cursor);

        StartPosition = FormStartPosition.Manual;
        FormBorderStyle = FormBorderStyle.None;
        AutoScaleMode = AutoScaleMode.None;
        Bounds = display;
        TopMost = true;
        ShowInTaskbar = false;
        DoubleBuffered = true;
        KeyPreview = true;

        if (!video)
        {
            AddTool(Tool.Arrow, "➜", "Стрелка");
            AddTool(Tool.Pen, "✎", "Карандаш");
            AddTool(Tool.Line, "╱", "Линия");
            AddTool(Tool.Rectangle, "□", "Прямоугольник");
            AddTool(Tool.Ellipse, "○", "Эллипс");
            AddTool(Tool.Text, "T", "Текст");
            AddTool(Tool.Eraser, "⌫", "Ластик");
            var colors = new ToolStripDropDownButton("●") { ForeColor = color, ToolTipText = "Цвет" };
            foreach (var (label, value) in new[] { ("Красный", color), ("Синий", Color.RoyalBlue), ("Зелёный", Color.SeaGreen), ("Белый", Color.White), ("Чёрный", Color.Black) })
            {
                var item = colors.DropDownItems.Add(label);
                item.Click += (_, _) => { color = value; colors.ForeColor = value; };
            }
            toolbar.Items.Add(colors);
            toolbar.Items.Add(input);
            toolbar.Items.Add(new ToolStripButton("↶") { ToolTipText = "Отменить действие" });
            toolbar.Items[toolbar.Items.Count - 1].Click += (_, _) =>
            {
                if (annotations.Count > 0) { annotations.RemoveAt(annotations.Count - 1); Invalidate(); }
            };
        }
        toolbar.Items.Add(dimensions);
        var cancel = toolbar.Items.Add("✕");
        cancel.ToolTipText = "Отмена";
        cancel.Click += (_, _) => Close();
        var saveTitle = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru" ? "Сохранить" : "Save";
        var save = toolbar.Items.Add(video ? "●" : saveTitle);
        save.ToolTipText = video ? "Начать запись" : saveTitle;
        save.Click += (_, _) => Commit(false);
        toolbar.Visible = false;
        Controls.Add(toolbar);
    }

    public Rectangle SelectedArea => new(display.X + selected.X, display.Y + selected.Y, selected.Width, selected.Height);
    public bool CopyRequested { get; private set; }

    public Bitmap RenderSelection()
    {
        var bitmap = frame.Clone(selected, PixelFormat.Format32bppRgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.TranslateTransform(-selected.X, -selected.Y);
        PaintAnnotations(graphics);
        return bitmap;
    }

    private void AddTool(Tool tool, string symbol, string name)
    {
        var button = new ToolStripButton(symbol) { ToolTipText = name, AccessibleName = name, Checked = choice == tool };
        button.Click += (_, _) =>
        {
            choice = tool;
            foreach (var (key, item) in tools) item.Checked = key == tool;
            input.Visible = tool == Tool.Text;
            LayoutToolbar();
            if (tool == Tool.Text) input.Focus();
        };
        tools.Add(tool, button);
        toolbar.Items.Add(button);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.DrawImageUnscaled(frame, 0, 0);
        var region = selected.IsEmpty ? suggestion : selected;
        using var shade = new Region(ClientRectangle);
        shade.Exclude(region);
        using var dark = new SolidBrush(Color.FromArgb(87, Color.Black));
        e.Graphics.FillRegion(dark, shade);
        if (!selected.IsEmpty)
        {
            var state = e.Graphics.Save();
            e.Graphics.SetClip(selected);
            PaintAnnotations(e.Graphics);
            e.Graphics.Restore(state);
            e.Graphics.DrawRectangle(Pens.White, selected.X, selected.Y, selected.Width - 1, selected.Height - 1);
            if (!selecting)
            {
                foreach (var point in Handles())
                {
                    e.Graphics.FillEllipse(Brushes.White, point.X - 4, point.Y - 4, 8, 8);
                    e.Graphics.DrawEllipse(Pens.Gray, point.X - 4, point.Y - 4, 8, 8);
                }
            }
        }
        else if (!suggestion.IsEmpty)
        {
            using var border = new Pen(Color.DodgerBlue, 2) { DashStyle = DashStyle.Dash };
            e.Graphics.DrawRectangle(border, suggestion);
        }
    }

    private void PaintAnnotations(Graphics graphics)
    {
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        foreach (var annotation in annotations) annotation.Paint(graphics);
        drawing?.Paint(graphics);
    }

    private IEnumerable<Point> Handles()
    {
        int cx = selected.X + selected.Width / 2, cy = selected.Y + selected.Height / 2;
        yield return selected.Location;
        yield return new(selected.Right, selected.Top);
        yield return new(selected.Left, selected.Bottom);
        yield return new(selected.Right, selected.Bottom);
        yield return new(cx, selected.Top);
        yield return new(cx, selected.Bottom);
        yield return new(selected.Left, cy);
        yield return new(selected.Right, cy);
    }

    private Edge EdgeAt(Point point)
    {
        if (selected.IsEmpty || !Rectangle.Inflate(selected, 7, 7).Contains(point)) return Edge.None;
        var horizontal = Math.Abs(point.X - selected.Left) <= 7 ? Edge.Left :
                         Math.Abs(point.X - selected.Right) <= 7 ? Edge.Right : Edge.None;
        var vertical = Math.Abs(point.Y - selected.Top) <= 7 ? Edge.Top :
                       Math.Abs(point.Y - selected.Bottom) <= 7 ? Edge.Bottom : Edge.None;
        return horizontal | vertical;
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Right) { Close(); return; }
        if (e.Button != MouseButtons.Left) return;
        pressed = e.Location;
        original = selected;
        resizing = EdgeAt(pressed);
        Capture = true;
        if (resizing != Edge.None) { toolbar.Visible = false; return; }
        moving = selected.Contains(pressed) && (video || ModifierKeys.HasFlag(Keys.Alt));
        if (moving) { toolbar.Visible = false; return; }
        if (!selected.Contains(pressed))
        {
            selecting = true;
            toolbar.Visible = false;
            return;
        }
        if (video) return;
        if (choice == Tool.Eraser) { Erase(e.Location); return; }
        if (choice == Tool.Text)
        {
            if (!string.IsNullOrWhiteSpace(input.Text))
                annotations.Add(new Annotation(choice, color, e.Location, input.Text.Trim()));
            Invalidate();
            return;
        }
        drawing = new Annotation(choice, color, e.Location);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var point = new Point(Math.Clamp(e.X, 0, ClientSize.Width), Math.Clamp(e.Y, 0, ClientSize.Height));
        if (e.Button == MouseButtons.Left && Capture)
        {
            if (resizing != Edge.None) ResizeSelection(point);
            else if (moving)
            {
                selected.X = Math.Clamp(original.X + point.X - pressed.X, 0, ClientSize.Width - selected.Width);
                selected.Y = Math.Clamp(original.Y + point.Y - pressed.Y, 0, ClientSize.Height - selected.Height);
            }
            else if (selecting && (selected != original || Math.Abs(point.X - pressed.X) + Math.Abs(point.Y - pressed.Y) >= 4))
                selected = BoundingBox(pressed, point);
            else if (drawing is not null) drawing.Extend(point);
            else if (choice == Tool.Eraser && selected.Contains(point)) Erase(point);
            Invalidate();
        }
        else
        {
            if (selected.IsEmpty) { suggestion = WindowAt(point); Invalidate(); }
            Cursor = EdgeAt(point) switch
            {
                Edge.Left or Edge.Right => Cursors.SizeWE,
                Edge.Top or Edge.Bottom => Cursors.SizeNS,
                Edge.Left | Edge.Top or Edge.Right | Edge.Bottom => Cursors.SizeNWSE,
                Edge.Right | Edge.Top or Edge.Left | Edge.Bottom => Cursors.SizeNESW,
                _ => Cursors.Cross
            };
        }
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        Capture = false;
        if (selecting && selected == original)
        {
            var candidate = WindowAt(e.Location);
            if (!candidate.IsEmpty) selected = candidate;
        }
        if (selected.Width < minimum || selected.Height < minimum) selected = original;
        if (selecting && selected != original) annotations.Clear();
        if (drawing is not null)
        {
            drawing.Extend(e.Location);
            annotations.Add(drawing);
            drawing = null;
        }
        selecting = false;
        moving = false;
        resizing = Edge.None;
        LayoutToolbar();
        Invalidate();
    }

    private void ResizeSelection(Point point)
    {
        int left = original.Left, right = original.Right, top = original.Top, bottom = original.Bottom;
        if (resizing.HasFlag(Edge.Left)) left = Math.Min(point.X, right - minimum);
        if (resizing.HasFlag(Edge.Right)) right = Math.Max(point.X, left + minimum);
        if (resizing.HasFlag(Edge.Top)) top = Math.Min(point.Y, bottom - minimum);
        if (resizing.HasFlag(Edge.Bottom)) bottom = Math.Max(point.Y, top + minimum);
        selected = Rectangle.FromLTRB(left, top, right, bottom);
    }

    private void LayoutToolbar()
    {
        toolbar.Visible = !selected.IsEmpty;
        if (!toolbar.Visible) return;
        dimensions.Text = $"{selected.Width} × {selected.Height}";
        var size = toolbar.GetPreferredSize(Size.Empty);
        toolbar.Size = size;
        int y = selected.Bottom + 8;
        if (y + size.Height > ClientSize.Height && !video) y = selected.Top - size.Height - 8;
        toolbar.Location = new Point(Math.Clamp((selected.Left + selected.Right - size.Width) / 2, 0, Math.Max(0, ClientSize.Width - size.Width)),
            Math.Clamp(y, 0, Math.Max(0, ClientSize.Height - size.Height)));
    }

    private void Erase(Point point)
    {
        var hit = annotations.FindLastIndex(item => item.Hit(point));
        if (hit >= 0) annotations.RemoveAt(hit);
        Invalidate();
    }

    private Rectangle WindowAt(Point point) => windows.Find(window => window.Contains(point));

    private void Commit(bool copy)
    {
        if (selected.IsEmpty && !suggestion.IsEmpty) selected = suggestion;
        if (selected.Width < minimum || selected.Height < minimum) return;
        CopyRequested = copy;
        DialogResult = DialogResult.OK;
        Close();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { Close(); return true; }
        if (keyData == Keys.Enter) { Commit(false); return true; }
        if (!video && keyData == (Keys.Control | Keys.C) && !input.Focused)
        {
            Commit(true);
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) frame.Dispose();
        base.Dispose(disposing);
    }

    private static Rectangle BoundingBox(Point start, Point end) =>
        Rectangle.FromLTRB(Math.Min(start.X, end.X), Math.Min(start.Y, end.Y),
            Math.Max(start.X, end.X), Math.Max(start.Y, end.Y));

    private sealed class Annotation(Tool tool, Color color, Point start, string? text = null)
    {
        private readonly List<Point> points = [start];
        private Point Last => points[^1];

        public void Extend(Point point)
        {
            if (tool == Tool.Pen || points.Count == 1) points.Add(point);
            else points[1] = point;
        }

        public void Paint(Graphics graphics)
        {
            using var brush = new SolidBrush(color);
            if (tool == Tool.Text)
            {
                using var font = new Font("Segoe UI", 22, FontStyle.Bold, GraphicsUnit.Pixel);
                graphics.DrawString(text, font, brush, start);
                return;
            }
            using var pen = new Pen(color, 4) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            if (tool == Tool.Arrow)
            {
                using var cap = new AdjustableArrowCap(4, 5);
                pen.CustomEndCap = cap;
                graphics.DrawLine(pen, start, Last);
            }
            else if (tool == Tool.Pen && points.Count > 1) graphics.DrawLines(pen, points.ToArray());
            else if (tool == Tool.Line) graphics.DrawLine(pen, start, Last);
            else if (tool == Tool.Rectangle) graphics.DrawRectangle(pen, BoundingBox(start, Last));
            else if (tool == Tool.Ellipse) graphics.DrawEllipse(pen, BoundingBox(start, Last));
        }

        public bool Hit(Point point)
        {
            if (tool == Tool.Text) return new Rectangle(start.X - 4, start.Y - 4, Math.Max(26, (text?.Length ?? 1) * 15), 32).Contains(point);
            using var path = new GraphicsPath();
            var bounds = BoundingBox(start, Last);
            if (tool == Tool.Rectangle && !bounds.IsEmpty) path.AddRectangle(bounds);
            else if (tool == Tool.Ellipse && bounds.Width > 0 && bounds.Height > 0) path.AddEllipse(bounds);
            else if (tool == Tool.Pen && points.Count > 1) path.AddLines(points.ToArray());
            else path.AddLine(start, Last);
            using var target = new Pen(Color.Black, 16);
            return path.IsOutlineVisible(point, target);
        }
    }
}
