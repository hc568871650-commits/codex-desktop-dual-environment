param([ValidateSet('dark','light')][string]$Theme='dark',[switch]$Expanded)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
Add-Type -Path @((Join-Path $source 'UiTheme.cs'),(Join-Path $source 'QuestionWindow.cs')) -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions
[Windows.Forms.Application]::EnableVisualStyles()
[void][CodexDual.AppTheme]::SetAppearance($Theme,'blue')
$request=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'config\question-preview.json'))
$window=New-Object CodexDual.QuestionWindow
$window.SetRequestJson($request)
$window.Text='提问界面预览'
$window.Controls.Find('QuestionContext',$true)[0].Text='界面预览 · 不会发送到任何任务'
$window.Add_SubmitRequested({param($sender,$e) $sender.SetSubmissionState($false,'这是界面预览，答案未发送。')})
$window.Add_ReturnRequested({param($sender,$e) $sender.SetSubmissionState($false,'这是界面预览，没有关联真实任务。')})
$context=New-Object Windows.Forms.ApplicationContext
$closeTimer=New-Object Windows.Forms.Timer;$closeTimer.Interval=100
$closeTimer.Add_Tick({if(-not $window.Visible){$closeTimer.Stop();$context.ExitThread()}})
try{
    $window.Show()
    if($Expanded){
        $area=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
        $window.ClientSize=New-Object Drawing.Size([Math]::Min(760,$area.Width),[Math]::Min(650,$area.Height))
        $window.Location=New-Object Drawing.Point(($area.Left+[int](($area.Width-$window.Width)/2)),($area.Top+[int](($area.Height-$window.Height)/2)))
    }
    $closeTimer.Start();[Windows.Forms.Application]::Run($context)
}finally{$closeTimer.Dispose();$window.Dispose();$context.Dispose()}
