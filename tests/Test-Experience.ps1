$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
Add-Type -AssemblyName System.Drawing
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('experience-'+[Guid]::NewGuid().ToString('N')+' 中文 space')
[void][IO.Directory]::CreateDirectory($root)
$official=Join-Path $root 'Official';$api=Join-Path $root 'API';$tool=Join-Path $root 'Tool'
foreach($folder in @($official,$tool)){[void][IO.Directory]::CreateDirectory($folder)}
Write-AtomicText (Join-Path $official 'auth.json') 'official-untouched'
$key=ConvertTo-SecureString 'fixture-key-original' -AsPlainText -Force
try{[void](Save-ApiEnvironment $api $official 'https://old.example.com/v1' 'old-model' $key)}finally{$key.Dispose()}
$config=Get-Content "$PSScriptRoot\..\config\instances.example.json" -Raw|ConvertFrom-Json
$config.stateDirectory=Join-Path $tool 'state'
foreach($instance in $config.instances){
    $base=if($instance.role -eq 'api'){$api}else{$official}
    $instance.home=Join-Path $base 'CodexHome';$instance.profile=Join-Path $base 'DesktopProfile';$instance.projects=Join-Path $base 'Projects';$instance.projectless=Join-Path $base 'Projectless';$instance.executable="$env:SystemRoot\System32\notepad.exe"
    if($instance.role -eq 'api'){$instance.apiRoot=$api}
}
$configPath=Join-Path $tool 'instances.local.json';Write-AtomicText $configPath ($config|ConvertTo-Json -Depth 8)
$config=Read-ControllerConfig $configPath;$instance=$config.instances[1];$offInstance=$config.instances[0]
$configHash=(Get-FileHash $configPath).Hash;$passed=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
function MustThrow([scriptblock]$Action,[string]$Message){$thrown=$false;try{& $Action|Out-Null}catch{$thrown=$true};Check $thrown $Message}

$prefs=Read-ControllerPreferences $config
Check ((Get-InstanceDisplayName $offInstance $prefs) -eq '官方环境') 'Legacy config has default display names'
Check (-not (Test-Path $config.stateDirectory)) 'Reading defaults does not write user state'
[void](Set-InstanceDisplayName $config $offInstance '主力 & 开发')
[void](Set-InstanceDisplayName $config $instance '审查助手')
$prefs=Read-ControllerPreferences $config
Check ((Get-InstanceDisplayName $offInstance $prefs) -eq '主力 & 开发' -and (Get-InstanceDisplayName $instance $prefs) -eq '审查助手') 'Independent names survive rereading preferences'
[void](Set-InstanceDisplayName $config $offInstance '' -Reset)
$prefs=Read-ControllerPreferences $config
Check ((Get-InstanceDisplayName $offInstance $prefs) -eq '官方环境' -and (Get-InstanceDisplayName $instance $prefs) -eq '审查助手') 'Reset affects only selected instance name'
MustThrow {Set-InstanceDisplayName $config $instance '   '} 'Blank name rejected'
MustThrow {Set-InstanceDisplayName $config $instance "bad`nname"} 'Multiline name rejected'
Check ((Get-FileHash $configPath).Hash -eq $configHash) 'Renaming leaves stable identity and environment paths byte-identical'
$prefs.pendingApi=@{pid=123;started=456};$prefs.panel=@{x=-1400;y=50};Save-ControllerPreferences $config $prefs
Check ((Read-ControllerPreferences $config).pendingApi.pid -eq 123) 'Pending configuration notice survives restart'
$areas=@((New-Object Drawing.Rectangle(-1920,0,1920,1080)),(New-Object Drawing.Rectangle(0,0,1920,1040)))
$point=Get-VisiblePanelPoint $prefs.panel 520 400 $areas
Check ($point.x -eq -1400 -and $point.y -eq 50) 'Valid position on negative-coordinate monitor retained'
$point=Get-VisiblePanelPoint @{x=5000;y=3000} 520 400 $areas
Check ($point.x -ge -1920 -and $point.x -le -520 -and $point.y -le 680) 'Missing monitor position brought into visible work area'

