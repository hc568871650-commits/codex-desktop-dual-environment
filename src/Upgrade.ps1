Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Instances.ps1"

function Assert-UpgradeNotRunning([string]$Root) {
    foreach($process in @(Get-ProcessSnapshot)){
        if(Test-SamePath $process.Path (Join-Path $Root 'CodexDualController.exe')){throw '请先退出此目录的双环境控制器再升级；两套 Codex 不需要退出。'}
        if($process.Path -and [IO.Path]::GetFileName($process.Path) -in @('powershell.exe','pwsh.exe') -and $process.Command){
            $argsList=[CodexDual.Native]::Arguments($process.Command)
            foreach($arg in $argsList){foreach($relative in @('src\Controller.ps1','src\Launcher.ps1')){if(Test-SamePath $arg (Join-Path $Root $relative)){throw '请先关闭旧启动器/控制器窗口；两套 Codex 不需要退出。'}}}
        }
    }
}
function Get-UpgradePayload([string]$Source) {
    $result=@()
    foreach($part in @('.gitignore','version.json','Start.cmd','Install.cmd','Controller.cmd','Uninstall.cmd','Configure.cmd','Upgrade.cmd','Rollback.cmd','src','scripts','assets','config','docs','README.md')){
        $path=Join-Path $Source $part
        if(-not (Test-Path -LiteralPath $path)){throw "升级包不完整：$part"}
        $items=if(Test-Path -LiteralPath $path -PathType Container){@(Get-ChildItem -LiteralPath $path -File -Recurse)}else{@(Get-Item -LiteralPath $path)}
        foreach($item in $items){Assert-NoReparsePoint $item.FullName;$result+=$item.FullName.Substring($Source.Length+1)}
    }
    return $result
}
function New-LegacyControllerConfig([string]$SettingsPath,[string]$Target) {
    Assert-NoReparsePoint $SettingsPath
    if(-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)){throw '没有找到 0.1 设置。请使用 -LegacySettingsPath 指定旧 settings.json；不会猜测或重新创建 API 数据。'}
    $legacy=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $api=Get-FullDirectory $legacy.root;$official=Get-FullDirectory $legacy.officialHome
    Assert-NoReparsePoint $api;Assert-NoReparsePoint $official
    $marker=Join-Path $api '.codex-dual.json'
    if(-not (Test-Path -LiteralPath $marker)){throw '旧 API 目录缺少本工具标记，不自动接管。'}
    $meta=Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
    if($meta.product -ne $script:ProductId){throw '旧 API 目录标记不匹配。'}
    # Check existence only. Never read/copy/decrypt credentials or authentication during migration.
    foreach($relative in @('CodexHome\config.toml','CodexHome\auth.json','Credentials\api-key.dpapi')){if(-not (Test-Path -LiteralPath (Join-Path $api $relative) -PathType Leaf)){throw "旧 API 环境不完整：$relative"}}
    # Preserve 0.1 official defaults/custom TOML verbatim; do not invent an effective task path.
    $officialProjectless='';$officialProjectlessMode='inherit'
    try{$officialProjectless=Get-ConfiguredProjectless $official;$officialProjectlessMode='explicit'}catch{}
    $apiProjectless=Get-ConfiguredProjectless (Join-Path $api 'CodexHome')
    if(-not (Test-SamePath $apiProjectless (Join-Path $api 'Projectless'))){throw '旧 API 无项目目录不是托管目录约定，需人工确认后使用已有环境注册流程。'}
    return [pscustomobject]@{schema=1;displayName='Codex 双环境';stateDirectory=(Join-Path $Target 'state');instances=@(
        [pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='official';home=$official;profile='';projects=(Join-Path $Target 'OfficialProjects');projectless=$officialProjectless;projectlessMode=$officialProjectlessMode;launchMode='official';executable=[string]$legacy.executable},
        [pscustomobject]@{id=[Guid]::NewGuid().ToString('N');role='api';home=(Join-Path $api 'CodexHome');profile=(Join-Path $api 'DesktopProfile');projects=(Join-Path $api 'Projects');projectless=$apiProjectless;launchMode='managed-api';apiRoot=$api;executable=[string]$legacy.executable}
    )}
}
function Get-UpgradeFilePath([string]$Root,[string]$Relative) {
    if([IO.Path]::IsPathRooted($Relative)){throw '升级清单不允许绝对文件路径。'}
    $path=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if(-not $path.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw '升级清单越出目标目录。'}
    Assert-NoReparsePoint $path
    return $path
}
function Invoke-UpgradeLocked([string]$Target,[scriptblock]$Action) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try{$hash=[BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-FullDirectory $Target).ToLowerInvariant()))).Replace('-','')}finally{$algorithm.Dispose()}
    $mutex=New-Object Threading.Mutex($false,('Local\CodexDual.Upgrade.'+$hash));$held=$false
    try{try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(-not $held){throw '此目录已有升级或回滚操作，请稍后重试。'};& $Action}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Invoke-ControllerUpgrade {
    param([string]$Source,[string]$Target,[string]$LegacySettingsPath,[switch]$CheckOnly,[string]$ShortcutDirectory)
    Invoke-UpgradeLocked $Target {Invoke-ControllerUpgradeCore $Source $Target $LegacySettingsPath -CheckOnly:$CheckOnly -ShortcutDirectory $ShortcutDirectory}
}
function Invoke-ControllerUpgradeCore {
    param([string]$Source,[string]$Target,[string]$LegacySettingsPath,[switch]$CheckOnly,[string]$ShortcutDirectory)
    $sourceRoot=Get-FullDirectory $Source;$targetRoot=Get-FullDirectory $Target
    Assert-NoReparsePoint $sourceRoot;Assert-NoReparsePoint $targetRoot
    $manifestProof=Join-Path $targetRoot 'install-manifest.json';Assert-NoReparsePoint $manifestProof
    $hasManifest=$false
    if(Test-Path -LiteralPath $manifestProof){$proof=Get-Content -LiteralPath $manifestProof -Raw -Encoding UTF8|ConvertFrom-Json;$hasManifest=$proof.schema -eq 1 -and (Test-SamePath $proof.root $targetRoot)}
    if(-not $hasManifest -and (-not (Test-Path -LiteralPath (Join-Path $targetRoot 'src\Core.ps1')) -or -not (Test-Path -LiteralPath (Join-Path $targetRoot 'Start.cmd')))){throw '目标不像本工具的旧解压/安装目录，拒绝覆盖。'}
    Assert-UpgradeNotRunning $targetRoot
    $payload=@(Get-UpgradePayload $sourceRoot)
    $configPath=Join-Path $targetRoot 'instances.local.json'
    $migrating=-not (Test-Path -LiteralPath $configPath)
    if($migrating){$config=New-LegacyControllerConfig $LegacySettingsPath $targetRoot}else{$config=Read-ControllerConfig $configPath}
    # Legacy official cwd is preserved separately from its projectless root.
    if($migrating){$config.instances[0].projects=Join-Path $targetRoot 'OfficialProjects'}
    foreach($instance in $config.instances){foreach($key in @('home','profile','projectless')){
        if($instance.$key -and (Test-PathOverlap $targetRoot $instance.$key)){throw '升级目标与环境数据重叠。请使用独立工具目录，不覆盖数据目录。'}
    }}
    foreach($relative in $payload+@('CodexDualController.exe','instances.local.json','install-manifest.json')){[void](Get-UpgradeFilePath $targetRoot $relative)}
    $sourceVersion=Get-Content -LiteralPath (Join-Path $sourceRoot 'version.json') -Raw|ConvertFrom-Json
    if($sourceVersion.product -ne 'codex-desktop-dual-environment'){throw '升级包产品标记错误。'}
    $targetVersionPath=Join-Path $targetRoot 'version.json';Assert-NoReparsePoint $targetVersionPath
    if(Test-Path -LiteralPath $targetVersionPath){
        $targetVersion=Get-Content -LiteralPath $targetVersionPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($targetVersion.product -ne $sourceVersion.product){throw '目标目录属于其他产品，拒绝覆盖。'}
        if([version]$targetVersion.version -gt [version]$sourceVersion.version){throw '已安装版本比此安装包更新，拒绝降级覆盖。'}
    }
    $current=$null;$manifestPath=Join-Path $targetRoot 'install-manifest.json'
    if(Test-Path -LiteralPath $manifestPath){$current=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json;if(-not (Test-SamePath $current.root $targetRoot)){throw '安装清单与目标目录不符。'}}
    if($current -and [version](Get-ObjectValue $current 'version' '0.0.0') -gt [version]$sourceVersion.version){throw '安装清单记录了更新版本，拒绝降级覆盖。'}
    $upToDate=-not $migrating -and (Test-Path -LiteralPath (Join-Path $targetRoot 'CodexDualController.exe')) -and $null -ne $current
    if($upToDate -and -not @($current.files|Where-Object {$_.path -eq 'CodexDualController.exe'}).Count){$upToDate=$false}
    foreach($relative in $payload){$destination=Get-UpgradeFilePath $targetRoot $relative;if(-not (Test-Path -LiteralPath $destination) -or (Get-FileHash -LiteralPath $destination).Hash -ne (Get-FileHash -LiteralPath (Join-Path $sourceRoot $relative)).Hash){$upToDate=$false}}
    if($upToDate){
        foreach($entry in $current.files){$path=Get-UpgradeFilePath $targetRoot $entry.path;if(-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path).Hash -ne $entry.sha256){$upToDate=$false;break}}
    }
    $newShortcut=$null;$shortcutPath=$null
    if($ShortcutDirectory){
        $ShortcutDirectory=Get-FullDirectory $ShortcutDirectory;Assert-NoReparsePoint $ShortcutDirectory
        $shortcutPath=Join-Path $ShortcutDirectory 'Codex Dual Controller.lnk';Assert-NoReparsePoint $shortcutPath
        if(Test-Path -LiteralPath $shortcutPath){
            $shell=New-Object -ComObject WScript.Shell;$existingLink=$shell.CreateShortcut($shortcutPath)
            if(-not (Test-SamePath $existingLink.TargetPath (Join-Path $targetRoot 'CodexDualController.exe')) -or $existingLink.Arguments -ne ''){throw '桌面已有其他入口使用同名快捷方式，保留原文件。请用 -ShortcutDirectory 选择其他位置。'}
        }else{$upToDate=$false}
    }
    if($upToDate){return [pscustomobject]@{Status='AlreadyCurrent';Target=$targetRoot;Version=$sourceVersion.version}}
    if($CheckOnly){return [pscustomobject]@{Status='Ready';Target=$targetRoot;MigrateLegacy=$migrating;InPlace=(Test-SamePath $sourceRoot $targetRoot);Version=$sourceVersion.version}}
    $snapshot=Join-Path $targetRoot ('upgrades\'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N'))
    Assert-NoReparsePoint $snapshot
    [void][IO.Directory]::CreateDirectory((Join-Path $snapshot 'staged'))
    [void][IO.Directory]::CreateDirectory((Join-Path $snapshot 'before'))
    $staged=Join-Path $snapshot 'staged'
    foreach($relative in $payload){$path=Get-UpgradeFilePath $staged $relative;[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));[IO.File]::Copy((Join-Path $sourceRoot $relative),$path,$false)}
    & (Join-Path $sourceRoot 'scripts\Build-ControllerHost.ps1') -Destination (Join-Path $staged 'CodexDualController.exe') | Out-Null
    if($migrating){Write-AtomicText (Join-Path $staged 'instances.local.json') ($config|ConvertTo-Json -Depth 8);[void](Read-ControllerConfig (Join-Path $staged 'instances.local.json'))}
    $manifest=[ordered]@{schema=1;root=$targetRoot;version=$sourceVersion.version;files=@();shortcuts=@();retainedData=@($config.instances.home);created=[DateTime]::UtcNow.ToString('o')}
    if($current){$manifest.shortcuts=@($current.shortcuts)}
    if($shortcutPath -and -not (Test-Path -LiteralPath $shortcutPath)){
        $stagedLink=Join-Path $staged 'new-controller.lnk'
        # Create through COM in the chosen shortcut directory; staging may contain Unicode
        # characters unsupported by WScript on ACP 1252. Byte copying has no such limitation.
        [void][IO.Directory]::CreateDirectory($ShortcutDirectory)
        $temporaryLink=Join-Path $ShortcutDirectory ('.CodexDual-'+[Guid]::NewGuid().ToString('N')+'.lnk')
        try{
            $shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($temporaryLink)
            $link.TargetPath=Join-Path $targetRoot 'CodexDualController.exe';$link.Arguments='';$link.WorkingDirectory=$targetRoot;$link.IconLocation=Join-Path $targetRoot 'assets\controller.ico';$link.Save()
            [IO.File]::Copy($temporaryLink,$stagedLink,$false)
        }finally{if(Test-Path -LiteralPath $temporaryLink){[IO.File]::Delete($temporaryLink)}}
        $newShortcut=@{path=$shortcutPath;sha256=(Get-FileHash -LiteralPath $stagedLink).Hash}
        $manifest.shortcuts=@($manifest.shortcuts|Where-Object {-not (Test-SamePath $_.path $shortcutPath)})+@($newShortcut)
    }
    foreach($relative in $payload+@('CodexDualController.exe')){$manifest.files+=@{path=$relative;sha256=(Get-FileHash -LiteralPath (Join-Path $staged $relative)).Hash}}
    Write-AtomicText (Join-Path $staged 'install-manifest.json') ($manifest|ConvertTo-Json -Depth 8)
    $changes=@();$relativeFiles=$payload+@('CodexDualController.exe','install-manifest.json');if($migrating){$relativeFiles+=@('instances.local.json')}
    foreach($relative in $relativeFiles){
        $destination=Get-UpgradeFilePath $targetRoot $relative;$new=Get-UpgradeFilePath $staged $relative
        $exists=Test-Path -LiteralPath $destination -PathType Leaf;$newHash=(Get-FileHash -LiteralPath $new).Hash
        if($exists -and (Get-FileHash -LiteralPath $destination).Hash -eq $newHash){continue}
        if($exists){
            if((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReadOnly){throw "旧工具文件为只读，未更新：$relative"}
            $probe=[IO.File]::Open($destination,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$probe.Dispose()
        }
        if($exists){$backup=Get-UpgradeFilePath (Join-Path $snapshot 'before') $relative;[void][IO.Directory]::CreateDirectory((Split-Path $backup -Parent));[IO.File]::Copy($destination,$backup,$false)}
        $changes+=@{path=$relative;existed=[bool]$exists;newHash=$newHash;oldHash=if($exists){(Get-FileHash -LiteralPath $backup).Hash}else{$null}}
    }
    $journal=[ordered]@{schema=1;target=$targetRoot;version=$sourceVersion.version;inPlace=(Test-SamePath $sourceRoot $targetRoot);status='Prepared';files=$changes;createdDirectories=@();shortcuts=@()}
    if($newShortcut){$journal.shortcuts=@($newShortcut)}
    $journalPath=Join-Path $snapshot 'upgrade.local.json'
    Write-AtomicText $journalPath ($journal|ConvertTo-Json -Depth 8)
    Assert-UpgradeNotRunning $targetRoot
    $shortcutCreated=$false;$upgradeStage='更新工具文件';$attemptedChanges=@()
    try {
        foreach($change in $changes){
            $destination=Get-UpgradeFilePath $targetRoot $change.path
            if($change.existed){
                if(-not (Test-Path -LiteralPath $destination) -or (Get-FileHash -LiteralPath $destination).Hash -ne $change.oldHash){throw ('备份后工具文件已变化，停止更新：'+$change.path)}
            }elseif(Test-Path -LiteralPath $destination){throw ('目标文件已被其他程序创建，停止更新：'+$change.path)}
            [void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
            $attemptedChanges+=$change
            [IO.File]::Copy((Join-Path $staged $change.path),$destination,$change.existed)
        }
        if($newShortcut){$upgradeStage='创建桌面入口';[void][IO.Directory]::CreateDirectory($ShortcutDirectory);[IO.File]::Copy($stagedLink,$shortcutPath,$false);$shortcutCreated=$true}
        if($migrating -and -not (Test-Path -LiteralPath $config.instances[0].projects)){[void][IO.Directory]::CreateDirectory($config.instances[0].projects);$journal.createdDirectories+=@($config.instances[0].projects)}
        $upgradeStage='保存升级记录';$journal.status='Completed';Write-AtomicText $journalPath ($journal|ConvertTo-Json -Depth 8)
    }catch{
        $upgradeError=$_
        $restoreErrors=@()
        if($shortcutCreated){try{if((Get-FileHash -LiteralPath $shortcutPath).Hash -ne $newShortcut.sha256){throw '快捷方式已变化'};[IO.File]::Delete($shortcutPath)}catch{$restoreErrors+=$shortcutPath}}
        foreach($change in $attemptedChanges){try{
            $destination=Get-UpgradeFilePath $targetRoot $change.path
            $exists=Test-Path -LiteralPath $destination -PathType Leaf
            if(-not $exists -and -not $change.existed){continue}
            if(-not $exists){throw '工具文件已被移除'}
            $actualHash=(Get-FileHash -LiteralPath $destination).Hash
            if($change.existed -and $actualHash -eq $change.oldHash){continue}
            if($actualHash -ne $change.newHash){throw '工具文件已变化'}
            if($change.existed){
                $backup=Get-UpgradeFilePath (Join-Path $snapshot 'before') $change.path
                if((Get-FileHash -LiteralPath $backup).Hash -ne $change.oldHash){throw '回滚备份损坏'}
                [IO.File]::Copy($backup,$destination,$true)
            }else{[IO.File]::Delete($destination)}
        }catch{$restoreErrors+=$change.path}}
        $journal.status=if($restoreErrors.Count){'RollbackIncomplete'}else{'FailedRolledBack'}
        try{Write-AtomicText $journalPath ($journal|ConvertTo-Json -Depth 8)}catch{Write-Warning '升级失败记录无法补写，原始异常保留。'}
        if($restoreErrors.Count){Write-Warning ('部分工具文件无法自动恢复，保留备份供恢复：'+($restoreErrors -join ', '));throw $upgradeError}
        Write-Warning ('升级失败，阶段：'+$upgradeStage+'。工具文件已回退，用户数据未更改。')
        throw $upgradeError
    }
    return [pscustomobject]@{Status='Upgraded';Target=$targetRoot;Version=$sourceVersion.version;MigratedLegacy=$migrating;Snapshot=$snapshot;InPlace=$journal.inPlace}
}

function Undo-ControllerUpgrade([string]$Snapshot) {
    $snapshotRoot=Get-FullDirectory $Snapshot;Assert-NoReparsePoint $snapshotRoot
    $journal=Get-Content -LiteralPath (Join-Path $snapshotRoot 'upgrade.local.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Invoke-UpgradeLocked $journal.target {Undo-ControllerUpgradeCore $Snapshot}
}
function Undo-ControllerUpgradeCore([string]$Snapshot) {
    $snapshotRoot=Get-FullDirectory $Snapshot;Assert-NoReparsePoint $snapshotRoot
    $journal=Get-Content -LiteralPath (Join-Path $snapshotRoot 'upgrade.local.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $target=Get-FullDirectory $journal.target
    if($journal.schema -ne 1 -or $journal.status -ne 'Completed' -or -not $snapshotRoot.StartsWith($target+'\upgrades\',[StringComparison]::OrdinalIgnoreCase)){throw '不是可回滚的升级记录。'}
    Assert-UpgradeNotRunning $target
    $shortcuts=@(Get-ObjectValue $journal 'shortcuts' @())
    foreach($shortcut in $shortcuts){
        $path=Get-FullDirectory $shortcut.path;Assert-NoReparsePoint $path
        if([IO.Path]::GetExtension($path) -ne '.lnk'){throw '回滚快捷方式记录无效。'}
        if((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path).Hash -ne $shortcut.sha256){throw '新增快捷方式已被修改，停止回滚以保留改动。'}
    }
    foreach($change in $journal.files){
        $path=Get-UpgradeFilePath $target $change.path
        if(-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path).Hash -ne $change.newHash){throw '升级后工具文件或控制配置已变化，停止回滚以保留改动。'}
        if($change.existed){$backup=Get-UpgradeFilePath (Join-Path $snapshotRoot 'before') $change.path;if(-not (Test-Path -LiteralPath $backup) -or (Get-FileHash -LiteralPath $backup).Hash -ne $change.oldHash){throw '回滚备份损坏，停止操作。'}}
    }
    foreach($change in $journal.files){$path=Get-UpgradeFilePath $target $change.path;if($change.existed){[IO.File]::Copy((Join-Path $snapshotRoot ('before\'+$change.path)),$path,$true)}else{[IO.File]::Delete($path)}}
    foreach($shortcut in $shortcuts){if(Test-Path -LiteralPath $shortcut.path){[IO.File]::Delete($shortcut.path)}}
    $journal.status='RolledBack';Write-AtomicText (Join-Path $snapshotRoot 'upgrade.local.json') ($journal|ConvertTo-Json -Depth 8)
    '已回滚工具文件。用户数据、原 0.1 设置及回滚记录保留。'
}
