[CmdletBinding()]
param(
    [switch]$PrepareOnly, [switch]$Apply, [switch]$FunctionsOnly,
    [string]$Version='native-title-0.1.0-20261016',
    [string]$Source='' ,
    [string]$Destination='',
    [string]$PreviousInstallation='',
    [string]$ControllerRoot='D:\Backup\Documents\ChatGPT\codex双开\CodexDual-Control',
    [string]$Launcher='E:\Codex-API\Launcher\Start-Codex-API.ps1',
    [string]$NodeExe='E:\New Folder\node.exe',
    [string]$PythonExe='C:\Users\Administrator\AppData\Local\Python\pythoncore-3.14-64\python.exe'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $Source) { $Source=Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'TitleIntegrationLaunch.ps1')

function New-TitleLauncherPatch([string]$Text,[string]$Helper,[string]$HelperHash,[string]$BindingPath,[string]$BindingHash) {
    if ($Text.Contains('# BEGIN CODEX NATIVE TITLE')) { throw 'title-launcher-already-patched' }
    foreach ($path in @($Helper,$BindingPath)) { if ($path -match "['`r`n]") { throw 'title-patch-path-invalid' } }
    $anchor='        Start-Process -FilePath $codexDesktopExe -ArgumentList @("--user-data-dir=$apiDesktopProfile") -WorkingDirectory (Join-Path $apiRoot "Projects")'
    if (($Text.Split(@($anchor),[StringSplitOptions]::None)).Length -ne 2) { throw 'title-launcher-anchor-not-unique' }
    $block=@'
        # BEGIN CODEX NATIVE TITLE v1
        $titleLaunch = $null
        $titleArguments = @()
        try {
            $titleHelper = '__HELPER__'
            if ((Get-FileHash -LiteralPath $titleHelper -Algorithm SHA256).Hash -ne '__HELPER_HASH__') { throw 'Title helper changed.' }
            . $titleHelper
            $titleLaunch = Get-TitleIntegrationLaunch -BindingPath '__BINDING__' -BindingSha256 '__BINDING_HASH__' -ApiHome $apiCodexHome -Profile $apiDesktopProfile -DesktopExecutable $codexDesktopExe
            if ($titleLaunch) { $titleArguments = @($titleLaunch.debugArguments) }
        } catch {
            $titleLaunch = $null
            $titleArguments = @()
            Write-LauncherLog 'Title enhancement unavailable; native startup continues.'
        }
        Start-Process -FilePath $codexDesktopExe -ArgumentList (@("--user-data-dir=$apiDesktopProfile") + $titleArguments) -WorkingDirectory (Join-Path $apiRoot "Projects")
        if ($titleLaunch) {
            try {
                $titleDaemonArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $titleLaunch.daemon + '" -BindingPath "' + $titleLaunch.bindingPath + '" -BindingSha256 "' + $titleLaunch.bindingSha256 + '"'
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $titleDaemonArgs -WindowStyle Hidden -WorkingDirectory $apiRoot
                Write-LauncherLog 'Title enhancement queued for this isolated API launch.'
            } catch { Write-LauncherLog 'Title enhancement loader did not start; native startup continues.' }
        }
        # END CODEX NATIVE TITLE v1
'@
    $newline=if($Text.Contains("`r`n")){"`r`n"}else{"`n"}
    $block=$block.Replace("`r`n","`n").Replace("`n",$newline).Replace('__HELPER__',$Helper).Replace('__HELPER_HASH__',$HelperHash).Replace('__BINDING__',$BindingPath).Replace('__BINDING_HASH__',$BindingHash)
    return [pscustomobject]@{Before=$anchor;After=$block;Text=$Text.Replace($anchor,$block)}
}
function Assert-TitlePowerShellSyntax([string]$Text) {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if (@($errors).Count) { throw 'title-powershell-syntax-invalid' }
}
function New-TitleUpgradePatch([string]$Text,[string]$OldInstallation,[string]$LauncherPath,[string]$Helper,[string]$HelperHash,[string]$BindingPath,[string]$BindingHash) {
    # Updating an existing title block is opt-in. Historical runtime pins may be
    # obsolete, but the exact old launcher artifacts and binding must still match.
    Assert-TitleRegularPath $OldInstallation
    $oldPlanPath=Join-Path $OldInstallation 'install-plan.json';Assert-TitleRegularPath $oldPlanPath
    if((Get-Item -LiteralPath $oldPlanPath).Length -gt 262144){throw 'title-old-plan-oversize'}
    $old=Get-Content -LiteralPath $oldPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($old.schema -ne 1 -or -not (Test-TitlePath $old.destination $OldInstallation) -or -not (Test-TitlePath $old.launcher $LauncherPath) -or
       -not (Test-TitlePath $old.backupPath (Join-Path $OldInstallation 'launcher.original.ps1')) -or
       -not (Test-TitlePath $old.stagedPath (Join-Path $OldInstallation 'launcher.staged.ps1'))){throw 'title-old-plan-mismatch'}
    $oldBinding=Join-Path $OldInstallation 'binding.json'
    foreach($path in @($old.backupPath,$old.stagedPath,$oldBinding)){Assert-TitleRegularPath $path}
    if((Get-TitleSha256 $old.backupPath) -ne $old.originalHash -or (Get-TitleSha256 $old.stagedPath) -ne $old.stagedHash -or (Get-TitleSha256 $oldBinding) -ne $old.bindingHash){throw 'title-old-artifact-changed'}
    $oldBefore=[string]$old.before;$oldAfter=[string]$old.after
    if(-not $oldBefore -or -not $oldAfter -or -not $oldAfter.Contains('# BEGIN CODEX NATIVE TITLE v1') -or
       -not $oldAfter.Contains('# END CODEX NATIVE TITLE v1') -or -not $oldAfter.Contains($oldBinding) -or
       -not $oldAfter.Contains([string]$old.bindingHash) -or ($Text.Split(@($oldAfter),[StringSplitOptions]::None)).Length -ne 2){throw 'title-old-block-drifted'}
    $oldOriginal=[IO.File]::ReadAllText($old.backupPath);$oldStaged=[IO.File]::ReadAllText($old.stagedPath)
    if(($oldOriginal.Split(@($oldBefore),[StringSplitOptions]::None)).Length -ne 2 -or $oldOriginal.Replace($oldBefore,$oldAfter) -cne $oldStaged){throw 'title-old-plan-inconsistent'}
    # The first installation's anchor is invariant even when upgrading a previous
    # upgrade whose plan.before is itself a complete title block.
    $anchor='        Start-Process -FilePath $codexDesktopExe -ArgumentList @("--user-data-dir=$apiDesktopProfile") -WorkingDirectory (Join-Path $apiRoot "Projects")'
    $unwrapped=$Text.Replace($oldAfter,$anchor)
    $patch=New-TitleLauncherPatch $unwrapped $Helper $HelperHash $BindingPath $BindingHash
    return [pscustomobject]@{Before=$oldAfter;After=$patch.After;Text=$patch.Text}
}
function Invoke-TitleOfflineCompatibilityProbe([string]$Python,[string]$SourceRoot,[string]$Cli) {
    $cliHash=Get-TitleSha256 $Cli
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Python
    # -I disables user site and PYTHON* imports; only this reviewed bundle is inserted.
    $code="import sys,runpy;root=sys.argv.pop(1);sys.path.insert(0,root);sys.argv[0]=root+'/probe_cli.py';runpy.run_path(sys.argv[0],run_name='__main__')"
    $start.Arguments=(@('-I','-B','-c',(ConvertTo-TitleQuotedArgument $code),(ConvertTo-TitleQuotedArgument $SourceRoot),'--cli',(ConvertTo-TitleQuotedArgument $Cli)) -join ' ')
    $start.WorkingDirectory=$SourceRoot
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $allowed=@('SystemRoot','WINDIR','PATH','TEMP','TMP','USERPROFILE','LOCALAPPDATA','APPDATA','COMSPEC','SystemDrive','NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE','PROCESSOR_IDENTIFIER','PATHEXT')
    foreach($name in @($start.EnvironmentVariables.Keys)){if($name -notin $allowed){$start.EnvironmentVariables.Remove($name)}}
    $probe=New-Object Diagnostics.Process
    $probe.StartInfo=$start
    try {
        [void]$probe.Start()
        $stdout=$probe.StandardOutput.ReadToEndAsync()
        $stderr=$probe.StandardError.ReadToEndAsync()
        if(-not $probe.WaitForExit(55000)){throw 'title-offline-probe-timeout'}
        $probe.WaitForExit()
        if($probe.ExitCode -ne 0){throw 'title-offline-probe-failed'}
        $result=$stdout.GetAwaiter().GetResult() | ConvertFrom-Json
        if($result.passed -isnot [bool] -or -not $result.passed -or @($result.toolNames).Count -ne 0 -or
            $result.environmentHeaderVerified -isnot [bool] -or -not $result.environmentHeaderVerified){throw 'title-offline-probe-incompatible'}
        if((Get-TitleSha256 $Cli) -ne $cliHash){throw 'title-cli-changed-during-probe'}
        return @{cliSha256=$cliHash;passed=$true;toolCount=0;environmentHeaderVerified=$true}
    } finally {
        try{if(-not $probe.HasExited){$probe.Kill();[void]$probe.WaitForExit(3000)}}catch{}
        $probe.Dispose()
    }
}
if ($FunctionsOnly) { return }
if ($PrepareOnly -and $Apply) { throw 'Choose PrepareOnly or Apply.' }
if ($Version -notmatch '^[a-zA-Z0-9._-]+$') { throw 'Invalid version.' }
if (-not $Destination) { $Destination=Join-Path 'E:\Codex-API\TitleSuggestions' $Version }
$Destination=[IO.Path]::GetFullPath($Destination)
$manifestPath=Join-Path $Destination 'install-plan.json'
$bindingPath=Join-Path $Destination 'binding.json'

