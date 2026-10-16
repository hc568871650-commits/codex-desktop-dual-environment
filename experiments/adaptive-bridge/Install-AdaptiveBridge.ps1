[CmdletBinding()]
param([switch]$PrepareOnly,[switch]$Apply,[switch]$FunctionsOnly,
    [string]$Version='adaptive-0.1.0-20261016',[string]$Source=$PSScriptRoot,[string]$Destination='',
    [string]$ControllerRoot='D:\Backup\Documents\ChatGPT\codex双开\CodexDual-Control',
    [string]$Launcher='E:\Codex-API\Launcher\Start-Codex-API.ps1',
    [string]$ExpectedLauncherSha256='', [string]$ProxyPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Launch-AdaptiveBridge.ps1')
function Assert-AbiSyntax([string]$Text) {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw 'ADAPTIVE_PATCH_SYNTAX_INVALID'}
}
function New-AbiLauncherPatch([string]$Text,[string]$Helper,[string]$HelperHash,[string]$IntegrationPath,[string]$IntegrationHash,[string]$Observer,[string]$ObserverHash) {
    foreach($path in @($Helper,$IntegrationPath,$Observer)){if($path -match "['`r`n]"){throw 'ADAPTIVE_PATCH_PATH_INVALID'}}
    if($Text.Contains('# BEGIN CODEX ADAPTIVE BRIDGE')){throw 'ADAPTIVE_ALREADY_PATCHED'}
    $pattern='(?ms)^        # API-only question takeover\. Any validation failure keeps the native CLI\.\r?\n.*?(?=^        New-Item -ItemType Directory -Path \$apiCodexHome, \$apiDesktopProfile, \$apiProjectlessRoot -Force \| Out-Null)'
    $matches=[regex]::Matches($Text,$pattern)
    if($matches.Count -ne 1 -or -not $matches[0].Value.Contains('Get-ValidatedApiQuestionBridge')){throw 'ADAPTIVE_QUESTION_TEMPLATE_UNKNOWN'}
    $before=$matches[0].Value
    $anchor='        # END CODEX NATIVE TITLE v1'
    if($Text.Split(@($anchor),[StringSplitOptions]::None).Length -ne 2){throw 'ADAPTIVE_POSTLAUNCH_ANCHOR_UNKNOWN'}
    $newline=if($Text.Contains("`r`n")){"`r`n"}else{"`n"}
    $after=@'
        # BEGIN CODEX ADAPTIVE BRIDGE v1
        Remove-Item Env:\CODEX_CLI_PATH -ErrorAction SilentlyContinue
        try {
            $adaptiveHelper = '__HELPER__'
            if ((Get-FileHash -LiteralPath $adaptiveHelper -Algorithm SHA256).Hash -ne '__HELPER_HASH__') { throw 'Adaptive helper changed.' }
            . $adaptiveHelper
            $adaptiveBinding = Get-AdaptiveBridgeLaunch -IntegrationPath '__INTEGRATION__' -IntegrationSha256 '__INTEGRATION_HASH__' -ApiHome $apiCodexHome -Profile $apiDesktopProfile -DesktopExecutable $codexDesktopExe
            if ($adaptiveBinding) { Write-LauncherLog 'Validated adaptive question bridge selected; connection not yet verified.' }
            else { Write-LauncherLog 'Adaptive question bridge using native fallback; see adaptive health status.' }
        } catch {
            Remove-Item Env:\CODEX_CLI_PATH -ErrorAction SilentlyContinue
            Write-LauncherLog 'Adaptive question helper unavailable; native CLI preserved.'
        }
        # END CODEX ADAPTIVE BRIDGE v1
'@
    $observerBlock=@'
        # BEGIN CODEX ADAPTIVE OBSERVER v1
        try {
            $adaptiveObserver = '__OBSERVER__'
            if ((Get-FileHash -LiteralPath $adaptiveObserver -Algorithm SHA256).Hash -ne '__OBSERVER_HASH__') { throw 'Adaptive observer changed.' }
            $adaptiveObserverArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $adaptiveObserver + '" -IntegrationPath "__INTEGRATION__" -IntegrationSha256 "__INTEGRATION_HASH__"'
            Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $adaptiveObserverArgs -WindowStyle Hidden -WorkingDirectory $apiRoot | Out-Null
            Write-LauncherLog 'Credential-free adaptive compatibility observer queued.'
        } catch { Write-LauncherLog 'Adaptive observer unavailable; native startup remains usable.' }
        # END CODEX ADAPTIVE OBSERVER v1
'@
    foreach($pair in @(@('__HELPER__',$Helper),@('__HELPER_HASH__',$HelperHash),@('__INTEGRATION__',$IntegrationPath),@('__INTEGRATION_HASH__',$IntegrationHash),@('__OBSERVER__',$Observer),@('__OBSERVER_HASH__',$ObserverHash))){$after=$after.Replace($pair[0],$pair[1]);$observerBlock=$observerBlock.Replace($pair[0],$pair[1])}
    $after=$after.Replace("`r`n","`n").Replace("`n",$newline)+$newline
    $observerAfter=$anchor+$newline+$observerBlock.Replace("`r`n","`n").Replace("`n",$newline)
    $patched=$Text.Replace($before,$after).Replace($anchor,$observerAfter)
    Assert-AbiSyntax $patched
    return [pscustomobject]@{Text=$patched;questionBefore=$before;questionAfter=$after;observerBefore=$anchor;observerAfter=$observerAfter}
}
function Write-AbiLauncherReplacement([string]$Launcher,[string]$Text,[string]$ExpectedHash) {
    Assert-AbiPlainPath $Launcher;Assert-AbiSyntax $Text
    $bytes=[IO.File]::ReadAllBytes($Launcher)
    $bom=$bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    $temp=$Launcher+'.adaptive-'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,$Text,(New-Object Text.UTF8Encoding($bom)))
        if((Get-AbiHash $Launcher) -ne $ExpectedHash){throw 'ADAPTIVE_LAUNCHER_CONCURRENT_CHANGE'}
        [IO.File]::Replace($temp,$Launcher,[NullString]::Value)
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
    if([IO.File]::ReadAllText($Launcher) -cne $Text){throw 'ADAPTIVE_LAUNCHER_WRITE_FAILED'}
}
if($FunctionsOnly){return}
if($PrepareOnly -and $Apply){throw 'CHOOSE_PREPARE_OR_APPLY'}
if($Version -notmatch '^[A-Za-z0-9._-]+$'){throw 'INVALID_VERSION'}
if(-not $Destination){$Destination=Join-Path 'E:\Codex-API\AdaptiveBridge' $Version}
$Destination=[IO.Path]::GetFullPath($Destination);Assert-AbiPlainPath $Destination
$planPath=Join-Path $Destination 'install-plan.json'
if($Apply) {
    Assert-AbiPlainPath $planPath;$plan=[IO.File]::ReadAllText($planPath)|ConvertFrom-Json
    if($plan.schema -ne 1 -or -not(Test-AbiPath $plan.destination $Destination) -or -not(Test-AbiPath $plan.launcher $Launcher)){throw 'ADAPTIVE_PLAN_MISMATCH'}
    $integration=Read-AbiIntegration (Join-Path $Destination 'integration.json') $plan.integrationHash
    $context=Import-AbiContext $integration
    if(-not(Test-AbiPath $context.config.stateDirectory $plan.stateDirectory)){throw 'ADAPTIVE_CONTROLLER_STATE_CHANGED'}
    if((Get-AbiHash $Launcher) -ne $plan.originalHash -or (Get-AbiHash $plan.backupPath) -ne $plan.originalHash -or (Get-AbiHash $plan.stagedPath) -ne $plan.stagedHash){throw 'ADAPTIVE_INSTALL_ARTIFACT_DRIFT'}
    $registration=Join-Path $plan.stateDirectory 'adaptive-bridge.local.json';Assert-AbiPlainPath $registration
    if(Test-Path -LiteralPath $registration){throw 'ADAPTIVE_REGISTRATION_ALREADY_EXISTS'}
    # Registration first is safe: until the launcher patch is committed it cannot
    # select a new CLI. If patching fails, remove only our exact registration.
    Write-AbiJson $registration @{schema=1;instanceId=$integration.instanceId;root=$Destination;enabled=$true}
    $registrationHash=Get-AbiHash $registration
    try{Write-AbiLauncherReplacement $Launcher ([IO.File]::ReadAllText($plan.stagedPath)) $plan.originalHash}
    catch{if((Test-Path -LiteralPath $registration) -and (Get-AbiHash $registration) -eq $registrationHash){Remove-Item -LiteralPath $registration -Force};throw}
    Write-AbiJson (Join-Path $Destination 'applied.json') @{schema=1;launcher=$Launcher;installedHash=(Get-AbiHash $Launcher);registrationHash=$registrationHash;installedUtc=[DateTime]::UtcNow.ToString('o')}
    [pscustomobject]@{state='installed-next-complete-start';destination=$Destination;restarted=$false;controllerQuestionBindingChanged=$false};return
}
if(Test-Path -LiteralPath $Destination){throw 'DESTINATION_EXISTS'}
if($ExpectedLauncherSha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'EXPECTED_LAUNCHER_HASH_REQUIRED'}
Assert-AbiPlainPath $Launcher
if((Get-AbiHash $Launcher) -ne $ExpectedLauncherSha256){throw 'ADAPTIVE_LAUNCHER_TEMPLATE_CHANGED'}
Assert-AbiPlainPath $ControllerRoot
. (Join-Path $ControllerRoot 'src\Instances.ps1')
$configPath=Join-Path $ControllerRoot 'instances.local.json';$config=Read-ControllerConfig $configPath
$instances=@($config.instances|Where-Object role -eq 'api')
if($instances.Count -ne 1 -or $instances[0].launchMode -ne 'external' -or -not(Test-AbiPath $instances[0].externalLauncher $Launcher)){throw 'ADAPTIVE_API_LAUNCHER_MISMATCH'}
$instance=$instances[0]
$legacyPath=Join-Path $config.stateDirectory 'question-bridge.local.json';$legacy=''
if(Test-Path -LiteralPath $legacyPath){Assert-AbiPlainPath $legacyPath;$saved=[IO.File]::ReadAllText($legacyPath)|ConvertFrom-Json;if($saved.schema -ne 1 -or $saved.instanceId -ne $instance.id){throw 'ADAPTIVE_OLD_REGISTRATION_INVALID'};$legacy=[string]$saved.directory;Assert-AbiPlainPath $legacy}
if(-not $ProxyPath){throw 'PROXY_REQUIRED'}
foreach($path in @($Source,$ProxyPath)){Assert-AbiPlainPath $path}
$required=@('Launch-AdaptiveBridge.ps1','Observe-AdaptiveBridge.ps1','Install-AdaptiveBridge.ps1','Rollback-AdaptiveBridge.ps1','AdaptiveBridge.ps1','Invoke-Compatibility.ps1','bin\RealCliQuestionFixture.exe')
foreach($relative in $required){if(-not(Test-Path -LiteralPath (Join-Path $Source $relative) -PathType Leaf)){throw ('MISSING_BUNDLE_FILE: '+$relative)}}
[void][IO.Directory]::CreateDirectory($Destination)
[void][IO.Directory]::CreateDirectory((Join-Path $Destination 'state'))
foreach($file in @(Get-ChildItem -LiteralPath $Source -File -Recurse)) {
    Assert-AbiPlainPath $file.FullName
    $relative=$file.FullName.Substring([IO.Path]::GetFullPath($Source).TrimEnd('\').Length).TrimStart('\')
    if($relative -match '^(tests|guard-compat)[\\/]' -or $relative -eq 'BridgeProxy.exe'){continue}
    $target=Join-Path $Destination $relative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));[IO.File]::Copy($file.FullName,$target,$false)
}
[IO.File]::Copy($ProxyPath,(Join-Path $Destination 'BridgeProxy.exe'),$false)
$files=@(Get-ChildItem -LiteralPath $Destination -File -Recurse|ForEach-Object {@{path=$_.FullName.Substring($Destination.TrimEnd('\').Length).TrimStart('\');sha256=(Get-AbiHash $_.FullName)}})
$dependencies=@()
foreach($name in @('Instances.ps1','Core.ps1','Native.cs','TomlConfig.cs','Preferences.ps1','ApiManagement.ps1','QuestionBridgeLaunch.ps1')){$path=Join-Path $ControllerRoot ('src\'+$name);Assert-AbiPlainPath $path;$dependencies+=@{path=$path;sha256=(Get-AbiHash $path)}}
$integration=[ordered]@{schema=1;version=$Version;root=$Destination;controllerRoot=$ControllerRoot;controllerConfig=$configPath;instanceId=$instance.id;apiHome=$instance.home;profile=$instance.profile;launcher=$Launcher;legacyBridgeDirectory=$legacy;proxyPath=(Join-Path $Destination 'BridgeProxy.exe');compatibilityScript=(Join-Path $Destination 'Invoke-Compatibility.ps1');bundleFiles=$files;dependencies=$dependencies}
$integrationPath=Join-Path $Destination 'integration.json';Write-AbiJson $integrationPath $integration
$integrationHash=Get-AbiHash $integrationPath
$helper=Join-Path $Destination 'Launch-AdaptiveBridge.ps1';$observer=Join-Path $Destination 'Observe-AdaptiveBridge.ps1'
$original=[IO.File]::ReadAllText($Launcher)
$patch=New-AbiLauncherPatch $original $helper (Get-AbiHash $helper) $integrationPath $integrationHash $observer (Get-AbiHash $observer)
$backup=Join-Path $Destination 'launcher.original.ps1';[IO.File]::Copy($Launcher,$backup,$false)
$staged=Join-Path $Destination 'launcher.staged.ps1'
[IO.File]::WriteAllText($staged,$patch.Text,(New-Object Text.UTF8Encoding($true)))
$plan=[ordered]@{schema=1;destination=$Destination;launcher=$Launcher;stateDirectory=$config.stateDirectory;originalHash=$ExpectedLauncherSha256;stagedHash=(Get-AbiHash $staged);integrationHash=$integrationHash;backupPath=$backup;stagedPath=$staged;questionBefore=$patch.questionBefore;questionAfter=$patch.questionAfter;observerBefore=$patch.observerBefore;observerAfter=$patch.observerAfter;preparedUtc=[DateTime]::UtcNow.ToString('o')}
Write-AbiJson $planPath $plan
[void](Read-AbiIntegration $integrationPath $integrationHash)
[pscustomobject]@{state='prepared-only';destination=$Destination;plan=$planPath;changedLiveLauncher=$false;controllerQuestionBindingChanged=$false}
