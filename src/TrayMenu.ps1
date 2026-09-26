function Initialize-QuickMenu {
    $titleItem=$menu.Items[0];$menu.Items.Clear()
    [void]$menu.Items.Add($titleItem)
    foreach($role in @('official','api')){[void]$menu.Items.Add($labels[$role])}
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($openPanelItem)
    foreach($role in @('official','api')){[void]$menu.Items.Add($script:openMenus[$role])}
    [void]$menu.Items.Add($bothEntry)
    $recent=New-Object Windows.Forms.ToolStripMenuItem('最近完成');$recent.DropDown=New-Object CodexDual.QuietMenu
    $placeholder=$recent.DropDownItems.Add('暂无完成记录');$placeholder.Enabled=$false
    $recent.Add_DropDownOpening({
        param($sender,$e) $recent=$sender
        while($recent.DropDownItems.Count){$recent.DropDownItems[0].Dispose()}
        foreach($event in $script:completionHistory){
            $instance=@($config.instances|Where-Object {$_.id -eq $event.instanceId})
            if($instance.Count -ne 1){continue}
            $title=[string](Get-ObjectValue $event 'title' '任务已完成')
            $title=$title -replace '[\p{Cc}\p{Cf}]',' ';if($title.Length -gt 28){$title=$title.Substring(0,27)+'…'}
            $name=(Get-InstanceDisplayName $instance[0] $script:preferences)+' · '+$title
            $item=$recent.DropDownItems.Add($name.Replace('&','&&'));$item.Tag=$event
            $item.Add_Click({param($sender,$e)
                $event=$sender.Tag;$target=@($config.instances|Where-Object {$_.id -eq $event.instanceId})
                if($target.Count -eq 1){$menu.Close();Invoke-PanelAction {Open-CompletionTarget $target[0] $event.threadId}}
            })
        }
        if(-not $recent.DropDownItems.Count){$empty=$recent.DropDownItems.Add('本次运行暂无完成记录');$empty.Enabled=$false}
        else{
            [void]$recent.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
            $clear=$recent.DropDownItems.Add('清除最近记录');$clear.Add_Click({$script:completionHistory=@()})
        }
    })
    [void]$menu.Items.Add($recent)
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $directories=New-Object Windows.Forms.ToolStripMenuItem('环境目录');$directories.DropDown=New-Object CodexDual.QuietMenu
    $script:directoryParents=@{}
    foreach($role in @('official','api')){
        $instance=@($config.instances|Where-Object {$_.role -eq $role})[0]
        $parent=New-Object Windows.Forms.ToolStripMenuItem((Get-InstanceDisplayName $instance $script:preferences).Replace('&','&&'))
        $parent.DropDown=New-Object CodexDual.QuietMenu;$script:directoryParents[$role]=$parent
        foreach($entry in @(@('projects','项目目录'),@('projectless','无项目任务目录'),@('home','配置目录'))){
            $item=$parent.DropDownItems.Add($entry[1]);$item.Tag=@{Instance=$instance;Kind=$entry[0]}
            $item.Add_Click({param($sender,$e) $target=$sender.Tag;$menu.Close();Invoke-PanelAction {Open-InstanceDirectory $target.Instance $target.Kind}})
        }
        [void]$directories.DropDownItems.Add($parent)
    }
    [void]$menu.Items.Add($directories);[void]$menu.Items.Add($apiMenu)
    $diagnostics=$menu.Items.Add('检查环境');$diagnostics.Add_Click({$menu.Close();Show-ControlPanel;Show-ControllerDiagnostics})
    $notifications=New-Object Windows.Forms.ToolStripMenuItem('通知');$notifications.DropDown=New-Object CodexDual.QuietMenu
    $notifications.Enabled=$script:completionReady
    [void]$notifications.DropDownItems.Add($completionMenu)
    foreach($minutes in @(15,60)){
        $pause=$notifications.DropDownItems.Add(('暂停提醒 '+$minutes+' 分钟'));$pause.Tag=$minutes
        $pause.Add_Click({param($sender,$e) Set-CompletionSnooze ([int]$sender.Tag)})
    }
    $resume=$notifications.DropDownItems.Add('恢复提醒');$resume.Add_Click({Set-CompletionSnooze 0})
    [void]$notifications.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
    $dismiss=$notifications.DropDownItems.Add('关闭所有提示');$dismiss.Add_Click({Close-CompletionCards})
    $notifications.Add_DropDownOpening({
        param($sender,$e) $notifications=$sender
        $completionMenu.Checked=$script:completionSettings.enabled
        $notifications.DropDownItems[1].Enabled=$script:completionSettings.enabled
        $notifications.DropDownItems[2].Enabled=$script:completionSettings.enabled
        $notifications.DropDownItems[3].Enabled=Test-CompletionSnoozed
    })
    [void]$menu.Items.Add($notifications)
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $closeGroup=New-Object Windows.Forms.ToolStripMenuItem('退出环境…');$closeGroup.DropDown=New-Object CodexDual.QuietMenu
    foreach($role in @('official','api')){[void]$closeGroup.DropDownItems.Add($script:closeMenus[$role])}
    [void]$menu.Items.Add($closeGroup);[void]$menu.Items.Add($exitItem)
    $menu.Add_Opening({
        foreach($instance in $config.instances){$script:directoryParents[$instance.role].Text=(Get-InstanceDisplayName $instance $script:preferences).Replace('&','&&')}
        $script:notificationsMenu.Text=if($script:completionReady -and (Test-CompletionSnoozed)){'通知 · 已暂停'}else{'通知'}
        $script:recentMenu.Enabled=$script:completionReady
    })
    # These handlers outlive this setup function; capture menu objects explicitly.
    $script:recentMenu=$recent;$script:notificationsMenu=$notifications
}