$registry='HKCU:\Software\CodexDualTests\'+[Guid]::NewGuid().ToString('N')
Write-AtomicText (Join-Path $tool 'CodexDualController.exe') 'fixture-not-executed'
try{
    Check (-not (Test-ControllerAutoStart $tool $configPath $registry)) 'Startup disabled by default'
    Set-ControllerAutoStart $tool $configPath $true $registry
    Check (Test-ControllerAutoStart $tool $configPath $registry) 'Enable and read startup registration in isolated test key'
    $command=Get-ControllerStartupCommand $tool $configPath
    Check ($command.Contains('" --config "') -and -not $command.Contains('--background') -and $command.EndsWith('instances.local.json"')) 'Startup quotes paths and opens the control panel'
    $startupName=Get-ControllerStartupName $configPath
    [void](New-ItemProperty -LiteralPath $registry -Name $startupName -Value (Get-LegacyControllerStartupCommand $tool $configPath) -PropertyType String -Force)
    Check (Repair-ControllerAutoStart $tool $configPath $registry) 'Legacy background startup registration migrated'
    Check ([string](Get-ItemProperty -LiteralPath $registry).$startupName -eq $command) 'Migrated startup opens the control panel'
    Set-ControllerAutoStart $tool $configPath $true $registry
    Set-ControllerAutoStart $tool $configPath $false $registry
    Check (-not (Test-ControllerAutoStart $tool $configPath $registry)) 'Disable removes exact owned entry'
    [void](New-ItemProperty -LiteralPath $registry -Name $startupName -Value 'changed-by-user' -PropertyType String -Force)
    MustThrow {Set-ControllerAutoStart $tool $configPath $false $registry} 'Modified startup entry preserved'
}finally{if(Test-Path -LiteralPath $registry){Remove-Item -LiteralPath $registry -Force}}

$configFile=Join-Path $instance.home 'config.toml'
$custom=@'