if ($Apply) {
    Assert-TitleRegularPath $manifestPath
    $plan=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($plan.schema -ne 1 -or -not (Test-TitlePath $plan.destination $Destination) -or -not (Test-TitlePath $plan.launcher $Launcher)) { throw 'title-install-plan-mismatch' }
    [void](Read-TitleBinding $bindingPath $plan.bindingHash)
    if ((Get-TitleSha256 $Launcher) -ne $plan.originalHash) { throw 'title-launcher-drifted-since-prepare' }
    if ((Get-TitleSha256 $plan.backupPath) -ne $plan.originalHash -or (Get-TitleSha256 $plan.stagedPath) -ne $plan.stagedHash) { throw 'title-install-artifact-changed' }
    $staged=[IO.File]::ReadAllText($plan.stagedPath)
    Assert-TitlePowerShellSyntax $staged
    Assert-TitleRegularPath $Launcher
    $temp=$Launcher+'.title-'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::Copy($plan.stagedPath,$temp,$false)
        if ((Get-TitleSha256 $Launcher) -ne $plan.originalHash) { throw 'title-launcher-concurrent-change' }
        [IO.File]::Replace($temp,$Launcher,[NullString]::Value)
    } finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force} }
    if ((Get-TitleSha256 $Launcher) -ne $plan.stagedHash) { throw 'title-install-verification-failed' }
    Write-TitleState (Join-Path $Destination 'applied.json') @{schema=1;launcher=$Launcher;installedHash=$plan.stagedHash;installedAt=[DateTime]::UtcNow.ToString('o')}
    [pscustomobject]@{state='installed-next-complete-start';destination=$Destination;launcher=$Launcher;restarted=$false}
    return
}

