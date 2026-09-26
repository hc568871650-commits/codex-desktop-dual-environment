using System;
using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Collections;
using System.Windows.Forms;

namespace CodexDual {
    // No UI objects cross the runspace boundary. Poll only consumes completed work.
    public sealed class BackgroundWork : IDisposable {
        readonly Runspace runspace;
        PowerShell shell;
        IAsyncResult pending;
        RegisteredWaitHandle reportWait;
        public bool Busy { get { return pending != null; } }
        public bool Completed { get { return pending != null && pending.IsCompleted; } }
        public BackgroundWork() {
            runspace = RunspaceFactory.CreateRunspace();
            runspace.ApartmentState = ApartmentState.MTA;
            runspace.ThreadOptions = PSThreadOptions.ReuseThread;
            runspace.Open();
        }
        public void Start(string script, object[] arguments) {
            if (Busy) throw new InvalidOperationException("Work already pending.");
            // A failed PowerShell pipeline can retain output/invocation state.
            // Reuse the initialized runspace, but give each job its own pipeline.
            if (shell != null) shell.Dispose();
            shell = PowerShell.Create(); shell.Runspace = runspace;
            shell.AddScript(script);
            foreach (object argument in arguments) shell.AddArgument(argument);
            pending = shell.BeginInvoke();
        }
        public PSDataCollection<PSObject> Take() {
            if (!Completed) throw new InvalidOperationException("Work is not complete.");
            try {
                var result = shell.EndInvoke(pending);
                if (shell.Streams.Error.Count > 0) throw new InvalidOperationException(shell.Streams.Error[0].ToString());
                return result;
            } finally { pending = null; }
        }
        public void PresentReport(Form dialog, TextBox display, Button copy, Button save, IDictionary state) {
            var handle = dialog.Handle;
            Action apply = delegate {
                if (dialog.IsDisposed || !Completed) return;
                try {
                    var result = Take();
                    state["report"] = result[0].Properties["Report"].Value;
                    display.Text = Convert.ToString(result[0].Properties["Text"].Value);
                    copy.Enabled = save.Enabled = true;
                } catch (Exception error) {
                    state["error"] = error;
                    display.Text = "环境检查未完成，请稍后重试。";
                }
                state["done"] = true;
            };
            reportWait = ThreadPool.RegisterWaitForSingleObject(pending.AsyncWaitHandle, delegate(object unused, bool timedOut) {
                try { if (!dialog.IsDisposed) dialog.BeginInvoke(apply); }
                catch (InvalidOperationException) { /* Dialog closed before completion. */ }
            }, null, Timeout.Infinite, true);
        }
        public void Dispose() {
            if (reportWait != null) reportWait.Unregister(null);
            // A slow CIM provider must never hold up closing the controller UI.
            ThreadPool.QueueUserWorkItem(delegate {
                try { if (shell != null) shell.Stop(); } catch { }
                try { if (shell != null) shell.Dispose(); } finally { runspace.Dispose(); }
            });
        }
    }
}