# Exact custom text is retained, including a fake header inside a string.
[mcp_servers."my.server"]
command = 'my-tool'
args = [
  "--flag", # array comment
  "a=b",
]
description = """
[model_providers.dual-api]
model = "must-not-edit"
"""
[features]
enabled = true
[[hooks.Stop]]
matcher = "one"
[[hooks.Stop]]
matcher = "two"
'@
Write-AtomicText $configFile ([IO.File]::ReadAllText($configFile)+$custom)
$initialConfig=[IO.File]::ReadAllText($configFile);$oldKey=[IO.File]::ReadAllText((Join-Path $api 'Credentials\api-key.dpapi'))
$profiles=Read-ApiProfiles $config $instance
Check ($profiles.profiles.Count -eq 1 -and $profiles.activeId -eq 'legacy') 'Existing API imported as a local channel without decrypting it'
$newKey=ConvertTo-SecureString 'fixture-new-secret' -AsPlainText -Force
try{$id=Save-ApiProfile $config $instance '' '备用渠道' 'https://new.example.com/v1' 'new-model' $newKey}finally{$newKey.Dispose()}
Check ([IO.File]::ReadAllText($configFile) -eq $initialConfig -and [IO.File]::ReadAllText((Join-Path $api 'Credentials\api-key.dpapi')) -eq $oldKey) 'Saving a channel does not apply it to the running environment'
$profileFile=Join-Path $api 'api-providers.local.json'
Check (-not [IO.File]::ReadAllText($profileFile).Contains('fixture-new-secret')) 'Channel key encrypted on disk'
Apply-ApiProfile $config $instance $id
$changed=[IO.File]::ReadAllText($configFile)
Check ($changed.EndsWith($custom) -and $changed.Contains('model = "new-model"')) 'Channel switching preserves exact MCP, multiline strings, arrays and hooks'
Check ($changed.Contains('base_url = "https://new.example.com/v1"')) 'Channel switching updates provider address'
$probe=New-CodexStartInfo -Executable 'unused.exe' -OfficialHome $official -ApiRoot $api -Api
try{Check ($probe.EnvironmentVariables['CODEX_DUAL_API_KEY'] -eq 'fixture-new-secret') 'Next API process receives selected channel credential'}finally{$probe.EnvironmentVariables.Remove('CODEX_DUAL_API_KEY')}
$selected=@((Read-ApiProfiles $config $instance).profiles|Where-Object {$_.id -eq $id})[0];$cipher=$selected.keyDpapi
[void](Save-ApiProfile $config $instance $id '备用渠道' 'https://new.example.com/v1' 'another-model' $null)
$updated=@((Read-ApiProfiles $config $instance).profiles|Where-Object {$_.id -eq $id})[0]
Check ($updated.keyDpapi -eq $cipher) 'Blank key edit retains that channel credential'
$originalStatus=(Get-Command Get-InstanceStatus).ScriptBlock
$beforeDeferred=[IO.File]::ReadAllText($configFile);$beforeDeferredKey=[IO.File]::ReadAllText((Join-Path $api 'Credentials\api-key.dpapi'))
function Get-InstanceStatus {param($Config,$Instance) return [pscustomobject]@{State='Running';Process=[pscustomobject]@{Id=111;Started=222}}}
try{
    Check ((Apply-ApiProfile $config $instance $id) -eq 'Deferred') 'Running API queues selection rather than editing live configuration'
    Check ([IO.File]::ReadAllText($configFile) -eq $beforeDeferred -and [IO.File]::ReadAllText((Join-Path $api 'Credentials\api-key.dpapi')) -eq $beforeDeferredKey) 'Deferred switch keeps live endpoint and key byte-identical'
    [void](Save-ApiProfile $config $instance $id '备用渠道' 'https://new.example.com/v1' 'edited-after-queue' $null)
    Check ((Read-ApiProfiles $config $instance).pendingProfile.model -eq 'another-model') 'Queued selection captures the approved profile revision'
}finally{Set-Item Function:\Get-InstanceStatus $originalStatus}
[void](Apply-ApiProfile $config $instance $id -UsePending)
Check ([IO.File]::ReadAllText($configFile).Contains('model = "another-model"') -and $null -eq (Read-ApiProfiles $config $instance).pendingProfile) 'Stopped instance applies queued profile and clears pending state'
MustThrow {Remove-ApiProfile $config $instance $id} 'Deleting active channel rejected'
MustThrow {Save-ApiProfile $config $instance '' '备用渠道' 'https://new.example.com/v1' 'm' $null} 'Duplicate channel name rejected'
$snapshots=@(Get-ChildItem (Join-Path $api 'Backup') -Filter 'snapshot-*.local.json'|Sort-Object CreationTime)
Check ($snapshots.Count -ge 1 -and -not [IO.File]::ReadAllText($snapshots[0].FullName).Contains('fixture-new-secret')) 'Config snapshots protect their complete payload with DPAPI'
Restore-ApiBackup $config $instance $snapshots[0].FullName
Check ([IO.File]::ReadAllText($configFile) -eq $initialConfig -and [IO.File]::ReadAllText((Join-Path $api 'Credentials\api-key.dpapi')) -eq $oldKey) 'Snapshot restore recovers matching original config and credential'
Check ((Read-ApiProfiles $config $instance).activeId -eq 'legacy') 'Snapshot restore also restores active channel identity'
Remove-ApiProfile $config $instance $id
Check (@((Read-ApiProfiles $config $instance).profiles|Where-Object {$_.id -eq $id}).Count -eq 0) 'Inactive channel can be deleted'

$quoted=$initialConfig.Substring(0,$initialConfig.Length-$custom.Length).Replace('[model_providers.dual-api]','[model_providers."dual-api"]').Replace('base_url = ','"base_url" = ')+$custom
$merged=Merge-ApiConfig $quoted $api 'https://quote.example.com/v1' 'quoted-model'
Check ($merged.Contains('"base_url" = "https://quote.example.com/v1"') -and $merged.EndsWith($custom)) 'Quoted TOML table and field names edited without rebuilding file'
MustThrow {Merge-ApiConfig ($initialConfig.Replace('model_provider = "dual-api"','model_provider = "ccs"')) $api 'https://x.example.com' 'x'} 'Externally selected provider is not overwritten'
MustThrow {Merge-ApiConfig ("model = 'duplicate'`n"+$initialConfig) $api 'https://x.example.com' 'x'} 'Duplicate managed keys rejected'
MustThrow {Merge-ApiConfig ($initialConfig+"`n[broken") $api 'https://x.example.com' 'x'} 'Unbalanced TOML rejected before writes'
MustThrow {Merge-ApiConfig ($initialConfig+"`n[model_providers.dual-api.auth]`ncommand='secret-helper'") $api 'https://x.example.com' 'x'} 'Conflicting provider auth rejected'
$inline="model_providers = { 'dual-api' = { base_url = 'https://x.example.com' } }"
MustThrow {Merge-ApiConfig $inline $api 'https://y.example.com' 'x'} 'Inline parent collision rejected'