if (Test-Path -LiteralPath $Destination) { throw 'Destination exists; use Apply after review or prepare a new version directory.' }
Assert-TitleRegularPath $Launcher
Assert-TitleRegularPath $ControllerRoot
foreach ($exe in @($NodeExe,$PythonExe)) { Assert-TitleRegularPath $exe }
. (Join-Path $ControllerRoot 'src\Instances.ps1')
$configPath=Join-Path $ControllerRoot 'instances.local.json'
$config=Read-ControllerConfig $configPath
$api=@($config.instances | Where-Object role -eq 'api')
if ($api.Count -ne 1 -or -not (Test-TitlePath $api[0].externalLauncher $Launcher)) { throw 'title-api-launcher-mismatch' }
$instance=$api[0]
$status=Get-InstanceStatus $config $instance
if ($status.State -ne 'Running') { throw 'Prepare requires a running API instance to attest its Desktop and direct CLI child.' }
$process=Assert-CurrentIdentity $instance $status.Process
$cli=@(Get-ProcessSnapshot | Where-Object { $_.ParentId -eq $process.Id -and [IO.Path]::GetFileName($_.Path) -ieq 'codex.exe' })
if ($cli.Count -ne 1) { throw 'title-cli-child-not-unique' }
$required=@('title_service.py','native_context.py','probe_cli.py','native/loader.mjs','native/worker.py','native/renderer.js','native/TitleIntegrationLaunch.ps1','native/Start-TitleIntegration.ps1','native/Install-NativeTitle.ps1','native/Rollback-NativeTitle.ps1')
foreach ($relative in $required) { Assert-TitleRegularPath (Join-Path $Source $relative) }
[void][IO.Directory]::CreateDirectory($Destination)
Assert-TitleRegularPath $Destination
[void][IO.Directory]::CreateDirectory((Join-Path $Destination 'native'))
[void][IO.Directory]::CreateDirectory((Join-Path $Destination 'state'))
$files=@()
foreach ($relative in $required) {
    $sourcePath=Join-Path $Source $relative
    $targetPath=Join-Path $Destination $relative
    [IO.File]::Copy($sourcePath,$targetPath,$false)
    $files+=@{path=$relative;sha256=(Get-TitleSha256 $targetPath)}
}
$compatibility=Invoke-TitleOfflineCompatibilityProbe $PythonExe $Destination $cli[0].Path
Write-TitleState (Join-Path $Destination 'compatibility.json') $compatibility
$dependencies=@()
foreach ($name in @('Instances.ps1','Core.ps1','Native.cs','TomlConfig.cs','Preferences.ps1','ApiManagement.ps1','QuestionBridgeLaunch.ps1')) {
    $path=Join-Path $ControllerRoot ('src\'+$name)
    Assert-TitleRegularPath $path
    $dependencies+=@{path=$path;sha256=(Get-TitleSha256 $path)}
}
$binding=[ordered]@{
    schema=1;version=$Version;instanceId=$instance.id;home=$instance.home;profile=$instance.profile;model='gpt-6-luna'
    desktop=@{path=$process.Path;sha256=(Get-TitleSha256 $process.Path)}
    cli=@{path=$cli[0].Path;sha256=(Get-TitleSha256 $cli[0].Path)}
    node=@{path=$NodeExe;sha256=(Get-TitleSha256 $NodeExe)}
    python=@{path=$PythonExe;sha256=(Get-TitleSha256 $PythonExe)}
    controller=@{directory=$ControllerRoot;configPath=$configPath;dependencies=$dependencies}
    installRoot=$Destination;stateDirectory=(Join-Path $Destination 'state');bundleFiles=$files;compatibility=$compatibility
}
Write-TitleState $bindingPath $binding
$bindingHash=Get-TitleSha256 $bindingPath
$helper=Join-Path $Destination 'native\TitleIntegrationLaunch.ps1'
$originalHash=Get-TitleSha256 $Launcher
$original=[IO.File]::ReadAllText($Launcher)
$patch=if($PreviousInstallation){New-TitleUpgradePatch $original $PreviousInstallation $Launcher $helper (Get-TitleSha256 $helper) $bindingPath $bindingHash}else{New-TitleLauncherPatch $original $helper (Get-TitleSha256 $helper) $bindingPath $bindingHash}
Assert-TitlePowerShellSyntax $patch.Text
$backup=Join-Path $Destination 'launcher.original.ps1'
$staged=Join-Path $Destination 'launcher.staged.ps1'
[IO.File]::Copy($Launcher,$backup,$false)
# Preserve BOM policy as well as all original text outside the one replacement.
$bytes=[IO.File]::ReadAllBytes($Launcher)
$hasBom=$bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
[IO.File]::WriteAllText($staged,$patch.Text,(New-Object Text.UTF8Encoding($hasBom)))
$plan=[ordered]@{schema=1;destination=$Destination;launcher=$Launcher;originalHash=$originalHash;stagedHash=(Get-TitleSha256 $staged);bindingHash=$bindingHash;backupPath=$backup;stagedPath=$staged;before=$patch.Before;after=$patch.After;preparedAt=[DateTime]::UtcNow.ToString('o')}
Write-TitleState $manifestPath $plan
[void](Read-TitleBinding $bindingPath $bindingHash)
[pscustomobject]@{state='prepared-only';destination=$Destination;plan=$manifestPath;stagedLauncher=$staged;changedLiveLauncher=$false}
