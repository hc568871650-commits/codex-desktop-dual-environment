using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace CodexDual.App;

internal static class ModernStyle
{
    public static Color Canvas => AppTheme.IsDark ? Color.FromArgb(24, 24, 24) : Color.FromArgb(250, 250, 250);
    public static Color Side => AppTheme.IsDark ? Color.FromArgb(31, 31, 31) : Color.FromArgb(242, 242, 242);
    public static Color Field => AppTheme.IsDark ? Color.FromArgb(38, 38, 38) : Color.FromArgb(239, 239, 239);
    public static Color Line => AppTheme.IsDark ? Color.FromArgb(54, 54, 54) : Color.FromArgb(224, 224, 224);
    public static Color ButtonBorder => AppTheme.IsDark ? Color.FromArgb(78, 78, 78) : Color.FromArgb(204, 204, 204);
    public static Color Divider => AppTheme.IsDark ? Color.FromArgb(58, 58, 58) : Color.FromArgb(222, 222, 222);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] private static extern int SetWindowTheme(IntPtr window, string? app, string? id);
    public static void NativeTheme(Control control) { if (control.IsHandleCreated) SetWindowTheme(control.Handle, AppTheme.IsDark ? "DarkMode_Explorer" : "Explorer", null); }
    public static void Apply(Control control)
    {
        if (control.Name == "Sidebar") control.BackColor = Side;
        else if (control is SoftSurface or ModernList or InputFrame) control.BackColor = Field;
        else if (control is TextBoxBase) control.BackColor = Field;
        else if (control is Label or Panel or Form) control.BackColor = control.Parent?.BackColor ?? Canvas;
        control.ForeColor = control.Name == "Muted" ? AppTheme.Muted : AppTheme.Text;
        if (control is ModernList) NativeTheme(control);
        foreach (Control child in control.Controls) Apply(child);
        control.Invalidate();
    }
    public static void Fill(Graphics g, Rectangle bounds, Color color, int radius = 12)
    { using var shape = AppTheme.Round(bounds, radius); using var brush = new SolidBrush(color); g.FillPath(brush, shape); }
}

internal sealed class ActionButton : QuietButton
{
    private bool hover, down;
    protected override void OnMouseEnter(EventArgs e) { hover = true; base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = down = false; base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = e.Button == MouseButtons.Left; base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; base.OnMouseUp(e); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.Clear(Parent?.BackColor ?? ModernStyle.Canvas); g.SmoothingMode = SmoothingMode.AntiAlias;
        var bounds = new Rectangle(1, 1, Width - 3, Height - 3);
        Color fill = Primary ? AppTheme.Primary : Selected ? AppTheme.Selected : ModernStyle.Field;
        if (hover || down) fill = Primary ? down ? AppTheme.PrimaryPressed : AppTheme.PrimaryHover : down ? AppTheme.Pressed : AppTheme.Hover;
        if (!Quiet || hover || down || Selected) ModernStyle.Fill(g, bounds, fill);
        using (var shape = AppTheme.Round(bounds, 12))
        using (var border = new Pen(hover || Selected ? AppTheme.Muted : ModernStyle.ButtonBorder)) g.DrawPath(border, shape);
        if (Focused && ShowFocusCues) { using var shape = AppTheme.Round(bounds, 12); using var pen = new Pen(AppTheme.Focus); g.DrawPath(pen, shape); }
        var textBounds = Rectangle.Inflate(bounds, Width < 64 ? -3 : -14, 0);
        var flags = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | (TextAlign == ContentAlignment.MiddleLeft ? TextFormatFlags.Left : TextFormatFlags.HorizontalCenter);
        TextRenderer.DrawText(g, Text, Font, textBounds, !Enabled ? AppTheme.Disabled : Primary ? AppTheme.PrimaryText : AppTheme.Text, flags);
    }
}

internal sealed class SoftSurface : Panel
{
    public SoftSurface() { DoubleBuffered = true; ResizeRedraw = true; Padding = new Padding(16); }
    protected override void OnPaintBackground(PaintEventArgs e)
    { e.Graphics.Clear(Parent?.BackColor ?? ModernStyle.Canvas); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias; ModernStyle.Fill(e.Graphics, new Rectangle(0, 0, Width - 1, Height - 1), BackColor, 16); }
}

