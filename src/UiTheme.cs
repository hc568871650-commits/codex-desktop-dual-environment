using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using System.Runtime.InteropServices;

namespace CodexDual {
    public sealed class QuietMenu : ContextMenuStrip {
        public QuietMenu() {
            Renderer = new QuietMenuRenderer();
            BackColor = Color.FromArgb(250,250,249); ForeColor = Color.FromArgb(38,38,38);
            Font = new Font("Microsoft YaHei UI",10);
            ShowImageMargin = false; ShowCheckMargin = true;
            Padding = new Padding(6); MinimumSize = new Size(260,0);
        }
        protected override void OnItemAdded(ToolStripItemEventArgs e) {
            base.OnItemAdded(e);
            e.Item.Padding = e.Item is ToolStripSeparator ? new Padding(0,3,0,3) : new Padding(6,6,12,6);
        }
    }
    public sealed class QuietMenuRenderer : ToolStripProfessionalRenderer {
        public QuietMenuRenderer() { RoundedEdges = false; }
        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
            e.Graphics.Clear(Color.FromArgb(250,250,249));
        }
        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }
        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
            using(var pen=new Pen(Color.FromArgb(220,220,218))) e.Graphics.DrawRectangle(pen,0,0,e.ToolStrip.Width-1,e.ToolStrip.Height-1);
        }
        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
            if(!e.Item.Selected || !e.Item.Enabled) return;
            using(var brush=new SolidBrush(Color.FromArgb(234,234,232))) e.Graphics.FillRectangle(brush,new Rectangle(2,1,e.Item.Width-4,e.Item.Height-2));
        }
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
            e.TextColor=e.Item.Enabled ? Color.FromArgb(38,38,38) : Color.FromArgb(115,115,115);
            base.OnRenderItemText(e);
        }
        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
            using(var pen=new Pen(Color.FromArgb(226,226,224))) e.Graphics.DrawLine(pen,10,e.Item.Height/2,e.Item.Width-10,e.Item.Height/2);
        }
        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
            using(var pen=new Pen(Color.FromArgb(45,45,45),1.6f)) {
                var r=e.ImageRectangle;
                e.Graphics.DrawLines(pen,new[]{new Point(r.Left+3,r.Top+r.Height/2),new Point(r.Left+6,r.Bottom-4),new Point(r.Right-2,r.Top+3)});
            }
        }
    }
    public class ShellForm : Form {
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
        public ShellForm() { DoubleBuffered = true; }
        public void AddTitleBar() {
            FormBorderStyle = FormBorderStyle.None;
            foreach (Control child in Controls) child.Top += 36;
            ClientSize = new Size(ClientSize.Width, ClientSize.Height + 36);
            var title = new Panel { Name = "WindowCaption", Location = new Point(1,1), Size = new Size(ClientSize.Width-2,34), BackColor = BackColor, Anchor = AnchorStyles.Top|AnchorStyles.Left|AnchorStyles.Right };
            var caption = new Label { Text = "Codex", AutoSize = false, Location = new Point(16,5), Size = new Size(Width-130,25), ForeColor = Color.FromArgb(110,110,110), TextAlign = ContentAlignment.MiddleLeft };
            MouseEventHandler drag = delegate(object sender, MouseEventArgs e) { if(e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle,0xA1,new IntPtr(2),IntPtr.Zero); } };
            caption.MouseDown += drag; title.MouseDown += drag;
            var minimize = new QuietButton { Quiet = true, Text = "−", AccessibleName = "最小化", Location = new Point(Width-90,2), Size = new Size(40,29), TabStop = false, Anchor = AnchorStyles.Top|AnchorStyles.Right };
            var close = new QuietButton { Quiet = true, Text = "×", AccessibleName = "关闭并收起到托盘", Location = new Point(Width-47,2), Size = new Size(40,29), TabStop = false, Anchor = AnchorStyles.Top|AnchorStyles.Right };
            minimize.Click += delegate { WindowState = FormWindowState.Minimized; };
            close.Click += delegate { Close(); };
            title.Controls.Add(caption); title.Controls.Add(minimize); title.Controls.Add(close); Controls.Add(title);
        }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            using(var pen = new Pen(Color.FromArgb(215,215,215))) e.Graphics.DrawRectangle(pen,0,0,Width-1,Height-1);
        }
    }
    public class Surface : Panel {
        public Surface() { DoubleBuffered = true; ResizeRedraw = true; BackColor = Color.White; }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            using (var pen = new Pen(Color.FromArgb(229,229,229)))
                e.Graphics.DrawRectangle(pen, 0, 0, Width-1, Height-1);
        }
    }
    public class QuietButton : Button {
        bool hover, pressed;
        public bool Primary { get; set; }
        public bool Quiet { get; set; }
        public QuietButton() {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
            Cursor = Cursors.Hand; UseVisualStyleBackColor = false;
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { pressed = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnPaint(PaintEventArgs e) {
            e.Graphics.Clear(Parent == null ? Color.White : Parent.BackColor);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            int d = Math.Min(16, Height-2);
            Rectangle r = new Rectangle(1,1,Width-3,Height-3);
            using (var path = new GraphicsPath()) {
                path.AddArc(r.Left,r.Top,d,d,180,90); path.AddArc(r.Right-d,r.Top,d,d,270,90);
                path.AddArc(r.Right-d,r.Bottom-d,d,d,0,90); path.AddArc(r.Left,r.Bottom-d,d,d,90,90); path.CloseFigure();
                var fill = !Enabled ? Color.FromArgb(245,245,245) : Primary ? Color.FromArgb(pressed ? 70 : hover ? 55 : 32,pressed ? 70 : hover ? 55 : 32,pressed ? 70 : hover ? 55 : 32) : Color.FromArgb(pressed ? 231 : hover ? 242 : 255,pressed ? 231 : hover ? 242 : 255,pressed ? 231 : hover ? 242 : 255);
                if (Quiet && !hover && !pressed && Parent != null) fill = Parent.BackColor;
                using (var brush = new SolidBrush(fill)) e.Graphics.FillPath(brush,path);
                if (!Quiet) using (var pen = new Pen(Focused ? Color.FromArgb(100,100,100) : Primary && Enabled ? fill : Color.FromArgb(222,222,222))) e.Graphics.DrawPath(pen,path);
            }
            TextRenderer.DrawText(e.Graphics,Text,Font,r,!Enabled ? SystemColors.GrayText : Primary ? Color.White : Color.FromArgb(38,38,38),TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics,new Rectangle(6,6,Width-12,Height-12));
        }
    }
}
