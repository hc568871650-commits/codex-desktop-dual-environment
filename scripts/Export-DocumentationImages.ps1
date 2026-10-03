param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Use Windows PowerShell 5.1 -STA.'}
$repo=Split-Path $PSScriptRoot -Parent
$version=(Get-Content (Join-Path $repo 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json).version
if(-not $OutputDirectory){$OutputDirectory=Join-Path $repo ('docs/images/'+$version)}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$fixture=Join-Path $repo ('test-results/docs-images-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
. "$repo/src/Instances.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$repo/src/Panel.ps1"
. "$repo/src/CompletionNotifications.ps1"
. "$repo/src/QuickPopup.ps1"
[Windows.Forms.Application]::EnableVisualStyles()
$config=Get-Content "$repo/config/instances.example.json" -Raw -Encoding UTF8|ConvertFrom-Json
$config.stateDirectory=Join-Path $fixture 'state'
foreach($instance in $config.instances){
    $base=Join-Path $fixture $instance.role
    $instance.home=Join-Path $base 'CodexHome';$instance.profile=Join-Path $base 'DesktopProfile'
    $instance.projects=Join-Path $base 'Projects';$instance.projectless=Join-Path $base 'Projectless'
    $instance.executable=Join-Path $env:SystemRoot 'System32/notepad.exe'
    if($instance.role -eq 'api'){$instance.apiRoot=$base}
}
$configPath=Join-Path $fixture 'instances.local.json';Write-AtomicText $configPath ($config|ConvertTo-Json -Depth 8)
$fake=ConvertTo-SecureString 'documentation-fixture-only' -AsPlainText -Force
try{[void](Save-ApiEnvironment $config.instances[1].apiRoot $config.instances[0].home 'https://example.com/v1' 'example-model' $fake)}finally{$fake.Dispose()}
$script:preferences=Read-ControllerPreferences $config
# Every persistent write is confined to the disposable fixture above.
# Controller smoke mode replaces its launch callback; it never opens Codex.
foreach($sample in @(@('main','dark','overview-dark'),@('settings','light','settings-light'),@('notifications','light','notifications-light'))){
    $script:preferences.appearance.mode=$sample[1];$script:preferences.appearance.accent='blue'
    Save-ControllerPreferences $config $script:preferences
    & "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "$repo/src/Controller.ps1" -ConfigPath $configPath -Action panel -SmokeTest -Preview $sample[0] -ScreenshotPath (Join-Path $OutputDirectory ($sample[2]+'.png'))
    if($LASTEXITCODE -ne 0){throw ('Controller render failed: '+$sample[0])}
}
$panel=New-Object Windows.Forms.Form;$panel.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
$question=$null
try{
    foreach($mode in @('dark','light')){
        [void][CodexDual.AppTheme]::SetAppearance($mode,'blue')
        $card=New-CompactNoticeCard '文档示例' '已完成' '通知界面更新已完成，可以查看变更。' {param($sender,$e) $sender.FindForm().Close()}
        try{
            $card.Location=New-Object Drawing.Point(-10000,-10000);$card.SetDisplaySettings(0,$false);$card.Show()
            [Windows.Forms.Application]::DoEvents();Save-UiScreenshot $card (Join-Path $OutputDirectory ('completion-'+$mode+'.png'))
        }finally{$card.Dispose()}
        $question=New-Object CodexDual.QuestionWindow
        $request=@{connectionId='documentation';requestToken=('d'*32);requestId=1;threadId='example';turnId='example';taskTitle='文档示例 · 发布说明';questions=@(
            @{id='format';header='发布形式';question='这次发布说明采用哪种形式？';options=@(@{label='简明说明';description='突出变化、使用方式和已知边界。'},@{label='完整记录';description='附上验证证据和升级步骤。'})},
            @{id='note';header='补充';question='还有哪些内容需要说明？';options=@()}
        )}
        $question.SetRequestJson(($request|ConvertTo-Json -Depth 12 -Compress));$question.ApplyAppearance()
        $question.ShowWithoutFocus=$true;$question.Location=New-Object Drawing.Point(-10000,-10000)
        $question.Show();$question.Location=New-Object Drawing.Point(-10000,-10000)
        [Windows.Forms.Application]::DoEvents();Save-UiScreenshot $question (Join-Path $OutputDirectory ('question-'+$mode+'.png'))
        $question.Dispose();$question=$null
    }
    [void][CodexDual.AppTheme]::SetAppearance('dark','blue')
    $script:uiBusy=$false;$script:openBusy=$false;$script:statusCache=@{}
    $script:completionReady=$true;$script:completionSettings=[pscustomobject]@{enabled=$true;snoozedUntilUtc=''}
    $script:completionHistory=@()
    function Get-CompletionStatusText {return '已开启'}
    Initialize-QuickPopup
    Show-QuickPopup (New-Object Drawing.Point(100,100)) 'notifications'
    [Windows.Forms.Application]::DoEvents();Save-UiScreenshot $script:quickPopup (Join-Path $OutputDirectory 'quick-notifications-dark.png')
}finally{if($question){$question.Dispose()};if($script:quickPopup){$script:quickPopup.Dispose()};$panel.Dispose()}
$hashes=@(Get-ChildItem $OutputDirectory -Filter '*.png'|ForEach-Object{@{file=$_.Name;sha256=(Get-FileHash $_.FullName).Hash}})
Write-AtomicText (Join-Path $fixture 'images.json') (@{version=$version;source='actual WinForms controls with synthetic data';images=$hashes}|ConvertTo-Json -Depth 5)
Write-Output ('Documentation images: '+$OutputDirectory)
Write-Output ('Fixture evidence: '+$fixture)
