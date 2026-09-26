$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\..\src\Panel.ps1"
. "$PSScriptRoot\..\src\QuickPopup.ps1"
. "$PSScriptRoot\..\src\CompletionNotifications.ps1"
. "$PSScriptRoot\..\src\WorkspacePages.ps1"
$script:passed=0
function Check($v,$message){if(-not $v){throw "FAIL: $message"};$script:passed++;Write-Output "PASS: $message"}
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('appearance-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$config=[pscustomobject]@{stateDirectory=$root};$script:preferences=Read-ControllerPreferences $config
Check ($script:preferences.appearance.mode -eq 'dark' -and $script:preferences.appearance.accent -eq 'neutral') 'Legacy preferences preserve the existing dark neutral appearance'
$script:preferences.names['fixture']='保留名称';$script:preferences.panel=@{x=20;y=30};Save-ControllerPreferences $config $script:preferences
$panel=New-Object CodexDual.ShellForm;$panel.ClientSize=New-Object Drawing.Size(460,320);$panel.StartPosition='Manual';$panel.Location=New-Object Drawing.Point(-10000,-10000)
$sidebar=New-Object Windows.Forms.Panel;$sidebar.Name='Sidebar';$sidebar.SetBounds(0,0,100,260);$panel.Controls.Add($sidebar)
$surface=New-Object CodexDual.Surface;$surface.SetBounds(110,20,330,220);$panel.Controls.Add($surface)
$muted=New-UiLabel $surface '次要文字' 15 15 240 25;$muted.Name='Muted'
$button=New-UiButton $surface '主操作' 15 70 180 {};$button.Primary=$true
$script:feedback=New-UiLabel $panel '' 110 280 330 25
$script:themeButtons=@{};$script:accentButtons=@{}
$script:quickPopup=New-Object CodexDual.TrayPopup;$script:quickPopup.Size=New-Object Drawing.Size(300,200)
$card=New-Object CodexDual.CompletionCard;$card.StartPosition='Manual';$card.Location=New-Object Drawing.Point(-10000,-10000);$card.ShowInTaskbar=$false
try{
 $panel.Show();$card.Show()
 Set-ControllerAppearance -Mode light -Accent blue
 Check (-not [CodexDual.AppTheme]::IsDark -and $panel.BackColor.GetBrightness() -gt 0.8) 'Light mode recolors the existing window immediately'
 Check ($sidebar.BackColor.ToArgb() -eq [CodexDual.AppTheme]::Sidebar.ToArgb() -and $surface.BackColor.ToArgb() -eq [CodexDual.AppTheme]::Surface.ToArgb()) 'Sidebar and surface keep their color hierarchy'
 Check ($muted.ForeColor.ToArgb() -eq [CodexDual.AppTheme]::Muted.ToArgb()) 'Secondary text follows the selected palette'
 Check ($script:quickPopup.BackColor.ToArgb() -eq [CodexDual.AppTheme]::Surface.ToArgb() -and $script:quickPopup.BorderColor.ToArgb() -eq [CodexDual.AppTheme]::Border.ToArgb()) 'Hidden quick popup also receives the new appearance'
 Check ($card.BackColor.ToArgb() -eq [CodexDual.AppTheme]::Surface.ToArgb() -and $card.BorderColor.ToArgb() -eq [CodexDual.AppTheme]::Border.ToArgb()) 'An already visible notification changes with the app'
 $saved=Read-ControllerPreferences $config
 Check ($saved.appearance.mode -eq 'light' -and $saved.appearance.accent -eq 'blue') 'Mode and accent persist to preferences'
 Check ($saved.names.fixture -eq '保留名称' -and $saved.panel.x -eq 20) 'Appearance edits preserve names and window position'
 foreach($accent in @('neutral','blue','green','purple')){Set-ControllerAppearance -Accent $accent;Check ([CodexDual.AppTheme]::Accent -eq $accent -and (Read-ControllerPreferences $config).appearance.accent -eq $accent) ('Accent persists: '+$accent)}
 Set-ControllerAppearance -Mode dark
 Check ([CodexDual.AppTheme]::IsDark -and $panel.BackColor.GetBrightness() -lt 0.2) 'Dark mode applies without recreating the window'
 Set-ControllerAppearance -Mode system
 Check ([CodexDual.AppTheme]::Mode -eq 'system' -and (Read-ControllerPreferences $config).appearance.mode -eq 'system') 'System-following is stored as a mode, not a one-time color'
 $saved=Read-ControllerPreferences $config;$saved.appearance=@{mode='unknown';accent='unknown'};Save-ControllerPreferences $config $saved
 $read=Read-ControllerPreferences $config
 Check ($read.appearance.mode -eq 'dark' -and $read.appearance.accent -eq 'neutral' -and $read.names.fixture -eq '保留名称') 'Invalid appearance values fall back without discarding other preferences'
}finally{$card.Dispose();$script:quickPopup.Dispose();$panel.Dispose();[void][CodexDual.AppTheme]::SetAppearance('dark','neutral')}
Write-Output "PASSED: $script:passed appearance checks"