internal sealed class InputFrame : Panel
{
    public TextBox Input { get; }
    public InputFrame(TextBox input)
    {
        DoubleBuffered = true; ResizeRedraw = true; Height = 48; Input = input;
        input.BorderStyle = BorderStyle.None; input.AutoSize = false; input.TabIndex = 0;
        Controls.Add(input); input.GotFocus += (_, _) => Invalidate(); input.LostFocus += (_, _) => Invalidate();
        Resize += (_, _) => Arrange(); Click += (_, _) => input.Focus();
    }
    private void Arrange() { Input.SetBounds(15, Math.Max(8, (Height - Input.PreferredHeight) / 2), Math.Max(10, Width - 30), Input.PreferredHeight + 2); }
    protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); if (Input != null) Arrange(); }
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        var g = e.Graphics; g.Clear(Parent?.BackColor ?? ModernStyle.Canvas); g.SmoothingMode = SmoothingMode.AntiAlias;
        var bounds = new Rectangle(1, 1, Width - 3, Height - 3); ModernStyle.Fill(g, bounds, ModernStyle.Field);
        using var shape = AppTheme.Round(bounds, 12); using var pen = new Pen(Input.Focused ? AppTheme.Focus : ModernStyle.Line); g.DrawPath(pen, shape);
    }
}

internal sealed class ModernList : ListBox
{
    public ModernList() { BorderStyle = BorderStyle.None; DrawMode = DrawMode.OwnerDrawFixed; ItemHeight = 48; IntegralHeight = false; HorizontalScrollbar = false; }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); ModernStyle.NativeTheme(this); }
    protected override void OnDrawItem(DrawItemEventArgs e)
    {
        if (e.Index < 0) return;
        using (var brush = new SolidBrush(ModernStyle.Field)) e.Graphics.FillRectangle(brush, e.Bounds);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var bounds = Rectangle.Inflate(e.Bounds, -4, -3);
        if ((e.State & DrawItemState.Selected) != 0) ModernStyle.Fill(e.Graphics, bounds, AppTheme.Selected, 9);
        bounds.Inflate(-12, 0);
        string text = (GetItemText(Items[e.Index]) ?? "").Replace('\r', ' ').Replace('\n', ' ');
        TextRenderer.DrawText(e.Graphics, text, Font, bounds, AppTheme.Text, TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }
}

internal sealed class ModernToggle : CheckBox
{
    public ModernToggle() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); AutoSize = false; Cursor = Cursors.Hand; Height = 48; }
    protected override void OnCheckedChanged(EventArgs e) { base.OnCheckedChanged(e); Invalidate(); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.Clear(Parent?.BackColor ?? ModernStyle.Canvas); g.SmoothingMode = SmoothingMode.AntiAlias;
        int x = Width - 48, y = (Height - 26) / 2;
        ModernStyle.Fill(g, new Rectangle(x, y, 46, 26), Checked ? AppTheme.Primary : AppTheme.Border, 13);
        using (var brush = new SolidBrush(Checked ? AppTheme.PrimaryText : AppTheme.Text)) g.FillEllipse(brush, x + (Checked ? 23 : 3), y + 3, 20, 20);
        TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width - 66, Height), Enabled ? AppTheme.Text : AppTheme.Disabled, TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        if (Focused && ShowFocusCues) { using var p = new Pen(AppTheme.Focus); g.DrawLine(p, 0, Height - 2, Width, Height - 2); }
    }
}

