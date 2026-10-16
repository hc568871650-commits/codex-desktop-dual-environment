# No production writes, no model calls, no Desktop launches.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$testSource=Split-Path -Parent $PSScriptRoot
. (Join-Path $testSource 'Install-AdaptiveBridge.ps1') -FunctionsOnly
$script:passed=0
function Check([string]$Name,[scriptblock]$Action){& $Action;$script:passed++;Write-Output ('PASS '+$Name)}
function Assert($Condition,[string]$Message='assertion failed'){if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Action,[string]$Pattern){try{& $Action}catch{if($_.Exception.Message -like ('*'+$Pattern+'*')){return};throw};throw ('Expected rejection '+$Pattern)}
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('codex-adaptive-integration-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
try {
    $controller=Join-Path $sandbox 'controller';$src=Join-Path $controller 'src';$state=Join-Path $controller 'state';$bundle=Join-Path $sandbox 'source';$destination=Join-Path $sandbox 'deployed'
    foreach($directory in @($src,$state,$bundle,(Join-Path $bundle 'bin'))){[void][IO.Directory]::CreateDirectory($directory)}
    $launcher=Join-Path $sandbox 'Start-API.ps1'
    $template=@'
param([switch]$PackageContext)
# MSIX / DPAPI MUST REMAIN
$env:FREEHYY_API_KEY='untouched-example'
$apiCodexHome='sample-home'
        # API-only question takeover. Any validation failure keeps the native CLI.
        Remove-Item Env:\CODEX_CLI_PATH -ErrorAction SilentlyContinue
        try {
            $questionHelper = 'old.ps1'
            $questionBridge = Get-ValidatedApiQuestionBridge -Directory 'old'
        } catch {}
        New-Item -ItemType Directory -Path $apiCodexHome, $apiDesktopProfile, $apiProjectlessRoot -Force | Out-Null
        # BEGIN CODEX NATIVE TITLE v1
        $titleHelper='native-title-0.1.4'
        Start-Process -FilePath $codexDesktopExe -ArgumentList (@("--user-data-dir=$apiDesktopProfile") + $titleArguments) -WorkingDirectory (Join-Path $apiRoot "Projects")
        # END CODEX NATIVE TITLE v1
'@
    [IO.File]::WriteAllText($launcher,$template,(New-Object Text.UTF8Encoding($true)))
    foreach($name in @('Launch-AdaptiveBridge.ps1','Observe-AdaptiveBridge.ps1','Install-AdaptiveBridge.ps1','Rollback-AdaptiveBridge.ps1')){[IO.File]::Copy((Join-Path $testSource $name),(Join-Path $bundle $name))}
    [IO.File]::WriteAllText((Join-Path $bundle 'Invoke-Compatibility.ps1'),'throw "fixture should never run during prelaunch"')
    [IO.File]::WriteAllText((Join-Path $bundle 'bin\RealCliQuestionFixture.exe'),'fake binary')
    [IO.File]::WriteAllText((Join-Path $bundle 'AdaptiveBridge.ps1'),@'
function Read-AdaptiveJson([string]$Path){return ([IO.File]::ReadAllText($Path)|ConvertFrom-Json)}
function Test-AdaptiveBridgeCandidate {param($Root,$Instance,$CandidateDirectory,$DesktopExecutable,$ProxyPath,$CompatibilityScript)
    if(Test-Path -LiteralPath (Join-Path $Root 'reject-candidate')){throw 'TEST_CANDIDATE_REJECTED'}
    return [pscustomobject]@{directory=$CandidateDirectory;proxy=(Join-Path $CandidateDirectory 'BridgeProxy.exe')}
}
'@)
    [IO.File]::WriteAllText((Join-Path $src 'Instances.ps1'),@'
function Read-ControllerConfig([string]$Path){return ([IO.File]::ReadAllText($Path)|ConvertFrom-Json)}
function Get-ApiFeatureInstance($Config,[string]$InstanceId){return @($Config.instances|Where-Object id -eq $InstanceId)[0]}
function Test-SamePath([string]$A,[string]$B){return Test-AbiPath $A $B}
function Get-InstanceStatus($Config,$Instance){return [pscustomobject]@{State=$Config.testState}}
function Get-ProcessSnapshot {return @()}
'@)
    foreach($name in @('Core.ps1','Native.cs','TomlConfig.cs','Preferences.ps1','ApiManagement.ps1','QuestionBridgeLaunch.ps1')){[IO.File]::WriteAllText((Join-Path $src $name),'# fake dependency')}
    $instance=[pscustomobject]@{id=('a'*32);role='api';launchMode='external';externalLauncher=$launcher;home=(Join-Path $sandbox 'home');profile=(Join-Path $sandbox 'profile')}
    $config=[pscustomobject]@{schema=1;instances=@($instance);stateDirectory=$state;testState='Stopped'}
    $configPath=Join-Path $controller 'instances.local.json';Write-AbiJson $configPath $config
    $proxy=Join-Path $sandbox 'BridgeProxy.exe';[IO.File]::WriteAllText($proxy,'fake proxy')
    $oldDir=Join-Path $sandbox 'legacy';[void][IO.Directory]::CreateDirectory($oldDir)
    Write-AbiJson (Join-Path $state 'question-bridge.local.json') @{schema=1;instanceId=$instance.id;directory=$oldDir}
    $originalHash=Get-AbiHash $launcher
    Check 'Prepare rejects unknown launcher hash' {Reject {& (Join-Path $bundle 'Install-AdaptiveBridge.ps1') -Source $bundle -Destination $destination -Launcher $launcher -ControllerRoot $controller -ProxyPath $proxy -ExpectedLauncherSha256 ('0'*64)} 'TEMPLATE_CHANGED'}
    Check 'Prepare leaves launcher and controller binding untouched' {
        $result=& (Join-Path $bundle 'Install-AdaptiveBridge.ps1') -Source $bundle -Destination $destination -Launcher $launcher -ControllerRoot $controller -ProxyPath $proxy -ExpectedLauncherSha256 $originalHash
        Assert ($result.state -eq 'prepared-only');Assert ((Get-AbiHash $launcher) -eq $originalHash)
        Assert (-not(Test-Path -LiteralPath (Join-Path $state 'adaptive-bridge.local.json')))
    }
    $plan=[IO.File]::ReadAllText((Join-Path $destination 'install-plan.json'))|ConvertFrom-Json
    $integrationPath=Join-Path $destination 'integration.json';$integration=Read-AbiIntegration $integrationPath $plan.integrationHash
    Check 'Patch preserves title MSIX and credentials blocks' {
        $text=[IO.File]::ReadAllText($plan.stagedPath)
        Assert ($text.Contains('# MSIX / DPAPI MUST REMAIN'));Assert ($text.Contains('$env:FREEHYY_API_KEY=''untouched-example'''))
        Assert ($text.Contains('$titleHelper=''native-title-0.1.4'''))
        Assert ($text.IndexOf('# END CODEX NATIVE TITLE v1') -lt $text.IndexOf('# BEGIN CODEX ADAPTIVE OBSERVER v1'))
        Assert ($text.Contains('-WindowStyle Hidden -WorkingDirectory'))
    }
    Check 'Duplicate question template is rejected' {Reject {New-AbiLauncherPatch ($template+"`n"+$template) 'x' 'y' 'z' 'q' 'r' 's'} 'TEMPLATE_UNKNOWN'}
    Check 'Integration tampering is rejected' {Reject {Read-AbiIntegration $integrationPath ('0'*64)} 'INTEGRATION_CHANGED'}
    Check 'Apply installs only future startup and health registration' {
        $result=& (Join-Path $bundle 'Install-AdaptiveBridge.ps1') -Apply -Destination $destination -Launcher $launcher
        Assert ($result.state -eq 'installed-next-complete-start')
        Assert (([IO.File]::ReadAllText((Join-Path $state 'question-bridge.local.json'))|ConvertFrom-Json).directory -eq $oldDir)
    }
    $launchArgs=@{IntegrationPath=$integrationPath;IntegrationSha256=$plan.integrationHash;ApiHome=$instance.home;Profile=$instance.profile;DesktopExecutable=(Join-Path $sandbox 'Desktop.exe')}
    Check 'First startup remains native and clears inherited CLI override' {$env:CODEX_CLI_PATH='wrong';$result=Get-AdaptiveBridgeLaunch @launchArgs;Assert ($null -eq $result);Assert (-not(Test-Path Env:\CODEX_CLI_PATH));Assert (([IO.File]::ReadAllText((Join-Path $destination 'state\status.json'))|ConvertFrom-Json).reason -eq 'FIRST_NATIVE_LAUNCH')}
    $candidate=Join-Path $destination 'versions\candidate';[void][IO.Directory]::CreateDirectory($candidate)
    Check 'Validated candidate promotes binding before environment selection' {
        Write-AbiStatus $integration 'waiting_restart' 'COMPATIBLE_PREPARED' $candidate 'test'
        $result=Get-AdaptiveBridgeLaunch @launchArgs
        Assert ($null -ne $result);Assert ($env:CODEX_CLI_PATH -eq (Join-Path $candidate 'BridgeProxy.exe'))
        Assert (([IO.File]::ReadAllText((Join-Path $state 'question-bridge.local.json'))|ConvertFrom-Json).directory -eq $candidate)
        Assert (([IO.File]::ReadAllText((Join-Path $destination 'state\promotion.json'))|ConvertFrom-Json).state -eq 'committed')
    }
    Check 'Running instance never rebinds' {
        $config.testState='Running';Write-AbiJson $configPath $config
        $before=Get-AbiHash (Join-Path $state 'question-bridge.local.json');$result=Get-AdaptiveBridgeLaunch @launchArgs
        Assert ($null -eq $result);Assert (-not(Test-Path Env:\CODEX_CLI_PATH));Assert ($before -eq (Get-AbiHash (Join-Path $state 'question-bridge.local.json')))
        $config.testState='Stopped';Write-AbiJson $configPath $config
    }
    Check 'Candidate validation failure stays native' {
        Write-AbiStatus $integration 'waiting_restart' 'COMPATIBLE_PREPARED' $candidate 'test'
        [IO.File]::WriteAllText((Join-Path $destination 'reject-candidate'),'test')
        $result=Get-AdaptiveBridgeLaunch @launchArgs;Assert ($null -eq $result);Assert (-not(Test-Path Env:\CODEX_CLI_PATH))
        Remove-Item -LiteralPath (Join-Path $destination 'reject-candidate')
    }
    Check 'Legacy disable is not silently overridden' {
        Write-AbiStatus $integration 'waiting_restart' 'COMPATIBLE_PREPARED' $candidate 'test'
        [IO.File]::WriteAllText((Join-Path $oldDir 'DISABLED'),'test')
        $result=Get-AdaptiveBridgeLaunch @launchArgs;Assert ($null -eq $result);Assert (([IO.File]::ReadAllText((Join-Path $destination 'state\status.json'))|ConvertFrom-Json).state -eq 'disabled')
        Remove-Item -LiteralPath (Join-Path $oldDir 'DISABLED')
    }
    Check 'Observer clears all provider secrets before modules' {
        $observer=[IO.File]::ReadAllText((Join-Path $testSource 'Observe-AdaptiveBridge.ps1'))
        Assert ($observer.IndexOf('Get-ChildItem Env:') -lt $observer.IndexOf(". (Join-Path"))
        Assert (-not $observer.Contains('ConvertTo-SecureString'));Assert (-not $observer.Contains('config.toml'))
    }
    Check 'Bundle drift fails closed' {
        Add-Content -LiteralPath (Join-Path $destination 'bin\RealCliQuestionFixture.exe') -Value 'drift'
        Reject {Read-AbiIntegration $integrationPath $plan.integrationHash} 'BUNDLE_CHANGED'
        [IO.File]::Copy((Join-Path $bundle 'bin\RealCliQuestionFixture.exe'),(Join-Path $destination 'bin\RealCliQuestionFixture.exe'),$true)
    }
    Check 'Rollback retains unrelated edits title and active registration' {
        Add-Content -LiteralPath $launcher -Value "`n# unrelated later change"
        $before=Get-AbiHash (Join-Path $state 'question-bridge.local.json')
        $result=& (Join-Path $bundle 'Rollback-AdaptiveBridge.ps1') -Installation $destination -Apply
        Assert ($result.state -eq 'rolled-back')
        $text=[IO.File]::ReadAllText($launcher);Assert ($text.Contains('# unrelated later change'));Assert ($text.Contains('$titleHelper=''native-title-0.1.4'''));Assert (-not $text.Contains('# BEGIN CODEX ADAPTIVE'))
        Assert ($before -eq (Get-AbiHash (Join-Path $state 'question-bridge.local.json')))
        Assert (Test-Path -LiteralPath (Join-Path $destination 'DISABLED'))
        Assert ($text.Contains('# ADAPTIVE ROLLBACK NATIVE SAFETY'))
    }
    Check 'Repeated rollback preserves later edits and never activates old bridge' {
        $before=Get-AbiHash $launcher
        $result=& (Join-Path $bundle 'Rollback-AdaptiveBridge.ps1') -Installation $destination -Apply
        Assert ($result.state -eq 'rolled-back');Assert ((Get-AbiHash $launcher) -eq $before)
        $text=[IO.File]::ReadAllText($launcher)
        Assert ($text.Split(@('# ADAPTIVE ROLLBACK NATIVE SAFETY'),[StringSplitOptions]::None).Length -eq 2)
        Assert ($text.IndexOf('# ADAPTIVE ROLLBACK NATIVE SAFETY') -gt $text.IndexOf('Get-ValidatedApiQuestionBridge'))
    }
    Write-Output ('PASS total='+$script:passed)
} finally {
    Remove-Item Env:\CODEX_CLI_PATH -ErrorAction SilentlyContinue
    # Leave isolated artifacts for diagnosis; never recursively delete from tests.
    Write-Output ('Artifacts: '+$sandbox)
}
