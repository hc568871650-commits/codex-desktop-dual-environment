$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Upgrade.ps1"
$source=[IO.Path]::GetFullPath("$PSScriptRoot\..")
$root=Join-Path $source ('test-results\upgrade-'+[Guid]::NewGuid().ToString('N')+' space 中文')
$official=Join-Path $root 'OfficialHome';$officialTasks=Join-Path $root 'OfficialTasks';$api=Join-Path $root 'API'
foreach($path in @($official,$officialTasks)){[void][IO.Directory]::CreateDirectory($path)}
Write-AtomicText (Join-Path $official 'config.toml') ("# Preserve custom official config`r`n[desktop]`r`nprojectlessWorkspaceRoot = "+(ConvertTo-TomlString $officialTasks))
Write-AtomicText (Join-Path $official 'auth.json') 'official-auth-sentinel'
$key=ConvertTo-SecureString 'fake-upgrade-credential' -AsPlainText -Force
try{[void](Save-ApiEnvironment $api $official 'https://example.com/v1' 'fake-model' $key)}finally{$key.Dispose()}
Write-AtomicText (Join-Path $api 'DesktopProfile\keep.dat') 'profile-sentinel'
Write-AtomicText (Join-Path $api 'CodexHome\keep-user-data.txt') 'history-sentinel'
$settings=Join-Path $root 'settings.json'
Write-AtomicText $settings (@{root=$api;officialHome=$official;executable="$env:SystemRoot\System32\notepad.exe";baseUrl='https://example.com/v1';model='fake-model'}|ConvertTo-Json)
$protected=@($settings,(Join-Path $official 'config.toml'),(Join-Path $official 'auth.json'),(Join-Path $api 'CodexHome\config.toml'),(Join-Path $api 'CodexHome\auth.json'),(Join-Path $api 'Credentials\api-key.dpapi'),(Join-Path $api 'DesktopProfile\keep.dat'),(Join-Path $api 'CodexHome\keep-user-data.txt'))
$hashes=@{};foreach($p in $protected){$hashes[$p]=(Get-FileHash -LiteralPath $p).Hash}
$script:passed=0
function Check($Value,$Message){if(-not $Value){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
function MustThrow([scriptblock]$Code,$Message){$thrown=$false;try{& $Code|Out-Null}catch{$thrown=$true};Check $thrown $Message}
function New-OldTool([string]$Name){$target=Join-Path $root $Name;[void][IO.Directory]::CreateDirectory((Join-Path $target 'src'));Write-AtomicText (Join-Path $target 'Start.cmd') '@echo old-launcher';Write-AtomicText (Join-Path $target 'src\Core.ps1') '# old-core';Write-AtomicText (Join-Path $target 'src\Launcher.ps1') '# old-gui';Write-AtomicText (Join-Path $target 'custom.txt') 'keep-custom';return $target}
$old=New-OldTool 'LegacyTool'
$oldStart=(Get-FileHash -LiteralPath (Join-Path $old 'Start.cmd')).Hash
$plan=Invoke-ControllerUpgrade $source $old $settings -CheckOnly
Check ($plan.Status -eq 'Ready' -and $plan.MigrateLegacy) 'Legacy upgrade recognized without writes'
Check (-not (Test-Path -LiteralPath (Join-Path $old 'upgrades'))) 'Check-only creates no backup or files'
$upgrade=Invoke-ControllerUpgrade $source $old $settings
Check ($upgrade.Status -eq 'Upgraded') '0.1 tool upgraded in existing directory'
$config=Read-ControllerConfig (Join-Path $old 'instances.local.json')
Check ($config.instances[1].home -eq (Join-Path $api 'CodexHome')) 'Existing API home reused'
Check ($config.instances[1].apiRoot -eq $api) 'Existing encrypted credential location reused'
Check ($config.instances[0].home -eq $official -and -not $config.instances[0].profile) 'Official home and default profile retained'
Check (Test-Path -LiteralPath (Join-Path $old 'CodexDualController.exe')) 'Taskbar host compiled at stable target path'
Check ((Get-Content -LiteralPath (Join-Path $old 'custom.txt') -Raw) -eq 'keep-custom') 'Unrelated user file retained'
foreach($p in $protected){Check ((Get-FileHash -LiteralPath $p).Hash -eq $hashes[$p]) ('Protected fixture unchanged: '+[IO.Path]::GetFileName($p))}
$configBytes=(Get-FileHash -LiteralPath (Join-Path $old 'instances.local.json')).Hash
$repeat=Invoke-ControllerUpgrade $source $old $settings
Check ($repeat.Status -eq 'AlreadyCurrent') 'Repeated upgrade is idempotent'
Check ((Get-FileHash -LiteralPath (Join-Path $old 'instances.local.json')).Hash -eq $configBytes) 'Stable instance IDs and local configuration preserved'
# A current 0.2 configuration must survive repairs exactly, including custom settings.
$config|Add-Member NoteProperty customSetting 'preserve-me';Write-AtomicText (Join-Path $old 'instances.local.json') ($config|ConvertTo-Json -Depth 8)
$customHash=(Get-FileHash -LiteralPath (Join-Path $old 'instances.local.json')).Hash
Write-AtomicText (Join-Path $old 'src\Core.ps1') '# modified-old-tool'
$repair=Invoke-ControllerUpgrade $source $old $settings
Check ((Get-FileHash -LiteralPath (Join-Path $old 'instances.local.json')).Hash -eq $customHash) '0.2 repair preserves existing configuration byte for byte'
Undo-ControllerUpgrade $repair.Snapshot | Out-Null
Check ((Get-Content -LiteralPath (Join-Path $old 'src\Core.ps1') -Raw) -eq '# modified-old-tool') 'Repair rollback restores prior customized tool'
MustThrow {Undo-ControllerUpgrade $upgrade.Snapshot} 'Rollback refuses post-upgrade user modifications'
$rollbackTarget=New-OldTool 'RollbackTool'
$rollback=Invoke-ControllerUpgrade $source $rollbackTarget $settings
Undo-ControllerUpgrade $rollback.Snapshot | Out-Null
Check ((Get-FileHash -LiteralPath (Join-Path $rollbackTarget 'Start.cmd')).Hash -eq $oldStart) 'Full upgrade rollback restores 0.1 entry'
Check (-not (Test-Path -LiteralPath (Join-Path $rollbackTarget 'instances.local.json'))) 'Rollback removes only newly generated controller config'
foreach($p in $protected){if((Get-FileHash -LiteralPath $p).Hash -ne $hashes[$p]){throw 'Rollback changed user data'}}
Check $true 'Rollback preserves all environment data and credentials'
$overlay=New-OldTool 'OverlayTool'
foreach($relative in @(Get-UpgradePayload $source)){$target=Join-Path $overlay $relative;[void][IO.Directory]::CreateDirectory((Split-Path $target -Parent));[IO.File]::Copy((Join-Path $source $relative),$target,$true)}
$overlayResult=Invoke-ControllerUpgrade $overlay $overlay $settings
Check ($overlayResult.InPlace -and $overlayResult.Status -eq 'Upgraded') 'Direct extraction overlay supports in-place completion'
Check ((Invoke-ControllerUpgrade $overlay $overlay $settings).Status -eq 'AlreadyCurrent') 'Overlay completion does not repeat on next start'
$bad=New-OldTool 'InvalidTool'
MustThrow {Invoke-ControllerUpgrade $source $bad (Join-Path $root 'missing.json')} 'Missing old settings refused without guessing'
Check ((Get-Content -LiteralPath (Join-Path $bad 'Start.cmd') -Raw) -eq '@echo old-launcher') 'Invalid upgrade leaves old tool untouched'
MustThrow {Get-UpgradeFilePath $old '..\escape.txt'} 'Upgrade path escape rejected'
$readonly=New-OldTool 'ReadOnlyTool';$readonlyStart=Join-Path $readonly 'Start.cmd';(Get-Item -LiteralPath $readonlyStart).IsReadOnly=$true
try{MustThrow {Invoke-ControllerUpgrade $source $readonly $settings} 'Read-only tool file blocks upgrade before replacement'}finally{(Get-Item -LiteralPath $readonlyStart).IsReadOnly=$false}
Check ((Get-FileHash -LiteralPath $readonlyStart).Hash -eq $oldStart -and -not (Test-Path -LiteralPath (Join-Path $readonly 'instances.local.json'))) 'Preflight failure preserves old entry and does not create config'
$defaultOfficial=Join-Path $root 'DefaultOfficial';[void][IO.Directory]::CreateDirectory($defaultOfficial)
Write-AtomicText (Join-Path $defaultOfficial 'config.toml') '# Native defaults: no desktop section'
$defaultSettings=Join-Path $root 'default-settings.json';$defaultData=Get-Content -LiteralPath $settings -Raw -Encoding UTF8|ConvertFrom-Json;$defaultData.officialHome=$defaultOfficial;Write-AtomicText $defaultSettings ($defaultData|ConvertTo-Json)
$defaultTarget=New-OldTool 'DefaultOfficialTool';$defaultUpgrade=Invoke-ControllerUpgrade $source $defaultTarget $defaultSettings
$defaultConfig=Read-ControllerConfig (Join-Path $defaultTarget 'instances.local.json')
Check ($defaultConfig.instances[0].projectlessMode -eq 'inherit' -and -not $defaultConfig.instances[0].projectless) '0.1 official default task directory preserved without guessing'
Check ((Get-Content -LiteralPath (Join-Path $defaultOfficial 'config.toml') -Raw) -eq '# Native defaults: no desktop section') 'Official default configuration never rewritten for migration'
if($env:CODEX_DUAL_LEGACY_TEST_ARCHIVE){
    $realTarget=Join-Path $root 'ActualRelease01'
    Expand-Archive -LiteralPath $env:CODEX_DUAL_LEGACY_TEST_ARCHIVE -DestinationPath $realTarget
    $realUpgrade=Invoke-ControllerUpgrade $source $realTarget $settings
    Check ($realUpgrade.Status -eq 'Upgraded') 'Actual 0.1 release ZIP upgrades successfully'
    foreach($p in $protected){if((Get-FileHash -LiteralPath $p).Hash -ne $hashes[$p]){throw 'Real archive upgrade changed fixture data'}}
    Check $true 'Actual archive upgrade preserves configuration and credential fixtures'
}
Write-Output "PASSED: $script:passed upgrade checks"
