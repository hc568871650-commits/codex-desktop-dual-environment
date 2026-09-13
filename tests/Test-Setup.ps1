$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Setup.ps1"
$source=[IO.Path]::GetFullPath("$PSScriptRoot\..")
$root=Join-Path $source ('test-results\setup-'+[Guid]::NewGuid().ToString('N'))
$target=Join-Path $root 'CustomTool';$default=Join-Path $root 'Default';$legacy=Join-Path $root 'absent-settings.json'
$links=Join-Path $root 'Links';$registry='HKCU:\Software\CodexDualController.SetupTests.'+[Guid]::NewGuid().ToString('N')
$script:passed=0
function Check($Value,$Message){if(-not $Value){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
function MustThrow([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $Message}
function Plan([string[]]$Roots){Get-ControllerSetupPlan -Source $source -Hints $Roots -DefaultDirectory $default -LegacySettingsPath $legacy -ShortcutDirectory $links}
$fixture=$null
try{
    Check ((Plan @()).Mode -eq 'Install') 'No installation selects fresh install'
    Check (-not (Test-Path $default)) 'Discovery creates no target directory'
    $key=ConvertTo-SecureString 'setup-fixture-key' -AsPlainText -Force
    & "$source\scripts\Bootstrap.ps1" -TargetDirectory $target -DataDirectory (Join-Path $root 'Data') -OfficialHome (Join-Path $root 'Official') -Executable "$env:SystemRoot\System32\notepad.exe" -BaseUrl 'https://example.com/v1' -Model 'fixture' -ApiKey $key -NoShortcuts -NoLaunch -NonInteractive -RegistryPath $registry | Out-Null
    Check (Test-Path (Join-Path $target 'CodexDualController.exe')) 'Unified entry installs into an empty custom directory'
    $configPath=Join-Path $target 'instances.local.json';$configHash=(Get-FileHash $configPath).Hash
    $config=Read-ControllerConfig $configPath
    $protected=@($configPath,(Join-Path $config.instances[0].home 'config.toml'),(Join-Path $config.instances[1].home 'config.toml'),(Join-Path $config.instances[1].home 'auth.json'),(Join-Path $config.instances[1].apiRoot 'Credentials\api-key.dpapi'))
    $hashes=@{};foreach($path in $protected){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
    $hints=@(Get-ControllerSetupHints -DefaultDirectory $default -RegistryPath $registry -StartupRegistryPath ($registry+'\Run') -ShortcutDirectory $links -Snapshot @())
    Check ($target -in $hints) 'Custom installation is discoverable from its registration'
    Check ((Plan @($target,$target.ToUpperInvariant(),(Join-Path $root 'stale'))).Candidates.Count -eq 1) 'Repeated hints deduplicate and nonexistent stale paths are ignored'
    Check ((Plan @($target)).Mode -eq 'Upgrade') 'Missing desktop entry selects repair even at the same version'
    Check ((Get-ControllerSetupPlan -Source $source -Hints @($target) -DefaultDirectory $default -LegacySettingsPath $legacy -NoShortcuts).Mode -eq 'Launch') 'Complete same-version installation simply launches when shortcuts are disabled'

    # Full automatic branch uses discovered roots, with no explicit target or API credentials.
    $result=@(& "$source\scripts\Bootstrap.ps1" -SearchDirectories $hints -LegacySettingsPath $legacy -ShortcutDirectory $links -NoLaunch -NonInteractive -RegistryPath $registry)[-1]
    Check ($result.Mode -eq 'Upgrade' -and $result.Target -eq $target) 'Unified entry auto-selects the existing custom installation'
    $linkPath=Join-Path $links 'Codex Dual Controller.lnk'
    Check (Test-Path $linkPath) 'Upgrade automatically adds the missing desktop entry'
    $noRegistry=$registry+'\Missing'
    Check ($target -in @(Get-ControllerSetupHints -DefaultDirectory $default -RegistryPath $noRegistry -StartupRegistryPath $noRegistry -ShortcutDirectory $links -Snapshot @())) 'Desktop shortcut discovers a custom installation'
    $runKey=$registry+'\Run';[void](New-Item -Path $runKey -Force)
    [void](New-ItemProperty -LiteralPath $runKey -Name (Get-ControllerStartupName $configPath) -Value (Get-ControllerStartupCommand $target $configPath) -PropertyType String)
    Check ($target -in @(Get-ControllerSetupHints -DefaultDirectory $default -RegistryPath $noRegistry -StartupRegistryPath $runKey -ShortcutDirectory (Join-Path $root 'NoLinks') -Snapshot @())) 'Quoted startup command discovers a custom installation'
    Remove-Item -LiteralPath $runKey -Force
    Check ($target -in @(Get-ControllerSetupHints -DefaultDirectory $default -RegistryPath $noRegistry -StartupRegistryPath $noRegistry -ShortcutDirectory (Join-Path $root 'NoLinks') -Snapshot @([pscustomobject]@{Path=(Join-Path $target 'CodexDualController.exe')}))) 'Running host path discovers a custom installation'
    $snapshot=Get-ChildItem (Join-Path $target 'upgrades') -Directory|Sort-Object Name -Descending|Select-Object -First 1
    $journal=Get-Content (Join-Path $snapshot.FullName 'upgrade.local.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Check ($journal.shortcuts.Count -eq 1 -and $journal.shortcuts[0].path -eq $linkPath) 'New shortcut is recorded in the upgrade journal'
    Check ((Plan @($target)).Mode -eq 'Launch') 'Repeat run chooses launch instead of reinstalling'
    foreach($path in $protected){Check ((Get-FileHash -LiteralPath $path).Hash -eq $hashes[$path]) ('Upgrade preserves '+[IO.Path]::GetFileName($path))}
    $snapshotCount=@(Get-ChildItem (Join-Path $target 'upgrades') -Directory).Count
    & "$source\scripts\Bootstrap.ps1" -SearchDirectories @($target) -LegacySettingsPath $legacy -ShortcutDirectory $links -NoLaunch -NonInteractive -RegistryPath $registry | Out-Null
    Check (@(Get-ChildItem (Join-Path $target 'upgrades') -Directory).Count -eq $snapshotCount) 'Repeated unified entry creates no redundant upgrade snapshot'

    # Conflict must be rejected even on the otherwise up-to-date Launch branch.
    $linkBytes=[IO.File]::ReadAllBytes($linkPath);$shell=New-Object -ComObject WScript.Shell
    $link=$shell.CreateShortcut($linkPath);$link.Arguments='--background';$link.Save()
    $conflictHash=(Get-FileHash $linkPath).Hash
    Check ((Plan @($target)).Mode -eq 'Blocked') 'Different shortcut arguments block implicit adoption'
    MustThrow {Undo-ControllerUpgrade $snapshot.FullName} 'Rollback preserves a user-modified new shortcut'
    Check ((Get-FileHash $linkPath).Hash -eq $conflictHash) 'Conflict remains unchanged'
    [IO.File]::WriteAllBytes($linkPath,$linkBytes)
    Undo-ControllerUpgrade $snapshot.FullName | Out-Null
    Check (-not (Test-Path $linkPath)) 'Rollback removes the shortcut it created'
    Check ((Get-FileHash $configPath).Hash -eq $configHash) 'Rollback retains existing configuration'

    $savedWriter=(Get-Item Function:Write-AtomicText).ScriptBlock
    function Write-AtomicText([string]$Path,[string]$Text){
        if($Path.EndsWith('upgrade.local.json') -and $Text -match '"status"\s*:\s*"Completed"'){throw 'fixture-final-journal-failure'}
        & $savedWriter $Path $Text
    }
    try{
        $originalError=''
        try{Invoke-ControllerUpgrade -Source $source -Target $target -LegacySettingsPath $legacy -ShortcutDirectory $links|Out-Null}catch{$originalError=$_.Exception.Message}
        Check ($originalError -eq 'fixture-final-journal-failure') 'Upgrade preserves the original failure after rollback'
        Check (-not (Test-Path $linkPath)) 'Failed upgrade removes only its newly created shortcut'
        Check ((Get-FileHash $configPath).Hash -eq $configHash) 'Failed upgrade preserves configuration'
    }finally{Set-Item Function:Write-AtomicText $savedWriter}

    $manifestPath=Join-Path $target 'install-manifest.json';$manifestText=[IO.File]::ReadAllText($manifestPath);$manifestBytes=[IO.File]::ReadAllBytes($manifestPath)
    $versionPath=Join-Path $target 'version.json';$versionText=[IO.File]::ReadAllText($versionPath);$versionBytes=[IO.File]::ReadAllBytes($versionPath)
    Write-AtomicText $versionPath '{"product":"codex-desktop-dual-environment","version":"99.0.0"}'
    Check ((Plan @($target)).Mode -eq 'Blocked') 'Newer installed version is never auto-downgraded'
    MustThrow {Invoke-ControllerUpgrade $source $target $legacy} 'Direct upgrade also refuses downgrade'
    [IO.File]::WriteAllBytes($versionPath,$versionBytes)
    $manifest=$manifestText|ConvertFrom-Json;$manifest|Add-Member NoteProperty version '99.0.0' -Force
    Write-AtomicText $manifestPath ($manifest|ConvertTo-Json -Depth 8)
    [IO.File]::Delete($versionPath)
    Check ((Plan @($target)).Mode -eq 'Blocked') 'Manifest version protects missing version.json'
    MustThrow {Invoke-ControllerUpgrade $source $target $legacy} 'Direct upgrade respects newer manifest version'
    # Restore exact bytes: rewriting JSON with a different BOM is a real payload change.
    [IO.File]::WriteAllBytes($manifestPath,$manifestBytes);[IO.File]::WriteAllBytes($versionPath,$versionBytes)

    $second=Join-Path $root 'SecondTool'
    [void][IO.Directory]::CreateDirectory($second)
    [IO.File]::Copy($configPath,(Join-Path $second 'instances.local.json'))
    $secondManifest=$manifestText|ConvertFrom-Json;$secondManifest.root=$second
    Write-AtomicText (Join-Path $second 'install-manifest.json') ($secondManifest|ConvertTo-Json -Depth 8)
    Write-AtomicText (Join-Path $second 'version.json') $versionText
    Check ((Plan @($target,$second)).Mode -eq 'Choose') 'Multiple installed candidates require explicit selection'
    Check ((Get-ControllerSetupPlan -Source $source -TargetDirectory $target -Hints @($second) -NoShortcuts).Target -eq $target) 'Explicit target overrides discovery'
    Check ((Get-ControllerSetupPlan -Source $target -Hints @($second) -NoShortcuts).Target -eq $target) 'Configured portable source prefers its own installation'
    $secondManifest.root=Join-Path $root 'OldLocation';Write-AtomicText (Join-Path $second 'install-manifest.json') ($secondManifest|ConvertTo-Json -Depth 8)
    Check ((Plan @($second)).Mode -eq 'Blocked') 'Moved or mismatched installation manifest is blocked'
    Write-AtomicText (Join-Path $second 'instances.local.json') 'broken-json'
    Check ((Plan @($second)).Mode -eq 'Blocked') 'Damaged configuration is not treated as a fresh installation'

    function Run-BatchEntry([string]$Name,[string]$Arguments){
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$env:ComSpec
        $info.Arguments='/d /c ""'+(Join-Path $source $Name)+'" '+$Arguments+'"'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true
        $info.EnvironmentVariables['PSModulePath']=Join-Path $root 'NonexistentModules'
        $child=[Diagnostics.Process]::Start($info)
        try{$child.StandardInput.Close();$stdout=$child.StandardOutput.ReadToEnd();$stderr=$child.StandardError.ReadToEnd();$child.WaitForExit();return @{Code=$child.ExitCode;Output=$stdout+$stderr}}finally{$child.Dispose()}
    }
    foreach($entry in @('Start.cmd','Install.cmd')){
        $batch=Run-BatchEntry $entry ('-TargetDirectory "'+$target+'" -NoShortcuts -CheckOnly')
        if($batch.Code -ne 0 -or -not $batch.Output.Contains('Launch')){throw ($entry+' check failed (exit '+$batch.Code+'): '+$batch.Output)}
        Check ($batch.Code -eq 0 -and $batch.Output.Contains('Launch')) ($entry+' works with a hostile inherited PowerShell module path')
    }
    $batch=Run-BatchEntry 'Start.cmd' ('-TargetDirectory "'+$second+'" -NoLaunch -NonInteractive')
    Check ($batch.Code -ne 0) 'Batch entry preserves failures after pause instead of returning success'

    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    $manifest.files=@($manifest.files|Where-Object {$_.path -ne 'CodexDualController.exe'})
    Write-AtomicText $manifestPath ($manifest|ConvertTo-Json -Depth 8)
    Check ((Get-ControllerSetupPlan -Source $source -TargetDirectory $target -NoShortcuts).Mode -eq 'Upgrade') 'Missing executable manifest record selects repair'
    $manifestRepair=Invoke-ControllerUpgrade -Source $source -Target $target -LegacySettingsPath $legacy
    Check ($manifestRepair.Status -eq 'Upgraded' -and @((Get-Content $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json).files|Where-Object {$_.path -eq 'CodexDualController.exe'}).Count -eq 1) 'Repair restores the missing executable manifest record'
    Check ((Get-ControllerSetupPlan -Source $source -TargetDirectory $target -NoShortcuts).Mode -eq 'Launch') 'Repaired manifest permits direct launch on the next run'

    # Repair a missing core tool file using the validated manifest, without fresh setup prompts.
    [IO.File]::Delete((Join-Path $target 'src\Core.ps1'))
    Check ((Plan @($target)).Mode -eq 'Upgrade') 'Missing tool file chooses repair rather than installation'
    & "$source\scripts\Bootstrap.ps1" -SearchDirectories @($target) -LegacySettingsPath $legacy -ShortcutDirectory $links -NoLaunch -NonInteractive -RegistryPath $registry | Out-Null
    Check ((Test-Path (Join-Path $target 'src\Core.ps1')) -and (Get-FileHash $configPath).Hash -eq $configHash) 'Automatic repair restores tool code while retaining configuration'

    # Simulate external edits before a pending copy and after a successful copy.
    $concurrentPath=Join-Path $target 'src\Core.ps1'
    $savedWriter=(Get-Item Function:Write-AtomicText).ScriptBlock
    foreach($failurePhase in @('BeforeCopy','AfterCopy')){
        [IO.File]::WriteAllText($concurrentPath,'# old fixture tool')
        function Write-AtomicText([string]$Path,[string]$Text){
            if($Path.EndsWith('upgrade.local.json')){
                if($failurePhase -eq 'BeforeCopy' -and $Text -match '"status"\s*:\s*"Prepared"'){[IO.File]::WriteAllText($concurrentPath,'# concurrent edit')}
                if($failurePhase -eq 'AfterCopy' -and $Text -match '"status"\s*:\s*"Completed"'){
                    [IO.File]::WriteAllText($concurrentPath,'# concurrent edit');throw 'fixture-post-copy-failure'
                }
            }
            & $savedWriter $Path $Text
        }
        try{
            $failure=''
            try{Invoke-ControllerUpgrade -Source $source -Target $target -LegacySettingsPath $legacy|Out-Null}catch{$failure=$_.Exception.Message}
            Check ($failure.Length -gt 0) ($failurePhase+': concurrent edit aborts upgrade')
            if($failurePhase -eq 'AfterCopy'){Check ($failure -eq 'fixture-post-copy-failure') 'Incomplete rollback preserves the original failure'}
            Check ([IO.File]::ReadAllText($concurrentPath) -eq '# concurrent edit') ($failurePhase+': failure recovery preserves the external edit')
            Check ((Get-FileHash $configPath).Hash -eq $configHash) ($failurePhase+': failure recovery preserves instance configuration')
        }finally{Set-Item Function:Write-AtomicText $savedWriter}
        [IO.File]::Copy((Join-Path $source 'src\Core.ps1'),$concurrentPath,$true)
        Invoke-ControllerUpgrade -Source $source -Target $target -LegacySettingsPath $legacy|Out-Null
    }

    # Run a disposable host-shaped process to prove no loaded EXE is replaced.
    $fixtureExe=Join-Path $root 'Sleeper.exe'
    Add-Type -TypeDefinition 'class SetupSleeper { static void Main(){System.Threading.Thread.Sleep(30000);} }' -OutputAssembly $fixtureExe -OutputType WindowsApplication
    $hostPath=Join-Path $target 'CodexDualController.exe';[IO.File]::Copy($fixtureExe,$hostPath,$true)
    $fixture=Start-Process -FilePath $hostPath -PassThru -WindowStyle Hidden
    $runningHash=(Get-FileHash $hostPath).Hash
    MustThrow {& "$source\scripts\Bootstrap.ps1" -SearchDirectories @($target) -LegacySettingsPath $legacy -ShortcutDirectory $links -NoLaunch -NonInteractive -RegistryPath $registry} 'Running target refuses file replacement'
    Check ((Get-FileHash $hostPath).Hash -eq $runningHash) 'Running executable is unchanged after refusal'
    Unregister-ControllerInstallation $target $registry
    Check ($target -notin @(Get-ControllerSetupHints -DefaultDirectory $default -RegistryPath $registry -StartupRegistryPath ($registry+'\Run') -ShortcutDirectory (Join-Path $root 'NoLinks') -Snapshot @())) 'Unregister removes only this discovery record'
}finally{
    if($fixture){if(-not $fixture.HasExited){$fixture.Kill();$fixture.WaitForExit()};$fixture.Dispose()}
    if(Test-Path -LiteralPath $registry){Remove-Item -LiteralPath $registry -Force}
}
Write-Output "PASSED: $script:passed automatic setup checks. Output: $root"
