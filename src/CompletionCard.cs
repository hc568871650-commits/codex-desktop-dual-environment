using System.Windows.Forms;
namespace CodexDual {
 public sealed class CompletionCard : Form {
  // A completion should not interrupt typing in another application.
  protected override bool ShowWithoutActivation { get { return true; } }
 }
}
