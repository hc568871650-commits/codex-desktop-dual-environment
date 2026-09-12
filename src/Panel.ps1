# UI helpers share the controller runspace. Instance IDs remain the action targets.
function New-UiLabel($Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height=26) {
    $label=New-Object Windows.Forms.Label;$label.Text=$Text;$label.UseMnemonic=$false;$label.SetBounds($X,$Y,$Width,$Height);$Parent.Controls.Add($label);return $label
}
function New-UiButton($Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width,[scriptblock]$Click) {
    $button=New-Object Windows.Forms.Button;$button.Text=$Text;$button.SetBounds($X,$Y,$Width,32);$button.Add_Click($Click);$Parent.Controls.Add($button);return $button
}
function New-UiTextBox($Parent,[int]$X,[int]$Y,[int]$Width) {
    $box=New-Object Windows.Forms.TextBox;$box.SetBounds($X,$Y,$Width,28);$Parent.Controls.Add($box);return $box
}
function Set-UiMessage([string]$Message) {$script:feedback.Text=$Message}
function Invoke-PanelAction([scriptblock]$Action) {
    if($script:uiBusy){return}
    $script:uiBusy=$true;$panel.UseWaitCursor=$true
    try{& $Action}catch{Set-UiMessage $_.Exception.Message;Show-Error $_}
    finally{$panel.UseWaitCursor=$false;$script:uiBusy=$false;Update-PanelStatus}
}
function Update-PanelNames {
    $script:preferences=Read-ControllerPreferences $config
    foreach($instance in $config.instances){
        $name=Get-InstanceDisplayName $instance $script:preferences
        $script:instanceNames[$instance.role].Text=$name
        $escaped=$name.Replace('&','&&')
        $script:openMenus[$instance.role].Text='打开 '+$escaped
        $script:closeMenus[$instance.role].Text='退出 '+$escaped+'…'
    }
}
function Save-PanelPosition {
    if($panel.WindowState -ne 'Normal'){return}
    try{
        $saved=Read-ControllerPreferences $config;$saved.panel=@{x=$panel.Left;y=$panel.Top}
        Save-ControllerPreferences $config $saved;$script:preferences=$saved
    }catch{Set-UiMessage ('位置未保存：'+$_.Exception.Message)}
}
function Show-ControlPanel {
    if($panel.WindowState -eq 'Minimized'){$panel.WindowState='Normal'}
    $saved=if($script:positionInitialized){@{x=$panel.Left;y=$panel.Top}}else{$script:preferences.panel}
    $areas=@([Windows.Forms.Screen]::AllScreens|ForEach-Object {$_.WorkingArea})
    $point=Get-VisiblePanelPoint $saved $panel.Width $panel.Height $areas
    $panel.Location=New-Object Drawing.Point($point.x,$point.y);$script:positionInitialized=$true
    $panel.Show();$panel.Activate();Update-PanelStatus
}
function Show-NameDialog($Instance) {
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='修改显示名称';$dialog.ClientSize=New-Object Drawing.Size(390,165)
    $dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.StartPosition='CenterParent';$dialog.Font=$panel.Font
    [void](New-UiLabel $dialog '显示名称（1–24 个字符）' 20 18 340)
    $nameInput=New-UiTextBox $dialog 20 49 350;$nameInput.MaxLength=24;$nameInput.Text=Get-InstanceDisplayName $Instance (Read-ControllerPreferences $config)
    $ok=New-UiButton $dialog '保存' 20 104 98 {
        try{[void](Set-InstanceDisplayName $config $Instance $nameInput.Text);Update-PanelNames;$dialog.DialogResult='OK'}catch{Show-Error $_}
    }
    [void](New-UiButton $dialog '恢复默认' 126 104 110 {
        try{[void](Set-InstanceDisplayName $config $Instance '' -Reset);Update-PanelNames;$dialog.DialogResult='OK'}catch{Show-Error $_}
    })
    $cancel=New-UiButton $dialog '取消' 244 104 126 {$dialog.DialogResult='Cancel'};$dialog.AcceptButton=$ok;$dialog.CancelButton=$cancel
    try{[void]$dialog.ShowDialog($panel)}finally{$dialog.Dispose()}
}
function Update-ApiSummary {
    $instance=$script:apiInstance
    $script:profilePicker.Items.Clear()
    if($instance.launchMode -ne 'managed-api'){$script:apiSummary.Text='外部启动器管理 · 配置请使用原管理工具';$script:profilePicker.Enabled=$false;$script:applyButton.Enabled=$false;return}
    try{
        $mode=Get-ApiManagementMode $instance.apiRoot
        $script:profilePicker.Enabled=$mode -eq 'builtin';$script:applyButton.Enabled=$mode -eq 'builtin'
        if($mode -eq 'ccs'){$script:apiSummary.Text='CC Switch 管理 · 请在 CCS 中切换渠道';return}
        $data=Read-ApiProfiles $config $instance
        foreach($profile in $data.profiles){[void]$script:profilePicker.Items.Add($profile)}
        $script:profilePicker.DisplayMember='name'
        $selectedId=if($data.pendingProfile){$data.pendingProfile.id}else{$data.activeId}
        $active=@($data.profiles|Where-Object {$_.id -eq $selectedId})
        if($active.Count){$script:profilePicker.SelectedItem=$active[0]}
        $doc=New-Object CodexDual.TomlConfig([IO.File]::ReadAllText((Join-Path $instance.home 'config.toml')))
        $script:apiSummary.Text='已配置默认模型：'+$doc.GetString('model')
        if($data.pendingProfile){$script:apiSummary.Text='下次启动应用：'+$data.pendingProfile.name+' / '+$data.pendingProfile.model}
    }catch{$script:apiSummary.Text='API 配置需检查';Set-UiMessage $_.Exception.Message;$script:applyButton.Enabled=$false}
}
function Apply-SelectedProfile($Profile,[bool]$Restart) {
    if(-not $Profile){throw '请先选择一个渠道。'}
    $instance=$script:apiInstance
    if($Restart){
        Close-Instance $instance
        if((Get-InstanceStatus $config $instance).State -ne 'Stopped'){Set-UiMessage '已取消：API 实例尚未退出，渠道未应用。';return}
    }
    $before=Get-InstanceStatus $config $instance
    $applied=Apply-ApiProfile $config $instance $Profile.id
    if($applied -eq 'Deferred'){$before=Get-InstanceStatus $config $instance}
    $saved=Read-ControllerPreferences $config
    $saved.pendingApi=if($applied -eq 'Deferred' -and $before.State -eq 'Running'){@{pid=$before.Process.Id;started=$before.Process.Started}}else{$null}
    Save-ControllerPreferences $config $saved;$script:preferences=$saved
    if($applied -eq 'Deferred'){Set-UiMessage '渠道已暂存。请在结束任务后重启 API 窗口，使新配置和密钥生效。'}
    elseif($Restart){Open-Instance $instance;Set-UiMessage '渠道已应用，API 窗口已重新打开。'}
    else{Set-UiMessage '渠道已应用，下次打开 API 窗口时使用。'}
    Update-ApiSummary
}
function Show-ApiManager {
    if($script:apiDialog -and -not $script:apiDialog.IsDisposed){$script:apiDialog.Activate();return}
    $instance=$script:apiInstance
    if($instance.launchMode -ne 'managed-api'){[void][Windows.Forms.MessageBox]::Show('此实例使用已登记的外部启动器，请通过原工具配置 API。可在“检查环境”查看路径。','API 管理');return}
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='API 渠道管理';$dialog.ClientSize=New-Object Drawing.Size(640,570)
    $dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.StartPosition='Manual';$dialog.Location=$panel.Location;$dialog.Font=$panel.Font
    $tabs=New-Object Windows.Forms.TabControl;$tabs.Dock='Fill';$dialog.Controls.Add($tabs)
    $channels=New-Object Windows.Forms.TabPage('渠道方案');$ccsPage=New-Object Windows.Forms.TabPage('CCS 接入');$backupPage=New-Object Windows.Forms.TabPage('备份恢复')
    $tabs.TabPages.AddRange(@($channels,$ccsPage,$backupPage))
    $list=New-Object Windows.Forms.ListBox;$list.SetBounds(18,20,200,336);$list.DisplayMember='name';$channels.Controls.Add($list)
    [void](New-UiLabel $channels '渠道名称' 238 20 350);$nameBox=New-UiTextBox $channels 238 46 368;$nameBox.MaxLength=40
    [void](New-UiLabel $channels 'API 地址（支持 Responses API）' 238 84 368);$urlBox=New-UiTextBox $channels 238 110 368
    [void](New-UiLabel $channels '默认模型 ID' 238 148 368);$modelBox=New-UiTextBox $channels 238 174 368
    [void](New-UiLabel $channels 'API Key（编辑时留空保留）' 238 212 368);$keyBox=New-UiTextBox $channels 238 238 368;$keyBox.UseSystemPasswordChar=$true
    $editState=@{id=''}
    $channelMessage=New-UiLabel $channels '保存方案后，选择应用；运行中的 API 窗口需重启。' 18 414 590 84
    function Refresh-ChannelList([string]$SelectId) {
        $list.Items.Clear();$data=Read-ApiProfiles $config $instance
        foreach($profile in $data.profiles){[void]$list.Items.Add($profile)}
        $selected=@($data.profiles|Where-Object {$_.id -eq $SelectId})
        if($selected.Count){$list.SelectedItem=$selected[0]}elseif($list.Items.Count){$list.SelectedIndex=0}
    }
    $list.Add_SelectedIndexChanged({
        if($list.SelectedItem){$profile=$list.SelectedItem;$editState.id=$profile.id;$nameBox.Text=$profile.name;$urlBox.Text=$profile.baseUrl;$modelBox.Text=$profile.model;$keyBox.Clear()}
    })
    [void](New-UiButton $channels '新增' 18 370 92 {$list.ClearSelected();$editState.id='';$nameBox.Clear();$urlBox.Clear();$modelBox.Clear();$keyBox.Clear();$nameBox.Focus()})
    [void](New-UiButton $channels '删除' 120 370 98 {
        if($list.SelectedItem -and [Windows.Forms.MessageBox]::Show('删除所选渠道方案？当前正在使用的渠道不能删除。','删除渠道','YesNo','Question') -eq 'Yes'){
            try{Remove-ApiProfile $config $instance $list.SelectedItem.id;Refresh-ChannelList '';Update-ApiSummary}catch{Show-Error $_}
        }
    })
    [void](New-UiButton $channels '保存方案' 238 282 368 {
        $secure=$null
        try{
            if($keyBox.Text){$secure=ConvertTo-SecureString $keyBox.Text -AsPlainText -Force}
            $savedId=Save-ApiProfile $config $instance $editState.id $nameBox.Text $urlBox.Text $modelBox.Text $secure
            $keyBox.Clear();Refresh-ChannelList $savedId;Update-ApiSummary;$channelMessage.Text='方案已保存，尚未应用。请选择“应用”或“应用并重启 API”。'
        }catch{Show-Error $_}finally{if($secure){$secure.Dispose()}}
    })
    [void](New-UiButton $channels '应用，稍后生效' 238 328 174 {
        try{Apply-SelectedProfile $list.SelectedItem $false;$channelMessage.Text=$script:feedback.Text}catch{Show-Error $_}
    })
    [void](New-UiButton $channels '应用并重启 API' 420 328 186 {
        try{Apply-SelectedProfile $list.SelectedItem $true;$channelMessage.Text=$script:feedback.Text}catch{Show-Error $_}
    })
    [void](New-UiLabel $ccsPage 'CCS 管理此 API 环境的渠道与密钥，控制器管理双窗口。' 18 20 590 46)
    [void](New-UiLabel $ccsPage 'CC Switch 程序' 18 76 590);$ccsExe=New-UiTextBox $ccsPage 18 104 486
    $settings=Read-ControllerPreferences $config;$ccsExe.Text=$settings.ccsExecutable
    [void](New-UiButton $ccsPage '选择…' 514 102 92 {
        $picker=New-Object Windows.Forms.OpenFileDialog;$picker.Filter='CC Switch 程序 (*.exe)|*.exe'
        try{if($picker.ShowDialog($dialog) -eq 'OK'){$ccsExe.Text=$picker.FileName}}finally{$picker.Dispose()}
    })
    [void](New-UiLabel $ccsPage 'CCS 设置文件（自动检测，仅核对目录）' 18 150 590);$ccsSettings=New-UiTextBox $ccsPage 18 178 588;$ccsSettings.ReadOnly=$true;$ccsSettings.Text=Get-CcsSettingsPath
    [void](New-UiLabel $ccsPage ('请在 CCS 中把 Codex 配置目录设为：'+[Environment]::NewLine+$instance.home) 18 224 588 66)
    $ccsMessage=New-UiLabel $ccsPage '' 18 394 588 110
    function Save-CcsPreference {
        $saved=Read-ControllerPreferences $config;$saved.ccsExecutable=$ccsExe.Text;$saved.ccsSettingsPath=$ccsSettings.Text;Save-ControllerPreferences $config $saved;$script:preferences=$saved
    }
    [void](New-UiButton $ccsPage '检查接入' 18 304 174 {try{[void](Test-CcsBinding $instance $ccsSettings.Text $ccsExe.Text);Save-CcsPreference;$ccsMessage.Text='目录匹配。交接前请结束 API 任务并退出实例。'}catch{$ccsMessage.Text=$_.Exception.Message}})
    [void](New-UiButton $ccsPage '打开 CCS' 208 304 174 {try{Open-CcsManager $instance $ccsSettings.Text $ccsExe.Text -Configure:((Get-ApiManagementMode $instance.apiRoot) -eq 'builtin');Save-CcsPreference}catch{Show-Error $_}})
    $ccsToggle=New-UiButton $ccsPage '交给 CCS 管理' 18 350 364 {
        try{
            $isCcs=(Get-ApiManagementMode $instance.apiRoot) -eq 'ccs'
            $message=if($isCcs){'恢复交给 CCS 前的内置配置？请先退出 CCS，避免它重新写入配置；当前配置会另存加密备份。'}else{'将此 API 环境交给 CCS 管理？内置配置会备份；完成后请在 CCS 中选择供应商，并保留 API 登录及任务目录设置。'}
            if([Windows.Forms.MessageBox]::Show($message,'切换管理方式','YesNo','Question','Button2') -ne 'Yes'){return}
            if($isCcs){Disable-CcsManagement $config $instance}else{Enable-CcsManagement $config $instance $ccsSettings.Text $ccsExe.Text;Save-CcsPreference}
            $isCcs=(Get-ApiManagementMode $instance.apiRoot) -eq 'ccs';$channels.Enabled=-not $isCcs
            $ccsToggle.Text=if($isCcs){'恢复内置管理'}else{'交给 CCS 管理'}
            $ccsMessage.Text=if($isCcs){'已交给 CCS。请在 CCS 中选择供应商；内置渠道编辑已停用。'}else{'已恢复内置管理。'}
            Update-ApiSummary;Refresh-ChannelList ''
        }catch{Show-Error $_}
    }
    $isCcs=(Get-ApiManagementMode $instance.apiRoot) -eq 'ccs';$channels.Enabled=-not $isCcs
    $ccsToggle.Text=if($isCcs){'恢复内置管理'}else{'交给 CCS 管理'}
    if($isCcs){$tabs.SelectedTab=$ccsPage}
    [void](New-UiLabel $backupPage '恢复快照会同时恢复 API 配置、密钥及渠道列表。' 18 20 590 44)
    $backupList=New-Object Windows.Forms.ListBox;$backupList.SetBounds(18,80,588,278);$backupList.DisplayMember='label';$backupPage.Controls.Add($backupList)
    function Refresh-BackupList {
        $backupList.Items.Clear();$folder=Join-Path $instance.apiRoot 'Backup';Assert-NoReparsePoint $folder
        foreach($file in @(Get-ChildItem -LiteralPath $folder -Filter 'snapshot-*.local.json' -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending)){
            Assert-NoReparsePoint $file.FullName;$meta=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
            [void]$backupList.Items.Add([pscustomobject]@{path=$file.FullName;label=([DateTime]$meta.created).ToString('yyyy-MM-dd HH:mm:ss')+' · '+$meta.reason})
        }
    }
    [void](New-UiButton $backupPage '备份当前配置' 18 380 180 {try{[void](New-ApiBackup $config $instance '手动备份');Refresh-BackupList}catch{Show-Error $_}})
    [void](New-UiButton $backupPage '恢复选中快照…' 214 380 190 {
        if(-not $backupList.SelectedItem){return}
        if([Windows.Forms.MessageBox]::Show(('恢复：'+$backupList.SelectedItem.label+'？请先退出 API 实例。'), '恢复 API 配置','YesNo','Question','Button2') -ne 'Yes'){return}
        try{Restore-ApiBackup $config $instance $backupList.SelectedItem.path;Refresh-BackupList;Refresh-ChannelList '';Update-ApiSummary;[void][Windows.Forms.MessageBox]::Show('已恢复，可重新打开 API 环境。','恢复完成')}catch{Show-Error $_}
    })
    [void](New-UiLabel $backupPage '快照仅供当前 Windows 用户解密。恢复前会另存一份备份。' 18 432 588 64)
    $script:apiDialog=$dialog
    try{Refresh-ChannelList '';Refresh-BackupList
        if($SmokeTest -and $Preview -eq 'api'){$dialog.Show();[Windows.Forms.Application]::DoEvents();Save-UiScreenshot $dialog $ScreenshotPath}
        else{[void]$dialog.ShowDialog($panel)}
    }finally{$keyBox.Clear();$dialog.Dispose();$script:apiDialog=$null}
}
function Show-ControllerDiagnostics {
    $lines=New-Object 'Collections.Generic.List[string]'
    foreach($instance in $config.instances){
        $name=Get-InstanceDisplayName $instance (Read-ControllerPreferences $config)
        $lines.Add('【'+$name+'】');$lines.Add('配置目录：'+$instance.home)
        try{$status=Get-InstanceStatus $config $instance;$lines.Add('实例：'+$status.Reason)}catch{$lines.Add('实例检查：'+$_.Exception.Message)}
        try{foreach($key in @('home','profile','projects','projectless')){if($instance.$key -and -not (Test-Path -LiteralPath $instance.$key -PathType Container)){$lines.Add('缺少目录：'+$key)}}
            if($instance.role -eq 'api' -and $instance.launchMode -eq 'managed-api'){
                if((Get-ApiManagementMode $instance.apiRoot) -eq 'ccs'){$meta=Get-Content -LiteralPath (Join-Path $instance.apiRoot '.codex-dual.json') -Raw -Encoding UTF8|ConvertFrom-Json;[void](Test-CcsBinding $instance $meta.ccsSettingsPath $meta.ccsExecutable);$lines.Add('CCS 目标目录：匹配')}
                $official=@($config.instances|Where-Object {$_.role -eq 'official'})[0]
                $probe=New-CodexStartInfo -Executable (Find-CodexExecutable $instance.executable) -OfficialHome $official.home -ApiRoot $instance.apiRoot -Api
                $probe.EnvironmentVariables.Remove('CODEX_DUAL_API_KEY');$lines.Add('启动配置与凭据入口：检查通过')
            }
        }catch{$lines.Add('配置检查：'+$_.Exception.Message)}
        $lines.Add('')
    }
    $lines.Add('检查未发送 API 请求。运行状态不代表任务空闲。')
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='环境检查';$dialog.Size=New-Object Drawing.Size(680,470);$dialog.StartPosition='CenterParent';$dialog.Font=$panel.Font
    $text=New-Object Windows.Forms.TextBox;$text.Multiline=$true;$text.ReadOnly=$true;$text.ScrollBars='Both';$text.Dock='Fill';$text.Text=$lines -join [Environment]::NewLine;$dialog.Controls.Add($text)
    try{[void]$dialog.ShowDialog($panel)}finally{$dialog.Dispose()}
}
function Save-UiScreenshot($Form,[string]$Path) {
    $bmp=New-Object Drawing.Bitmap($Form.Width,$Form.Height)
    try{$Form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$Form.Width,$Form.Height)));$bmp.Save($Path)}finally{$bmp.Dispose()}
}
