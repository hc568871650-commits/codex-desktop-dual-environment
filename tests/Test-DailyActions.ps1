$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
. "$PSScriptRoot\..\src\DailyActions.ps1"
$script:passed=0
function Check($Value,$Message){if(-not $Value){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
function MustThrow([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $Message}
$root=Join-Path ([IO.Path]::GetFullPath("$PSScriptRoot\..\test-results")) ('daily-'+[Guid]::NewGuid().ToString('N')+' space 中文')
$config=[pscustomobject]@{instances=@([pscustomobject]@{role='api'},[pscustomobject]@{role='official'})}
$calls=New-Object 'Collections.Generic.List[string]'
$result=@(Invoke-DualOpen $config {param($i) $calls.Add($i.role);if($i.role -eq 'official'){throw 'fixture failure'};'Shown'})
Check (($calls -join ',') -eq 'official,api') 'Both roles attempted in stable order even when first fails'
Check ($result.Count -eq 2 -and $result[0].Outcome -eq 'Failed' -and $result[1].Outcome -eq 'Shown') 'Partial success remains explicit'
Check ($result[0].Error -eq 'fixture failure') 'Original failure preserved for local feedback'
$result=@(Invoke-DualOpen $config {param($i) if($i.role -eq 'official'){'Cancelled'}else{'Running'}})
Check ($result[0].Outcome -eq 'Cancelled' -and $result[1].Outcome -eq 'Running') 'Cancelled selection and foreground refusal are not reported as shown'
$result=@(Invoke-DualOpen $config {param($i) if($i.role -eq 'api'){throw 'api failure'};'Shown'})
Check ($result[0].Outcome -eq 'Shown' -and $result[1].Outcome -eq 'Failed') 'Second failure does not erase first success'
$result=@(Invoke-DualOpen $config {param($i) $null})
Check (@($result|Where-Object {$_.Outcome -eq 'Failed'}).Count -eq 2) 'Unconfirmed callback outcomes fail closed'
$instance=[pscustomobject]@{home=(Join-Path $root 'Home');projects=(Join-Path $root 'Projects');projectless=(Join-Path $root 'Projectless')}
foreach($path in @($instance.home,$instance.projects,$instance.projectless)){[void][IO.Directory]::CreateDirectory($path)}
$toml="[desktop]`r`nprojectlessWorkspaceRoot = '"+$instance.projectless+"'`r`n"
Write-AtomicText (Join-Path $instance.home 'config.toml') $toml
foreach($kind in @('home','projects','projectless')){Check ((Get-InstanceDirectoryPath $instance $kind) -eq $instance.$kind) ('Resolves existing '+$kind+' with spaces and Chinese path')}
$instance.projectless=''
Check ((Get-InstanceDirectoryPath $instance 'projectless') -eq (Join-Path $root 'Projectless')) 'Inherited official workspace resolves actual config'
$instance.projectless=Join-Path $root 'Stale'
MustThrow {Get-InstanceDirectoryPath $instance 'projectless'} 'Stale workspace is rejected instead of opening a wrong directory'
$instance.projects=Join-Path $root 'Missing'
MustThrow {Get-InstanceDirectoryPath $instance 'projects'} 'Missing directory fails without creating it'
Check (-not (Test-Path -LiteralPath $instance.projects)) 'Folder actions do not create data directories'
MustThrow {Get-InstanceDirectoryPath $instance 'profile'} 'Unsupported folder kind refused'
$instance.projectless='';Write-AtomicText (Join-Path $instance.home 'config.toml') '[desktop]'
MustThrow {Get-InstanceDirectoryPath $instance 'projectless'} 'Invalid inherited workspace fails without guessing'
Write-Output "PASSED: $script:passed daily-action checks. Output: $root"