$ccsSettings=Join-Path $root 'ccs-settings.json';$ccsExe=Join-Path $root 'cc-switch-fixture.exe'
Write-AtomicText $ccsExe 'not-executed'
Write-AtomicText $ccsSettings (@{codexConfigDir=$official}|ConvertTo-Json)
MustThrow {Test-CcsBinding $instance $ccsSettings $ccsExe} 'CCS pointing at official home rejected'
Write-AtomicText $ccsSettings (@{codexConfigDir=$instance.home}|ConvertTo-Json)
Check (Test-CcsBinding $instance $ccsSettings $ccsExe) 'CCS matching API home accepted'
# Resolve only this fixture as the CCS source; no real CCS data or process is touched.
function Get-CcsSettingsPath {return $ccsSettings}
Enable-CcsManagement $config $instance $ccsSettings $ccsExe
Check ((Get-ApiManagementMode $api) -eq 'ccs') 'CCS handoff records management ownership'
MustThrow {Save-ApiEnvironment $api $official 'https://x.example.com' 'x' $null} 'Legacy save cannot overwrite CCS-owned config'
MustThrow {Apply-ApiProfile $config $instance 'legacy'} 'Built-in switching disabled during CCS ownership'
MustThrow {New-CodexStartInfo -Executable 'unused.exe' -OfficialHome $official -ApiRoot $api -Api} 'CCS mode refuses old launcher placeholder credentials'
$ccsConfig=$initialConfig.Replace('dual-api','ccs-route').Replace('env_key = "CODEX_DUAL_API_KEY"','')
Write-AtomicText $configFile $ccsConfig
Write-AtomicText (Join-Path $instance.home 'auth.json') '{"auth_mode":"apikey","OPENAI_API_KEY":"fixture-ccs-key"}'
$probe=New-CodexStartInfo -Executable 'unused.exe' -OfficialHome $official -ApiRoot $api -Api
Check (-not $probe.EnvironmentVariables.ContainsKey('CODEX_DUAL_API_KEY') -and $probe.EnvironmentVariables['CODEX_HOME'] -eq $instance.home) 'CCS launch keeps isolated home without injecting stale DPAPI credential'
Write-AtomicText $ccsSettings (@{codexConfigDir=$official}|ConvertTo-Json)
MustThrow {New-CodexStartInfo -Executable 'unused.exe' -OfficialHome $official -ApiRoot $api -Api} 'CCS directory drift blocks launching before process creation'
Write-AtomicText $ccsSettings (@{codexConfigDir=$instance.home}|ConvertTo-Json)
Disable-CcsManagement $config $instance
Check ((Get-ApiManagementMode $api) -eq 'builtin' -and [IO.File]::ReadAllText($configFile) -eq $initialConfig) 'Return from CCS restores prior built-in config verbatim'
Check ([IO.File]::ReadAllText((Join-Path $api 'Credentials\api-key.dpapi')) -eq $oldKey) 'CCS return preserves original built-in credential'
Check ([IO.File]::ReadAllText((Join-Path $official 'auth.json')) -eq 'official-untouched') 'Official authentication untouched throughout all operations'
Check ((Get-FileHash $configPath).Hash -eq $configHash) 'All management actions preserve instance config and IDs'

& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "$PSScriptRoot\..\src\Controller.ps1" -ConfigPath $configPath -Action panel -SmokeTest -Preview api -ScreenshotPath "$root\api-manager.png"
Check ($LASTEXITCODE -eq 0 -and (Test-Path "$root\api-manager.png")) 'Real WinForms API manager renders with fixture channels'
Write-Output "PASSED: $passed experience checks. Output: $root"
