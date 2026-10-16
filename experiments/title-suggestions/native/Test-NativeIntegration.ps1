[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Install-NativeTitle.ps1') -FunctionsOnly
$script:passed=0
function Check([string]$Name,[scriptblock]$Body) { & $Body; $script:passed++; Write-Output ('PASS '+$Name) }
function Require($Condition,[string]$Message='Assertion failed') { if(-not $Condition){throw $Message} }
function Reject([scriptblock]$Body,[string]$Message) {
    $caught=$false
    try{& $Body | Out-Null}catch{$caught=$true;Require ($_.Exception.Message -like ('*'+$Message+'*')) ('Unexpected rejection: '+$_.Exception.Message)}
    Require $caught ('Did not reject: '+$Message)
}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('CodexTitleIntegrationTests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    Check 'PowerShell syntax' {
        foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1){Assert-TitlePowerShellSyntax ([IO.File]::ReadAllText($file.FullName))}
    }
    $profile=Join-Path $scratch 'Profile';[void][IO.Directory]::CreateDirectory($profile)
    $debugFile=Join-Path $profile 'DevToolsActivePort'
    $browser='/devtools/browser/01234567-89ab-cdef-0123-456789abcdef'
    [IO.File]::WriteAllText($debugFile,"34567`n$browser")
    $started=[DateTime]::UtcNow.AddSeconds(-3).Ticks
    Check 'Ephemeral endpoint file accepted' {$found=Read-TitleDebugEndpoint $profile $started;Require ($found.Port -eq 34567 -and $found.BrowserPath -ceq $browser)}
    Check 'Endpoint runtime JSON is a small primitive DTO without provider metadata' {
        $found=Read-TitleDebugEndpoint $profile $started
        $target=Join-Path $scratch 'runtime-target.json'
        Write-TitleState $target @{pid=500;startedTicks=[string]$started;port=$found.Port;browserPath=$found.BrowserPath}
        $raw=[IO.File]::ReadAllText($target)
        $value=$raw|ConvertFrom-Json
        Require ($value.browserPath -is [string] -and $value.browserPath -ceq $browser)
        Require ($raw.Length -lt 2048 -and $raw -notmatch 'PSPath|PSDrive|PSProvider|ReadCount')
    }
    Check 'Stale endpoint rejected' {Reject {Read-TitleDebugEndpoint $profile ([DateTime]::UtcNow.AddMinutes(1).Ticks)} 'title-debug-file-stale'}
    Check 'Malformed endpoint rejected' {[IO.File]::WriteAllText($debugFile,"70000`n$browser");Reject {Read-TitleDebugEndpoint $profile $started} 'title-debug-port-invalid';[IO.File]::WriteAllText($debugFile,"34567`n$browser")}
    Check 'All endpoint listeners must be owned loopback' {
        Assert-TitleListeners @(@{LocalPort=34567;State='Listen';OwningProcess=500;LocalAddress='127.0.0.1'},@{LocalPort=34567;State='Listen';OwningProcess=500;LocalAddress='::1'}) 34567 500
    }
    Check 'LAN endpoint rejected' {Reject {Assert-TitleListeners @(@{LocalPort=34567;State='Listen';OwningProcess=500;LocalAddress='0.0.0.0'}) 34567 500} 'title-debug-owner-or-address-mismatch'}
    Check 'PID mismatch rejected' {Reject {Assert-TitleListeners @(@{LocalPort=34567;State='Listen';OwningProcess=501;LocalAddress='127.0.0.1'}) 34567 500} 'title-debug-owner-or-address-mismatch'}
    Check 'Missing listener rejected' {Reject {Assert-TitleListeners @() 34567 500} 'title-debug-not-listening'}
    Check 'Version browser binding accepted' {Assert-TitleVersionEndpoint @{webSocketDebuggerUrl="ws://127.0.0.1:34567$browser"} 34567 $browser}
    Check 'Version wrong port rejected' {Reject {Assert-TitleVersionEndpoint @{webSocketDebuggerUrl="ws://127.0.0.1:34568$browser"} 34567 $browser} 'title-browser-endpoint-mismatch'}
    Check 'Version browser mismatch rejected' {Reject {Assert-TitleVersionEndpoint @{webSocketDebuggerUrl="ws://127.0.0.1:34567$browser-other"} 34567 $browser} 'title-browser-endpoint-mismatch'}
    Check 'Version nonloopback rejected' {Reject {Assert-TitleVersionEndpoint @{webSocketDebuggerUrl="ws://example.com:34567$browser"} 34567 $browser} 'title-browser-endpoint-mismatch'}
    $fakeBinary=Join-Path $scratch 'codex.exe';[IO.File]::WriteAllText($fakeBinary,'fixture only; not executable')
    $binaryHash=Get-TitleSha256 $fakeBinary
    Check 'Exact direct CLI child accepted' {$c=Get-TitleCliChild @(@{Id=501;ParentId=500;Path=$fakeBinary}) 500 @{path=$fakeBinary;sha256=$binaryHash};Require ($c.Id -eq 501)}
    Check 'Descendant alone does not match direct CLI' {Require ($null -eq (Get-TitleCliChild @(@{Id=502;ParentId=501;Path=$fakeBinary}) 500 @{path=$fakeBinary;sha256=$binaryHash}))}
    Check 'Ambiguous CLI rejected' {Reject {Get-TitleCliChild @(@{Id=501;ParentId=500;Path=$fakeBinary},@{Id=502;ParentId=500;Path=$fakeBinary}) 500 @{path=$fakeBinary;sha256=$binaryHash}} 'title-cli-child-ambiguous'}
    Check 'Changed CLI rejected' {Reject {Get-TitleCliChild @(@{Id=501;ParentId=500;Path=$fakeBinary}) 500 @{path=$fakeBinary;sha256=('0'*64)}} 'title-cli-child-changed'}

    $bridgeRoot=Join-Path $scratch 'QuestionBridge';$controllerRoot=Join-Path $scratch 'Controller';$controllerState=Join-Path $scratch 'ControllerState'
    [void][IO.Directory]::CreateDirectory($bridgeRoot);[void][IO.Directory]::CreateDirectory((Join-Path $controllerRoot 'src'));[void][IO.Directory]::CreateDirectory($controllerState)
    $validatorPath=Join-Path $controllerRoot 'src\QuestionBridgeLaunch.ps1'
    [IO.File]::Copy((Join-Path $PSScriptRoot '..\..\..\src\QuestionBridgeLaunch.ps1'),$validatorPath)
    $proxyPath=Join-Path $bridgeRoot 'BridgeProxy.exe';[IO.File]::WriteAllText($proxyPath,'fake proxy fixture, never executed')
    $bridgeId='0123456789abcdef0123456789abcdef';$instanceId='abcdef0123456789abcdef0123456789'
    $bridgeConfig=@{instanceId=('api-live-'+$bridgeId);pipeName=('codex-api-questions-'+$bridgeId);takeoverQuestions=$true;apiHome=(Join-Path $scratch 'api-home');realCli=$fakeBinary}
    Write-TitleState (Join-Path $bridgeRoot 'bridge.config.json') $bridgeConfig
    $bridgeManifest=@{schema=1;kind='api-question-bridge-installation';id=$bridgeId;controllerInstanceId=$instanceId;root=$bridgeRoot;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;apiHome=$bridgeConfig.apiHome;profile=$profile;desktopExe=$fakeBinary;realCli=$fakeBinary;realCliHash=$binaryHash;proxyHash=(Get-TitleSha256 $proxyPath);desktopHash=$binaryHash;configHash=(Get-TitleSha256 (Join-Path $bridgeRoot 'bridge.config.json'))}
    Write-TitleState (Join-Path $bridgeRoot 'binding.json') $bridgeManifest
    $bridgeRegistrationPath=Join-Path $controllerState 'question-bridge.local.json'
    $bridgeRegistration=@{schema=1;instanceId=$instanceId;directory=$bridgeRoot};Write-TitleState $bridgeRegistrationPath $bridgeRegistration
    $titleRuntime=[pscustomobject]@{instanceId=$instanceId;home=$bridgeConfig.apiHome;profile=$profile;desktop=@{path=$fakeBinary;sha256=$binaryHash};cli=@{path=$fakeBinary;sha256=$binaryHash};controller=@{directory=$controllerRoot;dependencies=@(@{path=$validatorPath;sha256=(Get-TitleSha256 $validatorPath)})}}
    $controllerConfig=@{stateDirectory=$controllerState}
    $desktopProcess=@{Id=500;Started=[string]$started;Path=$fakeBinary}
    $proxyProcess=@{Id=501;ParentId=500;Started=[string]($started+100);Path=$proxyPath}
    $bridgedCli=@{Id=502;ParentId=501;Started=[string]($started+200);Path=$fakeBinary}
    Check 'Validated registered proxy direct CLI chain accepted' {
        $child=Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli) $desktopProcess $titleRuntime $controllerConfig
        Require ($child.Id -eq 502)
    }
    Check 'Runtime direct CLI works without consulting bridge registration' {
        $child=Get-TitleRuntimeCliChild @(@{Id=503;ParentId=500;Started=[string]($started+100);Path=$fakeBinary}) $desktopProcess $titleRuntime @{}
        Require ($child.Id -eq 503)
    }
    Check 'Proxy process with old parent creation evidence rejected' {
        $proxyProcess.Started=[string]($started-100)
        try{Reject {Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli) $desktopProcess $titleRuntime $controllerConfig} 'title-bridge-parent-identity-changed'}finally{$proxyProcess.Started=[string]($started+100)}
    }
    Check 'Proxy child with older creation evidence rejected' {
        $bridgedCli.Started=[string]$started
        try{Reject {Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli) $desktopProcess $titleRuntime $controllerConfig} 'title-cli-parent-identity-changed'}finally{$bridgedCli.Started=[string]($started+200)}
    }
    Check 'Direct CLI and proxy ambiguity rejected' {Reject {Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli,@{Id=503;ParentId=500;Started=[string]($started+100);Path=$fakeBinary}) $desktopProcess $titleRuntime $controllerConfig} 'title-cli-child-ambiguous'}
    Check 'Same proxy basename at foreign path rejected' {
        $foreign=Join-Path $scratch 'BridgeProxy.exe';[IO.File]::WriteAllText($foreign,'fake proxy fixture, never executed');$proxyProcess.Path=$foreign
        try{Reject {Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli) $desktopProcess $titleRuntime $controllerConfig} 'title-bridge-process-mismatch'}finally{$proxyProcess.Path=$proxyPath}
    }
    Check 'Proxy chain requires pinned validator' {
        $pins=$titleRuntime.controller.dependencies;$titleRuntime.controller.dependencies=@()
        try{Reject {Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli) $desktopProcess $titleRuntime $controllerConfig} 'title-bridge-validator-unpinned'}finally{$titleRuntime.controller.dependencies=$pins}
    }
    Check 'Changed validator rejected before execution' {
        $pinHash=$titleRuntime.controller.dependencies[0].sha256;$titleRuntime.controller.dependencies[0].sha256='0'*64
        try{Reject {Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli) $desktopProcess $titleRuntime $controllerConfig} 'title-bridge-validator-changed'}finally{$titleRuntime.controller.dependencies[0].sha256=$pinHash}
    }
    Check 'Cross instance bridge registration rejected' {
        $bridgeRegistration.instanceId='0'*32;Write-TitleState $bridgeRegistrationPath $bridgeRegistration
        try{Reject {Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli) $desktopProcess $titleRuntime $controllerConfig} 'title-bridge-registration-invalid'}finally{$bridgeRegistration.instanceId=$instanceId;Write-TitleState $bridgeRegistrationPath $bridgeRegistration}
    }
    Check 'Oversized bridge registration rejected' {
        [IO.File]::WriteAllText($bridgeRegistrationPath,('x'*65537))
        try{Reject {Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli) $desktopProcess $titleRuntime $controllerConfig} 'title-bridge-registration-invalid'}finally{Write-TitleState $bridgeRegistrationPath $bridgeRegistration}
    }
    Check 'Disabled bridge is never accepted by title helper' {
        [IO.File]::WriteAllText((Join-Path $bridgeRoot 'DISABLED'),'fixture')
        try{Reject {Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli) $desktopProcess $titleRuntime $controllerConfig} 'title-question-bridge-invalid'}finally{Remove-Item -LiteralPath (Join-Path $bridgeRoot 'DISABLED')}
    }
    Check 'Registered bridge real CLI must match title compatibility binding' {
        $titleRuntime.cli.sha256='0'*64
        try{Reject {Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli) $desktopProcess $titleRuntime $controllerConfig} 'title-bridge-cli-binding-mismatch'}finally{$titleRuntime.cli.sha256=$binaryHash}
    }
    Check 'Grandchild under unverified extra process not accepted' {
        $bridgedCli.ParentId=504
        try{Require ($null -eq (Get-TitleRuntimeCliChild @($proxyProcess,$bridgedCli,@{Id=504;ParentId=501;Started=[string]($started+150);Path='C:\untrusted.exe'}) $desktopProcess $titleRuntime $controllerConfig))}finally{$bridgedCli.ParentId=501}
    }

    $anchor='        Start-Process -FilePath $codexDesktopExe -ArgumentList @("--user-data-dir=$apiDesktopProfile") -WorkingDirectory (Join-Path $apiRoot "Projects")'
    $original="# MSIX and DPAPI fixture preamble`r`n$anchor`r`n# question bridge and credential cleanup fixture`r`n"
    $fakeHelper=Join-Path $scratch 'FakeHelper.ps1'
    [IO.File]::WriteAllText($fakeHelper,'function Get-TitleIntegrationLaunch { return [pscustomobject]@{debugArguments=@("--remote-debugging-port=0","--remote-debugging-address=127.0.0.1");daemon="C:\fixture\daemon.ps1";bindingPath="C:\fixture\binding.json";bindingSha256=("a"*64)} }')
    $patch=New-TitleLauncherPatch $original $fakeHelper (Get-TitleSha256 $fakeHelper) 'C:\fixture\binding.json' ('a'*64)
    Check 'Patch preserves all surrounding launcher text' {Require ($patch.Text.Replace($patch.After,$patch.Before) -ceq $original);Assert-TitlePowerShellSyntax $patch.Text}
    Check 'Duplicate anchor rejected' {Reject {New-TitleLauncherPatch ($original+$original) $fakeHelper (Get-TitleSha256 $fakeHelper) 'C:\fixture\binding.json' ('a'*64)} 'title-launcher-anchor-not-unique'}
    Check 'Second patch rejected' {Reject {New-TitleLauncherPatch $patch.Text $fakeHelper (Get-TitleSha256 $fakeHelper) 'C:\fixture\binding.json' ('a'*64)} 'title-launcher-already-patched'}
    function Start-Process { param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle) $script:launches+=@([pscustomobject]@{file=$FilePath;arguments=$ArgumentList;window=$WindowStyle}) }
    function Write-LauncherLog { param($Message) $script:logs+=@($Message) }
    $apiCodexHome='C:\fixture\home';$apiDesktopProfile='C:\fixture\profile';$codexDesktopExe='C:\fixture\ChatGPT.exe';$apiRoot='C:\fixture'
    Check 'Patched launcher adds debug flags and hidden daemon' {
        $script:launches=@();$script:logs=@();Invoke-Expression $patch.After
        Require ($script:launches.Count -eq 2);Require ($script:launches[0].arguments -contains '--remote-debugging-port=0');Require ($script:launches[1].window -eq 'Hidden')
    }
    Check 'Changed helper preserves native startup without debug flags' {
        [IO.File]::AppendAllText($fakeHelper,"`n# changed")
        $script:launches=@();$script:logs=@();Invoke-Expression $patch.After
        Require ($script:launches.Count -eq 1);Require (@($script:launches[0].arguments).Count -eq 1);Require ($script:logs -contains 'Title enhancement unavailable; native startup continues.')
    }
    Remove-Item Function:\Start-Process

    $install=Join-Path $scratch 'Install';[void][IO.Directory]::CreateDirectory($install)
    $launcher=Join-Path $scratch 'Launcher.ps1';[IO.File]::WriteAllText($launcher,$original)
    $bindingPath=Join-Path $install 'binding.json'
    $runtime=@{path=$fakeBinary;sha256=$binaryHash}
    $receipt=@{cliSha256=$binaryHash;passed=$true;toolCount=0;environmentHeaderVerified=$true}
    $binding=@{schema=1;instanceId=('a'*32);home='C:\fixture\home';profile='C:\fixture\profile';installRoot=$install;stateDirectory=(Join-Path $install 'state');desktop=$runtime;cli=$runtime;node=$runtime;python=$runtime;bundleFiles=@();controller=@{dependencies=@()};compatibility=$receipt}
    Write-TitleState $bindingPath $binding
    Check 'Binding binary pins verified' {[void](Read-TitleBinding $bindingPath (Get-TitleSha256 $bindingPath))}
    Check 'Binding hash drift rejected' {Reject {Read-TitleBinding $bindingPath ('0'*64)} 'title-binding-changed'}
    Check 'Compatibility receipt failed rejected' {Reject {Assert-TitleCompatibilityReceipt @{cliSha256=$binaryHash;passed=$false;toolCount=0;environmentHeaderVerified=$true} $binaryHash} 'title-compatibility-receipt-invalid'}
    Check 'Compatibility receipt CLI drift rejected' {Reject {Assert-TitleCompatibilityReceipt $receipt ('0'*64)} 'title-compatibility-receipt-invalid'}
    Check 'Compatibility receipt tools rejected' {Reject {Assert-TitleCompatibilityReceipt @{cliSha256=$binaryHash;passed=$true;toolCount=1;environmentHeaderVerified=$true} $binaryHash} 'title-compatibility-receipt-invalid'}
    Check 'Compatibility receipt string booleans rejected' {Reject {Assert-TitleCompatibilityReceipt @{cliSha256=$binaryHash;passed='true';toolCount=0;environmentHeaderVerified=$true} $binaryHash} 'title-compatibility-receipt-invalid'}
    Check 'Disabled loader receives graceful wait' {
        $fakeNode=[pscustomobject]@{HasExited=$false;WaitCalls=0}
        $fakeNode | Add-Member ScriptMethod WaitForExit {param($Milliseconds) $this.WaitCalls++; $this.HasExited=$true;return $true}
        $script:identityCalls=0
        Wait-TitleDisabledExit $fakeNode {$script:identityCalls++} 1000
        Require ($fakeNode.WaitCalls -eq 1 -and $script:identityCalls -eq 1)
    }
    Check 'Identity change bypasses disabled grace' {
        $fakeNode=[pscustomobject]@{HasExited=$false;WaitCalls=0}
        $fakeNode | Add-Member ScriptMethod WaitForExit {param($Milliseconds) $this.WaitCalls++;return $false}
        Reject {Wait-TitleDisabledExit $fakeNode {throw 'title-desktop-identity-changed'} 1000} 'title-desktop-identity-changed'
        Require ($fakeNode.WaitCalls -eq 0)
    }
    Check 'Offline probe isolated Python launch and receipt' {
        $probeRoot=Join-Path $scratch 'FakeOfflineProbe';[void][IO.Directory]::CreateDirectory($probeRoot)
        $probeCode="import sys,os,json`nassert sys.flags.isolated == 1`nassert 'FREEHYY_API_KEY' not in os.environ`nprint(json.dumps(dict(passed=True,toolNames=[],environmentHeaderVerified=True)))`n"
        [IO.File]::WriteAllText((Join-Path $probeRoot 'probe_cli.py'),$probeCode)
        $python='C:\Users\Administrator\AppData\Local\Python\pythoncore-3.14-64\python.exe'
        $prior=[Environment]::GetEnvironmentVariable('FREEHYY_API_KEY','Process')
        try {
            [Environment]::SetEnvironmentVariable('FREEHYY_API_KEY','offline-test-placeholder','Process')
            $result=Invoke-TitleOfflineCompatibilityProbe $python $probeRoot $fakeBinary
            Assert-TitleCompatibilityReceipt $result $binaryHash
        } finally { [Environment]::SetEnvironmentVariable('FREEHYY_API_KEY',$prior,'Process') }
        [IO.File]::WriteAllText((Join-Path $probeRoot 'probe_cli.py'),"import json`nprint(json.dumps(dict(passed=True,toolNames=['shell'],environmentHeaderVerified=True)))`n")
        Reject {Invoke-TitleOfflineCompatibilityProbe $python $probeRoot $fakeBinary} 'title-offline-probe-incompatible'
    }
    $staged=Join-Path $install 'launcher.staged.ps1';[IO.File]::WriteAllText($staged,$patch.Text)
    $backup=Join-Path $install 'launcher.original.ps1';[IO.File]::Copy($launcher,$backup)
    $plan=@{schema=1;destination=$install;launcher=$launcher;originalHash=(Get-TitleSha256 $launcher);stagedHash=(Get-TitleSha256 $staged);bindingHash=(Get-TitleSha256 $bindingPath);backupPath=$backup;stagedPath=$staged;before=$patch.Before;after=$patch.After}
    Write-TitleState (Join-Path $install 'install-plan.json') $plan
    Check 'Apply only modifies reviewed fake launcher' {
        $result=& (Join-Path $PSScriptRoot 'Install-NativeTitle.ps1') -Apply -Destination $install -Launcher $launcher
        Require ($result.state -eq 'installed-next-complete-start');Require ((Get-TitleSha256 $launcher) -eq $plan.stagedHash)
    }
    Check 'Apply rejects launcher drift' {Reject {& (Join-Path $PSScriptRoot 'Install-NativeTitle.ps1') -Apply -Destination $install -Launcher $launcher} 'title-launcher-drifted-since-prepare'}
    Check 'Rollback preview is read only' {
        $hash=Get-TitleSha256 $launcher
        $result=& (Join-Path $PSScriptRoot 'Rollback-NativeTitle.ps1') -Installation $install
        Require ($result.state -eq 'rollback-ready');Require ((Get-TitleSha256 $launcher) -eq $hash);Require (-not (Test-Path (Join-Path $install 'DISABLED')))
    }
    Check 'Rollback preserves unrelated subsequent edits' {
        [IO.File]::AppendAllText($launcher,"# unrelated later change`r`n")
        $result=& (Join-Path $PSScriptRoot 'Rollback-NativeTitle.ps1') -Installation $install -Apply
        Require ($result.state -eq 'rolled-back');Require ([IO.File]::ReadAllText($launcher) -ceq ($original+"# unrelated later change`r`n"));Require (Test-Path (Join-Path $install 'DISABLED'))
    }
    Check 'Rollback refuses edited integration block' {
        [IO.File]::WriteAllText($launcher,$patch.Text.Replace('remote-debugging-port=0','remote-debugging-port=9999'))
        # The literal comes from the helper rather than the block; mutate a block field instead.
        [IO.File]::WriteAllText($launcher,[IO.File]::ReadAllText($launcher).Replace('Title enhancement queued','Edited enhancement queued'))
        Reject {& (Join-Path $PSScriptRoot 'Rollback-NativeTitle.ps1') -Installation $install -Apply} 'title-rollback-block-drifted'
    }
    $oldInstall=Join-Path $scratch 'OldTitle';[void][IO.Directory]::CreateDirectory($oldInstall)
    $oldBindingPath=Join-Path $oldInstall 'binding.json';Write-TitleState $oldBindingPath @{schema=1;fixture=$true}
    $oldPatch=New-TitleLauncherPatch $original $fakeHelper (Get-TitleSha256 $fakeHelper) $oldBindingPath (Get-TitleSha256 $oldBindingPath)
    $oldBackup=Join-Path $oldInstall 'launcher.original.ps1';$oldStaged=Join-Path $oldInstall 'launcher.staged.ps1'
    [IO.File]::WriteAllText($oldBackup,$original);[IO.File]::WriteAllText($oldStaged,$oldPatch.Text)
    $oldPlan=@{schema=1;destination=$oldInstall;launcher=$launcher;backupPath=$oldBackup;stagedPath=$oldStaged;originalHash=(Get-TitleSha256 $oldBackup);stagedHash=(Get-TitleSha256 $oldStaged);bindingHash=(Get-TitleSha256 $oldBindingPath);before=$oldPatch.Before;after=$oldPatch.After}
    Write-TitleState (Join-Path $oldInstall 'install-plan.json') $oldPlan
    $withAdaptive="# adaptive fixture block`r`n"+$oldPatch.Text+"# later unrelated edit`r`n"
    Check 'Title upgrade replaces only old verified block preserving adaptive text' {
        $upgrade=New-TitleUpgradePatch $withAdaptive $oldInstall $launcher $fakeHelper (Get-TitleSha256 $fakeHelper) $bindingPath (Get-TitleSha256 $bindingPath)
        Require ($upgrade.Before -ceq $oldPatch.After)
        Require ($upgrade.Text.Replace($upgrade.After,$upgrade.Before) -ceq $withAdaptive)
        Require ($upgrade.Text.StartsWith("# adaptive fixture block`r`n") -and $upgrade.Text.EndsWith("# later unrelated edit`r`n"))
        Assert-TitlePowerShellSyntax $upgrade.Text
    }
    Check 'Title upgrade rejects manual change inside previous block' {
        Reject {New-TitleUpgradePatch ($withAdaptive.Replace('Title enhancement queued','Edited queued')) $oldInstall $launcher $fakeHelper (Get-TitleSha256 $fakeHelper) $bindingPath (Get-TitleSha256 $bindingPath)} 'title-old-block-drifted'
    }
    Check 'Title upgrade rejects changed old artifact' {
        [IO.File]::AppendAllText($oldStaged,'# changed')
        try{Reject {New-TitleUpgradePatch $withAdaptive $oldInstall $launcher $fakeHelper (Get-TitleSha256 $fakeHelper) $bindingPath (Get-TitleSha256 $bindingPath)} 'title-old-artifact-changed'}finally{[IO.File]::WriteAllText($oldStaged,$oldPatch.Text)}
    }
    Check 'Title upgrade rejects old plan for different launcher' {
        Reject {New-TitleUpgradePatch $withAdaptive $oldInstall (Join-Path $scratch 'OtherLauncher.ps1') $fakeHelper (Get-TitleSha256 $fakeHelper) $bindingPath (Get-TitleSha256 $bindingPath)} 'title-old-plan-mismatch'
    }
    Write-Output ("PASS total: $script:passed; scratch: $scratch")
} finally {
    # Keep fixtures for review. No production paths are written by this test.
}