internal sealed class ChoicePicker : Control
{
    private readonly (string Value, string Label)[] choices;
    private int selected;
    private QuietMenu? popup;
    internal ContextMenuStrip? DropDown => popup;
    public string Value { get => choices[selected].Value; set { int index = Array.FindIndex(choices, c => c.Value == value); if (index >= 0) selected = index; Invalidate(); } }
    public event EventHandler? ValueChanged;
    public ChoicePicker(params (string Value, string Label)[] choices)
    { this.choices = choices; SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Selectable, true); TabStop = true; Cursor = Cursors.Hand; Size = new Size(240, 46); AccessibleRole = AccessibleRole.ComboBox; }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(Parent?.BackColor ?? ModernStyle.Canvas); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        ModernStyle.Fill(e.Graphics, new Rectangle(0, 0, Width - 1, Height - 1), ModernStyle.Field);
        using (var shape = AppTheme.Round(new Rectangle(1, 1, Width - 3, Height - 3), 12))
        using (var border = new Pen(ModernStyle.ButtonBorder)) e.Graphics.DrawPath(border, shape);
        TextRenderer.DrawText(e.Graphics, choices[selected].Label, Font, new Rectangle(16, 0, Width - 52, Height), AppTheme.Text, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        using var p = new Pen(AppTheme.Muted, 1.5f); int y = Height / 2; e.Graphics.DrawLines(p, [new(Width - 29, y - 2), new(Width - 24, y + 3), new(Width - 19, y - 2)]);
        if (Focused && ShowFocusCues) { using var shape = AppTheme.Round(new Rectangle(1, 1, Width - 3, Height - 3), 12); using var focus = new Pen(AppTheme.Focus); e.Graphics.DrawPath(focus, shape); }
    }
    protected override void OnClick(EventArgs e)
    {
        base.OnClick(e); OpenDropDown();
    }
    internal void OpenDropDown()
    {
        if (IsDisposed || Disposing || !Enabled) return;
        Focus();
        if (popup == null)
        {
            popup = new QuietMenu();
            for (int n = 0; n < choices.Length; n++)
            {
                int index = n;
                var item = new ToolStripMenuItem(choices[n].Label) { Tag = choices[n].Value };
                item.Click += (_, _) => Select(index); popup.Items.Add(item); item.Padding = new Padding(10);
            }
        }
        popup.Font = Font; popup.MinimumSize = new Size(Width, 0);
        for (int n = 0; n < popup.Items.Count; n++) ((ToolStripMenuItem)popup.Items[n]).Checked = n == selected;
        AppTheme.ApplyTo(popup);
        popup.Show(this, new Point(0, Height + 4));
    }
    protected override void Dispose(bool disposing)
    {
        // Closed fires before ToolStrip has finished processing the click.
        // Keep the menu alive until its owning picker is disposed.
        if (disposing) { popup?.Dispose(); popup = null; }
        base.Dispose(disposing);
    }
    private void Select(int index) { if (selected == index) return; selected = index; Invalidate(); ValueChanged?.Invoke(this, EventArgs.Empty); }
    protected override bool IsInputKey(Keys keyData) => keyData is Keys.Up or Keys.Down || base.IsInputKey(keyData);
    protected override void OnKeyDown(KeyEventArgs e) { base.OnKeyDown(e); if (e.KeyCode == Keys.Down) Select(Math.Min(choices.Length - 1, selected + 1)); else if (e.KeyCode == Keys.Up) Select(Math.Max(0, selected - 1)); else if (e.KeyCode is Keys.Space or Keys.Enter) OnClick(EventArgs.Empty); }
}

internal sealed class DurationPicker : Control
{
    private int value;
    public int Value { get => value; set { this.value = Math.Clamp(value, 0, 3600); Invalidate(); ValueChanged?.Invoke(this, EventArgs.Empty); } }
    public event EventHandler? ValueChanged;
    public DurationPicker() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Selectable, true); TabStop = true; Cursor = Cursors.Hand; AccessibleRole = AccessibleRole.SpinButton; Size = new Size(240, 46); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.Clear(Parent?.BackColor ?? ModernStyle.Canvas); g.SmoothingMode = SmoothingMode.AntiAlias; ModernStyle.Fill(g, new Rectangle(0, 0, Width - 1, Height - 1), ModernStyle.Field);
        using (var shape = AppTheme.Round(new Rectangle(1, 1, Width - 3, Height - 3), 12))
        using (var border = new Pen(ModernStyle.ButtonBorder)) g.DrawPath(border, shape);
        using (var divider = new Pen(ModernStyle.Divider)) { g.DrawLine(divider, 46, 10, 46, Height - 10); g.DrawLine(divider, Width - 46, 10, Width - 46, Height - 10); }
        var flags = TextFormatFlags.SingleLine | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter;
        TextRenderer.DrawText(g, "−", Font, new Rectangle(0, 0, 46, Height), AppTheme.Muted, flags);
        TextRenderer.DrawText(g, value == 0 ? "常驻" : value + " 秒", Font, new Rectangle(46, 0, Width - 92, Height), AppTheme.Text, flags);
        TextRenderer.DrawText(g, "+", Font, new Rectangle(Width - 46, 0, 46, Height), AppTheme.Muted, flags);
    }
    protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); Focus(); if (e.X < 48) Value--; else if (e.X > Width - 48) Value++; }
    protected override bool IsInputKey(Keys keyData) => keyData is Keys.Up or Keys.Down or Keys.Left or Keys.Right || base.IsInputKey(keyData);
    protected override void OnKeyDown(KeyEventArgs e) { base.OnKeyDown(e); if (e.KeyCode is Keys.Up or Keys.Right) Value++; else if (e.KeyCode is Keys.Down or Keys.Left) Value--; }
}

internal sealed class Hairline : Control
{
    public Hairline() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); Height = 1; TabStop = false; }
    protected override void OnPaint(PaintEventArgs e) { e.Graphics.Clear(ModernStyle.Divider); }
}
