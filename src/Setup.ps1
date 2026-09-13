# Unified entry discovery and decision logic. Hints are never executed or trusted as manifests.
. "$PSScriptRoot\Upgrade.ps1"

function Get-ControllerSetupHints {
    param(
        [string]$DefaultDirectory=(Join-Path $env:LOCALAPPDATA 'CodexDualController'),
        [string]$RegistryPath='HKCU:\Software\CodexDualController\Installations',
        [string]$StartupRegistryPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        [string]$ShortcutDirectory=[Environment]::GetFolderPath('Desktop'),
        [object[]]$Snapshot
    )
    $hints=@($DefaultDirectory)
    $registered=Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue
    if($registered){foreach($property in $registered.PSObject.Properties){if($property.Name -like 'CodexDualController.*'){$hints+=[string]$property.Value}}}
    if(-not $PSBoundParameters.ContainsKey('Snapshot')){$Snapshot=Get-ProcessSnapshot}
    foreach($process in $Snapshot){if($process.Path -and [IO.Path]::GetFileName($process.Path) -ieq 'CodexDualController.exe'){$hints+=Split-Path $process.Path -Parent}}
    $startup=Get-ItemProperty -LiteralPath $StartupRegistryPath -ErrorAction SilentlyContinue
    if($startup){foreach($property in $startup.PSObject.Properties){
        if($property.Name -notlike 'CodexDualController.*'){continue}
        $argv=@([CodexDual.Native]::Arguments([string]$property.Value))
        if($argv.Count -and [IO.Path]::IsPathRooted($argv[0]) -and [IO.Path]::GetFileName($argv[0]) -ieq 'CodexDualController.exe'){$hints+=Split-Path $argv[0] -Parent}
    }}
    if(Test-Path -LiteralPath $ShortcutDirectory -PathType Container){
        $shell=New-Object -ComObject WScript.Shell
        foreach($file in @(Get-ChildItem -LiteralPath $ShortcutDirectory -Filter '*.lnk' -File)){
            try{$link=$shell.CreateShortcut($file.FullName);if($link.TargetPath -and [IO.Path]::GetFileName($link.TargetPath) -ieq 'CodexDualController.exe'){$hints+=Split-Path $link.TargetPath -Parent}}catch{Write-Warning ('Cannot read shortcut: '+$file.Name)}
        }
    }
    return $hints
}

function Get-ControllerInstallCandidate([string]$Root,[string]$LegacySettingsPath) {
    $candidate=[pscustomobject]@{Root=$Root;Valid=$false;Version='0.0.0';Legacy=$false;Reason=''}
    try{
        $candidate.Root=Get-FullDirectory $Root;Assert-NoReparsePoint $candidate.Root
        $manifestPath=Join-Path $candidate.Root 'install-manifest.json'
        $configPath=Join-Path $candidate.Root 'instances.local.json'
        if(Test-Path -LiteralPath $configPath){
            [void](Read-ControllerConfig $configPath)
            Assert-NoReparsePoint $manifestPath
            if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'Found configuration without an installation manifest. Select the original installed tool directory.'}
            $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
            if($manifest.schema -ne 1 -or -not (Test-SamePath $manifest.root $candidate.Root)){throw 'Installation manifest belongs to a different directory or has an unsupported schema.'}
            $candidate.Version=[string](Get-ObjectValue $manifest 'version' '0.0.0')
        }else{
            if(-not (Test-Path -LiteralPath (Join-Path $candidate.Root 'src\Launcher.ps1')) -or -not (Test-Path -LiteralPath (Join-Path $candidate.Root 'Start.cmd'))){throw 'Directory is not an existing controller installation.'}
            [void](New-LegacyControllerConfig $LegacySettingsPath $candidate.Root)
            $candidate.Legacy=$true;$candidate.Version='0.1.0'
        }
        $versionPath=Join-Path $candidate.Root 'version.json';Assert-NoReparsePoint $versionPath
        if(Test-Path -LiteralPath $versionPath){
            $version=Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8|ConvertFrom-Json
            if($version.product -ne 'codex-desktop-dual-environment'){throw 'Product version marker does not match.'}
            $candidate.Version=[string]$version.version
        }
        [void][version]::Parse($candidate.Version)
        $candidate.Valid=$true
    }catch{$candidate.Reason=$_.Exception.Message}
    return $candidate
}

function Test-ControllerPayloadCurrent([string]$Source,[string]$Target) {
    $manifestPath=Join-Path $Target 'install-manifest.json'
    if(-not (Test-Path -LiteralPath $manifestPath)){return $false}
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not @($manifest.files | Where-Object {$_.path -eq 'CodexDualController.exe'}).Count){return $false}
    foreach($relative in @(Get-UpgradePayload $Source)){
        $path=Get-UpgradeFilePath $Target $relative
        if(-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path).Hash -ne (Get-FileHash -LiteralPath (Join-Path $Source $relative)).Hash){return $false}
    }
    foreach($entry in $manifest.files){
        $path=Get-UpgradeFilePath $Target $entry.path
        if(-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path).Hash -ne $entry.sha256){return $false}
    }
    return $true
}

