# UI-independent daily actions; each environment retains its own identity checks.
function Invoke-DualOpen($Config,[scriptblock]$OpenAction) {
    foreach($role in @('official','api')) {
        $instance=@($Config.instances | Where-Object {$_.role -eq $role})[0]
        try {
            $outcome=& $OpenAction $instance
            if($outcome -notin @('Shown','Running','Cancelled')){throw '打开操作未返回可确认的结果。'}
            [pscustomobject]@{Role=$role;Outcome=$outcome;Error=''}
        } catch {
            # Preserve the original failure for the local result dialog, never the shareable report.
            [pscustomobject]@{Role=$role;Outcome='Failed';Error=$_.Exception.Message}
        }
    }
}

function Get-InstanceDirectoryPath($Instance,[ValidateSet('projects','projectless','home')][string]$Kind) {
    $path=[string]$Instance.$Kind
    if($Kind -eq 'projectless') {
        # Resolve the actual desktop setting, including official environments that inherit it.
        $actual=Get-ConfiguredProjectless $Instance.home
        if($path -and -not (Test-SamePath $path $actual)){throw '实际无项目任务目录与控制器记录不符，请先检查配置。'}
        $path=$actual
    }
    if(-not $path){throw '此环境未配置该目录。'}
    $path=Get-FullDirectory $path
    Assert-NoReparsePoint $path
    if(-not (Test-Path -LiteralPath $path -PathType Container)){throw '目录不存在；请先检查环境或完成部署。'}
    return $path
}

function Open-InstanceDirectory($Instance,[ValidateSet('projects','projectless','home')][string]$Kind) {
    $path=Get-InstanceDirectoryPath $Instance $Kind
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:SystemRoot 'explorer.exe'
    $info.Arguments='"'+$path+'"';$info.UseShellExecute=$true
    $child=[Diagnostics.Process]::Start($info)
    if($child){$child.Dispose()}
}
