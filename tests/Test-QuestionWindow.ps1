$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing,System.Web.Extensions
if(-not ('CodexDual.QuestionWindow' -as [type])) {
    Add-Type -Path @("$PSScriptRoot\..\src\UiTheme.cs","$PSScriptRoot\..\src\QuestionWindow.cs") -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions
}
[Windows.Forms.Application]::EnableVisualStyles()
$script:passed=0
$script:submitted=0
$script:returned=0
function Check($condition,[string]$message) {
    if(-not $condition){throw "FAIL: $message"}
    $script:passed++
    Write-Output "PASS: $message"
}
function Find-Control($root,[string]$name) {
    $result=$root.Controls.Find($name,$true)
    if($result.Length -ne 1){throw "Expected one UI control: $name, got $($result.Length)"}
    return $result[0]
}
function Pump {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 30
    [Windows.Forms.Application]::DoEvents()
}
function Snapshot($form,[string]$path) {
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}
    finally{$bitmap.Dispose()}
}

$request=@'
{
  "connectionId":"conn-1","requestToken":"token-1","requestId":73,
  "threadId":"task-1","turnId":"turn-1","itemId":"item-1","isBlocking":true,
  "questions":[
    {"id":"choice","header":"技术方案","question":"请选择适用于长期维护的实现。此处的提问故意很长，用于检验窄窗口换行，同时确保不能裁切题干。","options":[
      {"label":"A","description":"保留现有流程，以便快速完成当前任务，同时记录后续迁移所需的边界与风险。"},
      {"label":"B","description":"将不同来源的状态统一管理，并确保异常与断线时能够返回原任务继续回答。"}]},
    {"id":"detail","header":"补充说明","question":"请填写具体理由。","options":[],"isSecret":false},
    {"id":"credential","header":"敏感输入","question":"敏感内容输入时需要隐藏。","options":[],"isSecret":true},
    {"id":"optional","header":"其他方案","question":"也可自行填写方案。","options":[{"label":"现有方案","description":"沿用既有配置。"}],"isOther":true}
  ]
}
'@
$form=$null
$directory=Join-Path ([IO.Path]::GetTempPath()) ('CodexQuestionWindow-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
try {
    [void][CodexDual.AppTheme]::SetAppearance('dark','green')
    $form=New-Object CodexDual.QuestionWindow
    $form.Add_SubmitRequested({$script:submitted++})
    $form.Add_ReturnRequested({$script:returned++})
    $form.SetRequestJson($request)
    $form.Show();Pump
    Check $form.TopMost 'Question window remains above normal application windows'
    $submit=Find-Control $form 'SubmitAnswer'
    $return=Find-Control $form 'ReturnToCodex'
    $status=Find-Control $form 'QuestionStatus'
    $introduction=Find-Control $form 'QuestionIntroduction'
    $footer=Find-Control $form 'QuestionFooter'
    Check ((Find-Control $form 'CaptionMuted').Text -eq '回答问题' -and $return.Text -eq '返回 Codex' -and $submit.Text -eq '提交' -and $form.Controls.Find('QuestionHeading',$true).Length -eq 0) 'Caption and actions use compact wording without duplicate headings'
    Check (-not $introduction.Visible -and -not $status.Visible -and $footer.Height -eq 52 -and (Find-Control $form 'Questions').Height -ge 280) 'Untitled ready request gives unused introduction and status space to questions'
    $form.SetRequestJson($request.Replace('"isBlocking":true','"isBlocking":true,"taskTitle":"精简通知界面"'));Pump
    Check ($introduction.Visible -and $introduction.Height -eq 28 -and (Find-Control $form 'QuestionContext').Text -eq '精简通知界面') 'Task title uses one compact line when provided'
    $form.SetRequestJson($request);Pump
    $screen=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    Check ($form.ClientSize.Width -eq [Math]::Min(480,$screen.Width) -and $form.ClientSize.Height -eq [Math]::Min(380,$screen.Height) -and -not $form.ShowInTaskbar) 'Default question window is compact and absent from the taskbar'
    Check ($form.Right -le $screen.Right -and $form.Bottom -le $screen.Bottom -and $form.Left -ge $screen.Left -and $form.Top -ge $screen.Top -and $screen.Right-$form.Right -le 20 -and $screen.Bottom-$form.Bottom -le 20) 'Preview appears at the notification corner inside the working area'
    Check ($form.FormBorderStyle -eq 'None' -and $form.MinimumSize.Width -le 320) 'Borderless window can be resized'
    $form.PlaceNearNotifications((New-Object Drawing.Rectangle(-1280,-720,1280,680)));Pump
    Check ($form.Location.X -eq -500 -and $form.Location.Y -eq -440 -and $form.Right -eq -20 -and $form.Bottom -eq -60) 'Placement respects negative monitor coordinates and taskbar-safe working area'
    $form.PlaceNearNotifications((New-Object Drawing.Rectangle(100,50,370,300)));Pump
    Check ($form.Bounds -eq (New-Object Drawing.Rectangle(100,50,370,300)) -and $form.MinimumSize.Width -le 370) 'Small working area keeps the entire window visible'
    $form.PlaceNearNotifications($screen);Pump
    Check ($form.RequestToken -eq 'token-1' -and -not $submit.Enabled -and $null -eq $form.AnswerJson) 'No answer is selected or emitted by default'
    $scroll=Find-Control $form 'Questions'
    Check ($scroll.VerticalScroll.Visible -and $scroll.Controls.Count -eq 4) 'Four questions scroll in the fixed window'
    $choice=Find-Control $form 'Option_choice_1'
    $detail=Find-Control $form 'Answer_detail'
    $secret=Find-Control $form 'Answer_credential'
    $other=Find-Control $form 'Answer_optional'
    Check ($secret.UseSystemPasswordChar -and -not $secret.Multiline) 'Sensitive input masks text'
    Check ($choice.Height -ge 43 -and (Find-Control $form 'QuestionTitle_choice').Height -ge 34) 'Long question and option descriptions reserve wrapped height'
    $choice.Checked=$true;$detail.Text='中文说明 / Unicode ✓';$secret.Text='secret-123';$other.Text='另一方案';Pump
    Check ($submit.Enabled -and $form.AnswerJson -eq $null -and $script:submitted -eq 0) 'Editing never emits an answer'
    $form.SetRequestJson($request);Pump
    Check ((Find-Control $form 'Option_choice_1').Checked -and (Find-Control $form 'Answer_detail').Text -eq '中文说明 / Unicode ✓' -and (Find-Control $form 'Answer_credential').Text -eq 'secret-123') 'Same token preserves multi-question draft including sensitive text'
    Check ((Find-Control $form 'Other_optional').Checked -and (Find-Control $form 'Answer_optional').Text -eq '另一方案') 'Other choice and its draft are restored'
    $form.Width=360;Pump
    $title=Find-Control $form 'QuestionTitle_choice'
    $option=Find-Control $form 'Option_choice_1'
    Check ($title.Height -gt 34 -and $option.Height -gt 43 -and $option.Right -le $scroll.ClientSize.Width -and -not $scroll.HorizontalScroll.Visible -and $submit.Right -le $form.ClientSize.Width -and $return.Right -lt $submit.Left) 'Narrow resize reflows long text and keeps actions visible'
    $form.PlaceNearNotifications($screen);Pump
    Snapshot $form (Join-Path $directory 'dark.png')
    $last=Find-Control $form 'Question_optional'
    $scroll.AutoScrollPosition=New-Object Drawing.Point(0,$scroll.VerticalScroll.Maximum);Pump
    Check ($last.Bottom -le $scroll.ClientSize.Height -and $last.Bottom -gt 0) 'Scrolling reaches the end of the final question above the footer'
    [void][CodexDual.AppTheme]::SetAppearance('light','blue');$form.ApplyAppearance();Pump
    Check ($form.BackColor.GetBrightness() -gt 0.8 -and (Find-Control $form 'Option_choice_1').ForeColor.ToArgb() -eq [CodexDual.AppTheme]::Text.ToArgb()) 'Light appearance updates controls in place'
    Snapshot $form (Join-Path $directory 'light.png')
    Check ((Test-Path (Join-Path $directory 'dark.png')) -and (Test-Path (Join-Path $directory 'light.png'))) 'Dark and light screenshots were rendered'
    $return.PerformClick();Pump
    Check ($script:returned -eq 1 -and $script:submitted -eq 0 -and $form.AnswerJson -eq $null) 'Return action does not answer'
    $form.SetSubmissionState($true,'正在提交回答…')
    Check (-not $submit.Enabled) 'Busy state disables submission'
    $form.Width=320;Pump
    $form.SetSubmissionState($false,'连接中断，回答尚未提交。请检查当前连接，或返回 Codex 继续回答；现有草稿会保留。');Pump
    Check ($status.Visible -and $status.Height -gt 24 -and $status.Bottom -lt $return.Top -and $footer.Height -gt 76) 'Long recovery status wraps above the actions in a narrow window'
    Snapshot $form (Join-Path $directory 'wrapped-status.png')
    $form.SetSubmissionState($false,'');Pump
    Check (-not $status.Visible -and $footer.Height -eq 52 -and $submit.Enabled) 'Ready state removes the explanation row and restores question space'
    $form.PlaceNearNotifications($screen);Pump
    $submit.PerformClick();Pump
    $answer=New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $command=$answer.DeserializeObject($form.AnswerJson)
    Check ($script:submitted -eq 1 -and -not $submit.Enabled -and $command.command -eq 'answer') 'Only explicit submit emits a complete answer command once'
    Check ($command.requestId -eq 73 -and $command.requestToken -eq 'token-1' -and $command.answers.choice.answers[0] -eq 'B' -and $command.answers.detail.answers[0] -eq '中文说明 / Unicode ✓' -and $command.answers.credential.answers[0] -eq 'secret-123' -and $command.answers.optional.answers[0] -eq '另一方案') 'Command preserves identity, Unicode, choices and free text'
    $form.InvalidateRequest('问题已失效，请返回 Codex。')
    Check (-not $submit.Enabled -and $form.AnswerJson -eq $null -and (Find-Control $form 'QuestionStatus').Text.Contains('失效')) 'Expired request clears pending output and disables submit'
    $form.SetSubmissionState($false,'连接已断开')
    Check (-not $submit.Enabled) 'Connection recovery cannot reactivate an invalid request'
    $form.Close();Pump
    Check (-not $form.Visible -and -not $form.IsDisposed -and $script:submitted -eq 1) 'Closing hides without producing an answer'
} finally {
    if($form){$form.Dispose()}
    [void][CodexDual.AppTheme]::SetAppearance('dark','neutral')
}
if($script:passed -ne 29){throw "Question window checks were skipped: $script:passed"}
Write-Output "PASSED: $script:passed question window checks. Screenshots: $directory"
