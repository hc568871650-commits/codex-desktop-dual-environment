$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. "$PSScriptRoot\..\src\Panel.ps1"
. "$PSScriptRoot\..\src\CompletionNotifications.ps1"
. "$PSScriptRoot\..\src\TrayMenu.ps1"
$script:passed=0
function Check($value,$message){if(-not $value){throw "FAIL: $message"};$script:passed++;Write-Output "PASS: $message"}
$config=[pscustomobject]@{instances=@([pscustomobject]@{id=('a'*32);role='official'},[pscustomobject]@{id=('b'*32);role='api'})}
$script:preferences=@{names=@{}};$script:completionReady=$true
$script:completionSettings=[pscustomobject]@{enabled=$true;snoozedUntilUtc=''}
$script:completionHistory=@();$script:directoryCalls=@();$script:taskCalls=@()
$menu=New-Object CodexDual.QuietMenu
[void]$menu.Items.Add('Codex 双环境')
$labels=@{};$script:openMenus=@{};$script:closeMenus=@{}
foreach($role in @('official','api')){$labels[$role]=New-Object Windows.Forms.ToolStripMenuItem($role);$script:openMenus[$role]=New-Object Windows.Forms.ToolStripMenuItem('打开 '+$role);$script:closeMenus[$role]=New-Object Windows.Forms.ToolStripMenuItem('退出 '+$role)}
$openPanelItem=New-Object Windows.Forms.ToolStripMenuItem('打开控制面板')
$bothEntry=New-Object Windows.Forms.ToolStripMenuItem('同时打开两边')
$apiMenu=New-Object Windows.Forms.ToolStripMenuItem('管理 API')
$completionMenu=New-Object Windows.Forms.ToolStripMenuItem('独立任务完成提示')
$exitItem=New-Object Windows.Forms.ToolStripMenuItem('退出控制器')
function Invoke-PanelAction([scriptblock]$Action){& $Action}
function Open-CompletionTarget($Instance,$ThreadId){$script:taskCalls+=@{role=$Instance.role;threadId=$ThreadId}}
function Open-InstanceDirectory($Instance,$Kind){$script:directoryCalls+=@{role=$Instance.role;kind=$Kind}}
function Show-ControlPanel {$script:settingsOpened=$true}
function Show-WorkspacePage($Page){$script:settingsPageOpened=$Page}
try{
 Initialize-QuickMenu
 Check ($menu -is [CodexDual.QuietMenu] -and $menu.Renderer -is [CodexDual.QuietMenuRenderer]) 'Tray uses the shared neutral renderer'
 Check $script:recentMenu.HasDropDownItems 'Recent tasks submenu is reachable even before first completion'
 $menu.Show(50,50);$script:recentMenu.ShowDropDown();[Windows.Forms.Application]::DoEvents()
 Check ($script:recentMenu.DropDownItems.Count -eq 1 -and -not $script:recentMenu.DropDownItems[0].Enabled) 'Empty recent history has a disabled placeholder'
 $script:recentMenu.HideDropDown()
 $thread=[guid]::NewGuid().ToString();$script:completionHistory=@([pscustomobject]@{instanceId=('b'*32);threadId=$thread;title='菜单测试'})
 $script:completionHistory+=@([pscustomobject]@{instanceId=('a'*32);threadId=[guid]::NewGuid().ToString();title='官方记录不得展示'})
 $script:recentMenu.ShowDropDown();[Windows.Forms.Application]::DoEvents()
 Check ($script:recentMenu.DropDownItems.Count -eq 3) 'Recent submenu refreshes after setup function returns'
 $script:recentMenu.DropDownItems[0].PerformClick()
 Check ($script:taskCalls.Count -eq 1 -and $script:taskCalls[0].role -eq 'api' -and $script:taskCalls[0].threadId -eq $thread) 'Recent item targets exact environment and task'
 $script:directoryParents.api.DropDownItems[1].PerformClick()
 Check ($script:directoryCalls[0].role -eq 'api' -and $script:directoryCalls[0].kind -eq 'projectless') 'Directory submenu retains environment and directory kind'
 $script:notificationsMenu.PerformClick()
 Check (-not $script:notificationsMenu.HasDropDownItems -and $script:settingsOpened -and $script:settingsPageOpened -eq 'notifications') 'Tray notification entry leads only to console settings'
 $menu.Close()
}finally{$menu.Dispose()}
Write-Output "PASSED: $script:passed quick-menu checks"
