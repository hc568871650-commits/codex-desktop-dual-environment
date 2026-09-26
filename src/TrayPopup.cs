using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CodexDual {
    public sealed class TrayPopup : Form {
        const int EdgeGap = 8;
        const int CornerRadius = 8;
        Size? requestedSize;
        Color borderColor = Color.FromArgb(82, 82, 82);
        public Color BorderColor { get { return borderColor; } set { borderColor = value; Invalidate(); } }

        [DllImport("user32.dll")]
        static extern bool SetForegroundWindow(IntPtr handle);

        public TrayPopup() {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            KeyPreview = true;
            AutoScroll = true;
            BackColor = Color.FromArgb(34, 34, 34);
            ForeColor = Color.White;
            DoubleBuffered = true;
        }

        public Size PreferredPopupSize {
            get { return requestedSize ?? Size; }
            set { requestedSize = value; }
        }

        public static Rectangle CalculateBounds(Point anchor, Size desired, Rectangle workArea) {
            int marginX = Math.Min(EdgeGap, Math.Max(0, workArea.Width / 2));
            int marginY = Math.Min(EdgeGap, Math.Max(0, workArea.Height / 2));
            int width = Math.Min(Math.Max(1, desired.Width), Math.Max(1, workArea.Width - 2 * marginX));
            int height = Math.Min(Math.Max(1, desired.Height), Math.Max(1, workArea.Height - 2 * marginY));
            int right = workArea.Right - marginX - width;
            int bottom = workArea.Bottom - marginY - height;
            int x = anchor.X + EdgeGap + width <= workArea.Right - marginX
                ? anchor.X + EdgeGap : anchor.X - EdgeGap - width;
            int y = anchor.Y + EdgeGap + height <= workArea.Bottom - marginY
                ? anchor.Y + EdgeGap : anchor.Y - EdgeGap - height;
            x = Math.Max(workArea.Left + marginX, Math.Min(x, right));
            y = Math.Max(workArea.Top + marginY, Math.Min(y, bottom));
            return new Rectangle(x, y, width, height);
        }

        public void ShowAt(Point anchor, Rectangle workingArea) {
            if (IsDisposed) throw new ObjectDisposedException("TrayPopup");
            if (!requestedSize.HasValue) requestedSize = Size;
            Bounds = CalculateBounds(anchor, requestedSize.Value, workingArea);
            if (!Visible) Show();
            else BringToFront();
            Activate();
            SetForegroundWindow(Handle);
        }

        protected override void OnDeactivate(EventArgs e) {
            base.OnDeactivate(e);
            Hide();
        }

        protected override void OnFormClosing(FormClosingEventArgs e) {
            base.OnFormClosing(e);
            if (e.CloseReason == CloseReason.UserClosing) {
                e.Cancel = true;
                Hide();
            }
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
            Keys key = keyData & Keys.KeyCode;
            if (key == Keys.Escape) { Hide(); return true; }
            if (keyData == Keys.Down || keyData == Keys.Up ||
                keyData == Keys.Tab || keyData == (Keys.Shift | Keys.Tab)) {
                List<Button> buttons = new List<Button>();
                CollectButtons(this, buttons);
                if (buttons.Count == 0) return base.ProcessCmdKey(ref msg, keyData);
                int current = buttons.FindIndex(delegate(Button b) { return b.Focused || b.ContainsFocus; });
                if (current < 0) current = buttons.IndexOf(ActiveControl as Button);
                bool forward = keyData == Keys.Down || keyData == Keys.Tab;
                int next = current < 0 ? (forward ? 0 : buttons.Count - 1)
                    : (current + (forward ? 1 : -1) + buttons.Count) % buttons.Count;
                buttons[next].Select();
                return true;
            }
            if (keyData == Keys.Enter) {
                Button button = FindFocusedButton(this);
                if (button == null) button = ActiveControl as Button;
                if (button != null && button.Visible && button.Enabled) {
                    button.PerformClick();
                    return true;
                }
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        static void CollectButtons(Control parent, List<Button> buttons) {
            List<Control> children = new List<Control>();
            foreach (Control child in parent.Controls) children.Add(child);
            children.Sort(delegate(Control a, Control b) { return a.TabIndex.CompareTo(b.TabIndex); });
            foreach (Control child in children) {
                if (!child.Visible || !child.Enabled) continue;
                Button button = child as Button;
                if (button != null && button.TabStop) buttons.Add(button);
                CollectButtons(child, buttons);
            }
        }

        static Button FindFocusedButton(Control parent) {
            foreach (Control child in parent.Controls) {
                Button button = child as Button;
                if (button != null && button.Focused) return button;
                Button nested = FindFocusedButton(child);
                if (nested != null) return nested;
            }
            return null;
        }

        protected override void OnSizeChanged(EventArgs e) {
            base.OnSizeChanged(e);
            if (Width < 2 || Height < 2) return;
            int d = Math.Min(CornerRadius * 2, Math.Min(Width, Height));
            using (GraphicsPath path = new GraphicsPath()) {
                path.AddArc(0, 0, d, d, 180, 90);
                path.AddArc(Width - d, 0, d, d, 270, 90);
                path.AddArc(Width - d, Height - d, d, d, 0, 90);
                path.AddArc(0, Height - d, d, d, 90, 90);
                path.CloseFigure();
                Region old = Region;
                Region = new Region(path);
                if (old != null) old.Dispose();
            }
        }

        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (Pen border = new Pen(BorderColor)) {
                using (GraphicsPath path = new GraphicsPath()) {
                    int d = Math.Min(CornerRadius * 2, Math.Min(Width, Height));
                    if (d < 2) return;
                    path.AddArc(0, 0, d, d, 180, 90);
                    path.AddArc(Width - d - 1, 0, d, d, 270, 90);
                    path.AddArc(Width - d - 1, Height - d - 1, d, d, 0, 90);
                    path.AddArc(0, Height - d - 1, d, d, 90, 90);
                    path.CloseFigure();
                    e.Graphics.DrawPath(border, path);
                }
            }
        }
    }
}
