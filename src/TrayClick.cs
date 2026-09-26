using System;
using System.Diagnostics;
using System.Windows.Forms;

namespace CodexDual {
    // Feed NotifyIcon.MouseDown only. MouseDoubleClick is already represented by its second MouseDown.
    public sealed class TrayClick : IDisposable {
        private readonly Timer timer;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private readonly int interval;
        private long firstDown;
        private bool pending;
        private bool disposed;

        public event EventHandler SingleClick;
        public event EventHandler DoubleClick;

        public int Interval { get { return interval; } }

        public TrayClick() : this(Math.Max(SystemInformation.DoubleClickTime, 550) + 75) { }

        // An explicit interval is useful for deterministic, fast UI-message-loop tests.
        public TrayClick(int intervalMilliseconds) {
            if (intervalMilliseconds < 1) throw new ArgumentOutOfRangeException("intervalMilliseconds");
            interval = intervalMilliseconds;
            timer = new Timer();
            timer.Tick += OnTick;
        }

        public void HandleMouseDown(MouseButtons button) {
            if (disposed) return;
            if (button != MouseButtons.Left) {
                Cancel();
                return;
            }

            long now = clock.ElapsedMilliseconds;
            if (pending) {
                bool isDouble = now - firstDown <= interval;
                Cancel();
                if (isDouble) {
                    EventHandler handler = DoubleClick;
                    if (handler != null) handler(this, EventArgs.Empty);
                    return;
                }
                EventHandler single = SingleClick;
                if (single != null) single(this, EventArgs.Empty);
                if (disposed || pending) return;
                now = clock.ElapsedMilliseconds;
            }
            firstDown = now;
            pending = true;
            timer.Interval = interval;
            timer.Start();
        }

        private void OnTick(object sender, EventArgs e) {
            if (!pending || disposed) return;
            long remaining = interval - (clock.ElapsedMilliseconds - firstDown);
            if (remaining > 0) {
                timer.Interval = (int)Math.Min(remaining, int.MaxValue);
                return;
            }
            Cancel();
            EventHandler handler = SingleClick;
            if (handler != null) handler(this, EventArgs.Empty);
        }

        private void Cancel() {
            pending = false;
            timer.Stop();
        }

        public void Dispose() {
            if (disposed) return;
            disposed = true;
            Cancel();
            timer.Tick -= OnTick;
            timer.Dispose();
        }
    }
}
