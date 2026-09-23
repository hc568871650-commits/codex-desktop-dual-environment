$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
. "$PSScriptRoot\..\src\Diagnostics.ps1"
$script:passed=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
function MustThrow([scriptblock]$Action,[string]$Message){$thrown=$false;try{& $Action|Out-Null}catch{$thrown=$true};Check $thrown $Message}

$root=Join-Path ([IO.Path]::GetTempPath()) ('dual-diagnostics-'+[Guid]::NewGuid().ToString('N')+' 中文')
[void][IO.Directory]::CreateDirectory($root)
$tool=Join-Path $root 'tool';[void][IO.Directory]::CreateDirectory($tool)
$secret='SECRET-PATH-KEY-MODEL-https://sensitive.invalid'
$official=[pscustomobject]@{role='official';id='1';home=(Join-Path $root 'official-home');profile=(Join-Path $root 'official-profile');projects=(Join-Path $root 'official-projects');projectless=(Join-Path $root 'official-projectless');launchMode='official';executable=$secret}
$api=[pscustomobject]@{role='api';id='2';home=(Join-Path $root 'api-home');profile=(Join-Path $root 'api-profile');projects=(Join-Path $root 'api-projects');projectless=(Join-Path $root 'api-projectless');apiRoot=(Join-Path $root 'api-root');launchMode='managed-api';executable=$secret}
$config=[pscustomobject]@{schema=1;stateDirectory=(Join-Path $root 'state');displayName=$secret;instances=@($official,$api)}
$originalStatus=(Get-Command Get-InstanceStatus).ScriptBlock
$originalMode=(Get-Command Get-ApiManagementMode).ScriptBlock
try {
    foreach($instance in $config.instances){foreach($key in @('home','profile','projects','projectless')){[void][IO.Directory]::CreateDirectory($instance.$key)}}
    [void][IO.Directory]::CreateDirectory((Join-Path $api.apiRoot 'Credentials'))
    [IO.File]::WriteAllText((Join-Path $api.apiRoot 'Credentials\api-key.dpapi'),$secret)
    [IO.File]::WriteAllText((Join-Path $tool 'version.json'),'{"product":"codex-desktop-dual-environment","version":"0.4.0","name":"'+$secret+'"}')
    function Get-InstanceStatus($Config,$Instance){[pscustomobject]@{State=if($Instance.role -eq 'official'){'Running'}else{'Stopped'};Reason=$secret;Process=[pscustomobject]@{Command=$secret}}}
    function Get-ApiManagementMode([string]$Root){'builtin'}
    $report=Get-ControllerDiagnostics $config $tool
    Check ($report.Schema -eq 1 -and $report.Version -eq '0.4.0' -and $report.Runtime.OS -eq 'Windows') 'Version and runtime are structured'
    Check ($report.Instances.Count -eq 2 -and $report.Instances[0].Role -eq 'official' -and $report.Instances[1].Role -eq 'api') 'Only fixed roles are reported'
    Check ($report.Instances[0].State -eq 'Running' -and $report.Instances[1].State -eq 'Stopped') 'Statuses are restricted to fixed states'
    Check ($report.Instances[1].CredentialEntryPresent -and $report.Instances[1].ManagementMode -eq 'builtin') 'Credential entry existence is boolean'
    Check (@($report.Checks|Where-Object {$_.Code -eq 'CREDENTIAL_PRESENT' -and $_.Severity -eq 'ok'}).Count -eq 1) 'Credential check is classified'
    $json=$report|ConvertTo-Json -Depth 8;$text=ConvertTo-ControllerDiagnosticText $report
    Check (-not $json.Contains($secret) -and -not $text.Contains($secret) -and -not $json.Contains($root)) 'Structured and text reports omit bait values and paths'
    Check ($text.Contains('运行状态不代表任务空闲') -and $text.Contains('STATUS_RUNNING')) 'Text explains status limitations and check codes'
    $path=Join-Path $root 'diagnostics.txt';Export-ControllerDiagnostics $report $path
    $bytes=[IO.File]::ReadAllBytes($path)
    Check ($bytes.Length -gt 3 -and $bytes[0] -ne 239 -and [IO.File]::ReadAllText($path).Contains('诊断报告')) 'Export is UTF-8 plain text without BOM'
    $hash=(Get-FileHash $path).Hash
    MustThrow {Export-ControllerDiagnostics $report $path} 'Export refuses to overwrite existing report'
    Check ((Get-FileHash $path).Hash -eq $hash) 'Existing report bytes stay intact'
    $report.Checks[0].Message=$secret;$report.Checks[0].Advice=$secret
    Check (-not (ConvertTo-ControllerDiagnosticText $report).Contains($secret)) 'Text reconstitutes descriptions from code whitelist'

    $api.projects=Join-Path $root 'missing';$api.profile=$official.profile
    [IO.File]::Delete((Join-Path $api.apiRoot 'Credentials\api-key.dpapi'))
    $bad=Get-ControllerDiagnostics $config $tool
    Check (@($bad.Checks|Where-Object {$_.Code -eq 'PATH_CONFLICT' -and $_.Severity -eq 'error'}).Count -ge 1) 'Overlapping directory reports error'
    Check (@($bad.Checks|Where-Object {$_.Code -eq 'DIRECTORY_MISSING' -and $_.Severity -eq 'error'}).Count -ge 1) 'Missing directory reports actionable error'
    Check (@($bad.Checks|Where-Object {$_.Code -eq 'CREDENTIAL_MISSING' -and $_.Severity -eq 'error'}).Count -eq 1) 'Missing credential entry reports error'
    function Get-InstanceStatus($Config,$Instance){throw $secret}
    function Get-ApiManagementMode([string]$Root){throw $secret}
    $failed=Get-ControllerDiagnostics $config $tool
    Check (@($failed.Instances|Where-Object {$_.State -eq 'Unknown'}).Count -eq 2 -and $failed.Instances[1].ManagementMode -eq 'unknown') 'Failed probes become fixed unknown values'
    Check (-not (($failed|ConvertTo-Json -Depth 8).Contains($secret)) -and -not (ConvertTo-ControllerDiagnosticText $failed).Contains($secret)) 'Probe exceptions never escape into report'
    $config.instances=@($official,$official)
    $invalid=Get-ControllerDiagnostics $config $tool
    Check (@($invalid.Checks|Where-Object {$_.Code -eq 'CONFIG_INVALID' -and $_.Severity -eq 'error'}).Count -eq 1) 'Invalid role configuration reports error'
    Check (@($invalid.Instances|Where-Object {$_.Role -eq 'api'}).Count -eq 0) 'Duplicate role cannot be mistaken for API instance'
    $config.instances=@($official,$api)
    function Get-ApiManagementMode([string]$Root){'ccs'}
    $ccs=Get-ControllerDiagnostics $config $tool
    Check ($ccs.Instances[1].ManagementMode -eq 'ccs' -and $null -eq $ccs.Instances[1].CredentialEntryPresent) 'CCS branch does not inspect built-in credential entry'
    $api.launchMode='external'
    $external=Get-ControllerDiagnostics $config $tool
    Check ($external.Instances[1].ManagementMode -eq 'external' -and @($external.Checks|Where-Object {$_.Code -eq 'MODE_EXTERNAL'}).Count -eq 1) 'External launcher is a fixed management mode'
    Check (@($external.Checks|Where-Object {$_.Code -eq 'LAUNCHER_UNKNOWN'}).Count -eq 1) 'Missing launcher setting is not trusted'
    $launcher=Join-Path $root 'external-launch.ps1';[IO.File]::WriteAllText($launcher,'# fixture')
    $api|Add-Member NoteProperty externalLauncher $launcher
    $external=Get-ControllerDiagnostics $config $tool
    Check (@($external.Checks|Where-Object {$_.Code -eq 'LAUNCHER_PRESENT' -and $_.Severity -eq 'ok'}).Count -eq 1) 'Configured external launcher file exists'
    [IO.File]::Delete($launcher)
    $external=Get-ControllerDiagnostics $config $tool
    Check (@($external.Checks|Where-Object {$_.Code -eq 'LAUNCHER_MISSING' -and $_.Severity -eq 'error'}).Count -eq 1) 'Missing external launcher gets fixed advice'
    $api.launchMode='nonsense'
    $unknownMode=Get-ControllerDiagnostics $config $tool
    Check ($unknownMode.Instances[1].ManagementMode -eq 'unknown' -and @($unknownMode.Checks|Where-Object {$_.Code -eq 'MODE_UNKNOWN'}).Count -eq 1) 'Unknown launch mode is not treated as external'
    $api.launchMode='managed-api'
    $official.profile='';$official.projectless='';$official|Add-Member NoteProperty projectlessMode 'inherit'
    $inherited=Join-Path $root 'inherited-projectless';[void][IO.Directory]::CreateDirectory($inherited)
    [IO.File]::WriteAllText((Join-Path $official.home 'config.toml'),("[desktop]`r`nprojectlessWorkspaceRoot = '"+$inherited+"'"))
    $inheritedReport=Get-ControllerDiagnostics $config $tool
    Check ($null -eq $inheritedReport.Instances[0].Directories.profile -and @($inheritedReport.Checks|Where-Object {$_.Code -eq 'PROFILE_NATIVE' -and $_.Severity -eq 'ok'}).Count -eq 1) 'Blank official profile means native default, not missing'
    Check ($inheritedReport.Instances[0].Directories.projectless -eq $true) 'Inherited official projectless directory is read and checked'
    Check (@($inheritedReport.Checks|Where-Object {$_.Role -eq 'official' -and $_.Code -eq 'DIRECTORY_MISSING'}).Count -eq 0) 'Native profile and valid inherited directory create no missing warning'
    [IO.Directory]::Delete($inherited)
    $missingInherited=Get-ControllerDiagnostics $config $tool
    Check ($missingInherited.Instances[0].Directories.projectless -eq $false -and @($missingInherited.Checks|Where-Object {$_.Role -eq 'official' -and $_.Code -eq 'DIRECTORY_MISSING'}).Count -eq 1) 'Inherited missing projectless directory is reported'
    [IO.File]::WriteAllText((Join-Path $official.home 'config.toml'),$secret)
    $unresolved=Get-ControllerDiagnostics $config $tool
    Check ($null -eq $unresolved.Instances[0].Directories.projectless -and @($unresolved.Checks|Where-Object {$_.Code -eq 'PROJECTLESS_UNKNOWN'}).Count -eq 1) 'Unreadable inherited projectless uses fixed warning'
    Check (-not (($unresolved|ConvertTo-Json -Depth 8).Contains($secret))) 'Inherited config error omits content'
    $api.home=Join-Path $api.apiRoot 'CodexHome';[void][IO.Directory]::CreateDirectory($api.home)
    $settings=Join-Path $root 'ccs-settings.json';$ccsExe=Join-Path $root 'CCSwitch.exe'
    [IO.File]::WriteAllText($ccsExe,'fixture')
    [IO.File]::WriteAllText($settings,(@{codexConfigDir=$api.home}|ConvertTo-Json))
    [IO.File]::WriteAllText((Join-Path $api.apiRoot '.codex-dual.json'),(@{managementMode='ccs';ccsSettingsPath=$settings;ccsExecutable=$ccsExe}|ConvertTo-Json))
    $ccsGood=Get-ControllerDiagnostics $config $tool
    Check (@($ccsGood.Checks|Where-Object {$_.Code -eq 'CCS_BINDING_OK' -and $_.Severity -eq 'ok'}).Count -eq 1) 'CCS binding validates matching settings'
    [IO.File]::WriteAllText($settings,(@{codexConfigDir=$secret}|ConvertTo-Json))
    $ccsBad=Get-ControllerDiagnostics $config $tool
    Check (@($ccsBad.Checks|Where-Object {$_.Code -eq 'CCS_BINDING_INVALID' -and $_.Severity -eq 'error'}).Count -eq 1) 'CCS binding mismatch is fixed error'
    Check (-not (($ccsBad|ConvertTo-Json -Depth 8).Contains($secret))) 'CCS binding exception omits sensitive setting'
    [IO.File]::WriteAllText((Join-Path $tool 'version.json'),'{invalid '+$secret)
    $badVersion=Get-ControllerDiagnostics $config $tool
    Check ($badVersion.Version -eq 'unknown' -and @($badVersion.Checks|Where-Object {$_.Code -eq 'VERSION_UNKNOWN' -and $_.Severity -eq 'warning'}).Count -eq 1) 'Malformed version is reported without its contents'
    Check (-not (($badVersion|ConvertTo-Json -Depth 8).Contains($secret))) 'Malformed version contents are absent from report'
}finally{
    Set-Item Function:Get-InstanceStatus $originalStatus
    Set-Item Function:Get-ApiManagementMode $originalMode
}
Write-Output "Diagnostics checks passed: $script:passed"
