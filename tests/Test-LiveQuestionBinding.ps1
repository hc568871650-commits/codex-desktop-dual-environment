$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\..\src\Instances.ps1"
. "$PSScriptRoot\..\src\PendingQuestions.ps1"
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('CodexLiveBinding-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$bridge=Join-Path $fixture 'bridge';$apiFixtureHome=Join-Path $fixture 'home';$profile=Join-Path $fixture 'profile'
foreach($directory in @($bridge,$apiFixtureHome,$profile)){[void][IO.Directory]::CreateDirectory($directory)}
$desktop=Join-Path $fixture 'desktop.exe';$cli=Join-Path $fixture 'cli.exe';$proxy=Join-Path $bridge 'BridgeProxy.exe'
foreach($file in @($desktop,$cli,$proxy)){[IO.File]::WriteAllText($file,('FAKE TEST FILE '+$file))}
$manifestPath=Join-Path $bridge 'binding.json';$bridgeConfigPath=Join-Path $bridge 'bridge.config.json';$disabled=Join-Path $bridge 'DISABLED'
$identity='0123456789abcdef0123456789abcdef';$controllerId='abcdef0123456789abcdef0123456789'
$script:passed=0
function Assert-Test([bool]$Condition,[string]$Name){if(-not $Condition){throw ('FAIL: '+$Name)};$script:passed++;Write-Output ('PASS: '+$Name)}
function Save-Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))}
function Reset-Fixture {
    foreach($path in @($disabled,(Join-Path $bridge 'trial.json'))){if(Test-Path -LiteralPath $path){[IO.File]::Delete($path)}}
    $script:bridgeConfig=@{apiHome=$apiFixtureHome;realCli=$cli;instanceId=('api-live-'+$identity);pipeName=('codex-api-questions-'+$identity);takeoverQuestions=$true}
    Save-Json $bridgeConfigPath $script:bridgeConfig
    $script:manifest=@{schema=1;kind='api-question-bridge-installation';id=$identity;root=$bridge;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;controllerInstanceId=$controllerId;apiHome=$apiFixtureHome;profile=$profile;realCli=$cli;realCliHash=(Get-FileHash $cli).Hash;desktopExe=$desktop;desktopHash=(Get-FileHash $desktop).Hash;proxyHash=(Get-FileHash $proxy).Hash;configHash=(Get-FileHash $bridgeConfigPath).Hash}
    Save-Json $manifestPath $script:manifest
}
function Read-TestBridge {return Get-ValidatedApiQuestionBridge -Directory $bridge -ApiHome $apiFixtureHome -Profile $profile -DesktopExecutable $desktop -InstanceId $controllerId}
function Test-ManifestReject([string]$Field,$Value){Reset-Fixture;$script:manifest[$Field]=$Value;Save-Json $manifestPath $script:manifest;Assert-Test ($null -eq (Read-TestBridge)) ('reject manifest '+$Field)}
function Test-ConfigReject([string]$Field,$Value){Reset-Fixture;$script:bridgeConfig[$Field]=$Value;Save-Json $bridgeConfigPath $script:bridgeConfig;$script:manifest.configHash=(Get-FileHash $bridgeConfigPath).Hash;Save-Json $manifestPath $script:manifest;Assert-Test ($null -eq (Read-TestBridge)) ('reject config '+$Field+' '+$Value)}
try {
    Reset-Fixture;$valid=Read-TestBridge
    Assert-Test ($null -ne $valid -and $valid.proxy -eq $proxy -and $valid.config.instanceId -eq ('api-live-'+$identity)) 'valid production helper binding'
    foreach($case in @(@('schema',2),@('kind','isolated-api-bridge-trial'),@('id','invalid'),@('root',$fixture),@('apiHome',$profile),@('profile',$apiFixtureHome),@('controllerInstanceId','wrong'),@('desktopExe',$cli),@('userSid','S-1-0-0'),@('realCliHash','00'),@('desktopHash','00'),@('proxyHash','00'),@('configHash','00'))){Test-ManifestReject $case[0] $case[1]}
    foreach($case in @(@('apiHome',$profile),@('realCli',$desktop),@('instanceId','wrong'),@('pipeName','wrong'),@('takeoverQuestions',$false),@('takeoverQuestions','true'))){Test-ConfigReject $case[0] $case[1]}
    Reset-Fixture;[IO.File]::WriteAllText($bridgeConfigPath,'{}');Assert-Test ($null -eq (Read-TestBridge)) 'reject changed config bytes'
    Reset-Fixture;[IO.File]::WriteAllText($disabled,'disabled');Assert-Test ($null -eq (Read-TestBridge)) 'DISABLED uses native fallback'
    Assert-Test ($null -ne (Get-ValidatedApiQuestionBridge -Directory $bridge -ApiHome $apiFixtureHome -Profile $profile -DesktopExecutable $desktop -InstanceId $controllerId -IgnoreDisabled)) 'controller may validate disabled binding'
    Reset-Fixture;[IO.File]::WriteAllText((Join-Path $bridge 'trial.json'),'{}');Assert-Test ($null -eq (Read-TestBridge)) 'reject mixed trial and production'
    foreach($path in @($manifestPath,$bridgeConfigPath)){foreach($bad in @('', '{bad json')){Reset-Fixture;[IO.File]::WriteAllText($path,$bad);Assert-Test ($null -eq (Read-TestBridge)) ('reject empty or malformed '+[IO.Path]::GetFileName($path))}}
    Reset-Fixture;[IO.File]::Delete($manifestPath);Assert-Test ($null -eq (Read-TestBridge)) 'missing manifest fallback'
    Reset-Fixture
    $config=[pscustomobject]@{instances=@([pscustomobject]@{id=$controllerId;role='api';home=$apiFixtureHome;profile=$profile},[pscustomobject]@{id='official';role='official';home=(Join-Path $fixture 'official')});stateDirectory=(Join-Path $fixture 'state')}
    $result=Read-QuestionBridgeBinding $bridge
    Assert-Test ($result.instance.id -eq $controllerId -and $result.pipe -eq ('codex-api-questions-'+$identity)) 'controller binds actual registered API instance'
    Assert-Test ($null -eq $script:questionClient -and $null -eq $script:questionBinding -and @($script:questionPending).Count -eq 0) 'read binding has no connection or question state side effects'
    $config.instances[0].id='wrong';$rejected=$false;try{Read-QuestionBridgeBinding $bridge|Out-Null}catch{$rejected=$true};Assert-Test $rejected 'controller rejects changed registration'
    $config.instances[0].id=$controllerId;$config.instances+=@($config.instances[0]);$rejected=$false;try{Read-QuestionBridgeBinding $bridge|Out-Null}catch{$rejected=$true};Assert-Test $rejected 'controller rejects ambiguous API registration'
    $link=Join-Path $fixture 'bridge-link';$linked=$false
    try{New-Item -ItemType Junction -Path $link -Target $bridge -ErrorAction Stop|Out-Null;$linked=$true}catch{Write-Output ('SKIP: junction unavailable: '+$_.Exception.Message)}
    if($linked){Assert-Test ($null -eq (Get-ValidatedApiQuestionBridge -Directory $link -ApiHome $apiFixtureHome -Profile $profile -DesktopExecutable $desktop -InstanceId $controllerId)) 'reject reparse directory';[IO.Directory]::Delete($link)}
    Write-Output ('Live question binding: '+$script:passed+' checks passed; no executable started.')
}finally {
    # Only this explicitly created temporary fixture is removed, after detaching its junction.
    $link=Join-Path $fixture 'bridge-link'
    if(Test-Path -LiteralPath $link){[IO.Directory]::Delete($link)}
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