function Get-ControllerSetupPlan {
    param(
        [string]$Source,[string]$TargetDirectory,[string[]]$Hints=@(),
        [string]$DefaultDirectory=(Join-Path $env:LOCALAPPDATA 'CodexDualController'),
        [string]$LegacySettingsPath=(Join-Path $env:LOCALAPPDATA 'CodexDualLauncher\settings.json'),
        [string]$ShortcutDirectory=[Environment]::GetFolderPath('Desktop'),[switch]$NoShortcuts
    )
    $sourceRoot=Get-FullDirectory $Source;Assert-NoReparsePoint $sourceRoot
    $sourceVersion=Get-Content -LiteralPath (Join-Path $sourceRoot 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($sourceVersion.product -ne 'codex-desktop-dual-environment'){throw 'Invalid source package.'}
    [void][version]::Parse([string]$sourceVersion.version)
    $plan=[pscustomobject]@{Mode='Install';Source=$sourceRoot;Target=(Get-FullDirectory $DefaultDirectory);Version=$sourceVersion.version;Candidates=@();Reason='未找到已有安装，将进入首次安装。'}
    $roots=@()
    if($TargetDirectory){$roots=@((Get-FullDirectory $TargetDirectory));$plan.Target=$roots[0]}
    elseif((Test-Path -LiteralPath (Join-Path $sourceRoot 'instances.local.json')) -or (Test-Path -LiteralPath (Join-Path $sourceRoot 'install-manifest.json'))){$roots=@($sourceRoot)}
    else{$roots=@($Hints)}
    $seen=@{}
    foreach($root in $roots){
        if([string]::IsNullOrWhiteSpace($root)){continue}
        $full=Get-FullDirectory $root
        if($seen.ContainsKey($full.ToLowerInvariant())){continue};$seen[$full.ToLowerInvariant()]=$true
        Assert-NoReparsePoint $full
        if(-not (Test-Path -LiteralPath $full)){continue}
        if((Test-Path -LiteralPath $full -PathType Container) -and @(Get-ChildItem -LiteralPath $full -Force).Count -eq 0){continue}
        $plan.Candidates+=Get-ControllerInstallCandidate $full $LegacySettingsPath
    }
    if($plan.Candidates.Count -gt 1){$plan.Mode='Choose';$plan.Reason='找到多个安装候选目录，请选择要更新的工具目录。';return $plan}
    if($plan.Candidates.Count -eq 0){
        if(-not $TargetDirectory -and (Test-Path -LiteralPath $LegacySettingsPath)){$plan.Mode='LocateLegacy';$plan.Reason='找到旧版设置，请选择原来的工具目录后继续升级。'}
        if((Test-Path -LiteralPath $plan.Target) -and @(Get-ChildItem -LiteralPath $plan.Target -Force).Count){$plan.Mode='Blocked';$plan.Reason='安装目标不是空目录，请指定已有工具目录或另选一个空目录。'}
        return $plan
    }
    $candidate=$plan.Candidates[0];$plan.Target=$candidate.Root
    if(-not $candidate.Valid){$plan.Mode='Blocked';$plan.Reason=$candidate.Reason;return $plan}
    if([version]$candidate.Version -gt [version]$sourceVersion.version){$plan.Mode='Blocked';$plan.Reason='已安装版本比此安装包更新，拒绝降级覆盖。';return $plan}
    if(-not $NoShortcuts){
        $shortcutPath=Join-Path $ShortcutDirectory 'Codex Dual Controller.lnk';Assert-NoReparsePoint $shortcutPath
        if(Test-Path -LiteralPath $shortcutPath){
            $shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($shortcutPath)
            if(-not (Test-SamePath $link.TargetPath (Join-Path $plan.Target 'CodexDualController.exe')) -or $link.Arguments -ne ''){$plan.Mode='Blocked';$plan.Reason='同名桌面快捷方式属于其他入口，已保留。请用 -ShortcutDirectory 选择其他位置。';return $plan}
        }
    }
    $plan.Mode='Upgrade';$plan.Reason='发现已有安装，将备份并更新工具文件，保留配置和数据。'
    if(-not $candidate.Legacy -and (Test-ControllerPayloadCurrent $sourceRoot $plan.Target)){
        $plan.Mode='Launch';$plan.Reason='工具文件已与安装包一致，直接打开控制面板。'
        if(-not $NoShortcuts -and -not (Test-Path -LiteralPath (Join-Path $ShortcutDirectory 'Codex Dual Controller.lnk'))){$plan.Mode='Upgrade';$plan.Reason='补建缺失的桌面入口。'}
    }
    return $plan
}
