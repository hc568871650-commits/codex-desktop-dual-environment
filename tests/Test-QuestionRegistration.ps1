param([string]$OutputDirectory=(Join-Path $PSScriptRoot '..\test-results'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$source=Join-Path $PSScriptRoot '..\src\PendingQuestions.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Source parse failed'}
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-QuestionBridgeRegistration'},$true)
if(-not $function){throw 'Registration function missing'}
Invoke-Expression $function.Extent.Text
$testRoot=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('question-registration-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$config=[pscustomobject]@{stateDirectory=$testRoot;instances=@([pscustomobject]@{role='api';id=('a'*32)})}
$script:passed=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:passed++;Write-Output ('PASS: '+$Message)}
function Assert-NoReparsePoint([string]$Path){if($script:rejectPath){throw 'path unsafe'}}
function Test-SamePath([string]$A,[string]$B){return $A -and $B -and $A.Equals($B,[StringComparison]::OrdinalIgnoreCase)}
function Get-ProcessSnapshot {if($script:rejectSnapshot){throw 'unreadable snapshot'};return $script:snapshot}
function Read-QuestionBridgeBinding([string]$Directory){if($script:rejectCandidate){throw 'candidate invalid'};return [pscustomobject]@{directory=$Directory;instance=[pscustomobject]@{id=$script:candidateId};disabled=$script:disabledPath}}
function Connect-QuestionBridge([string]$Directory){$script:connects++;$script:connectedDirectory=$Directory}
function Reset-State {
    $script:questionRegistrationPollAt=[DateTime]::MinValue;$script:questionPending=@();$script:questionReturnTarget=$null
    $script:questionClient=[pscustomobject]@{Busy=$false;HasPendingResults=$false}
    $script:questionWindow=$null;$script:questionBinding=[pscustomobject]@{directory='C:\old';proxy='C:\old\BridgeProxy.exe'}
    $script:snapshot=@();$script:rejectPath=$false;$script:rejectSnapshot=$false;$script:rejectCandidate=$false
    $script:candidateId='a'*32;$script:disabledPath=Join-Path $testRoot ([Guid]::NewGuid().ToString('N')+'.disabled')
    $script:connects=0;$script:connectedDirectory=''
    [IO.File]::WriteAllText((Join-Path $testRoot 'question-bridge.local.json'),(@{schema=1;instanceId=('a'*32);directory='C:\new'}|ConvertTo-Json))
}
function Check-Blocked([string]$Name){Update-QuestionBridgeRegistration;Assert ($script:connects -eq 0) $Name}
Reset-State
Update-QuestionBridgeRegistration
Assert ($script:connects -eq 1 -and $script:connectedDirectory -eq 'C:\new') 'Valid idle new registration refreshes once'
Update-QuestionBridgeRegistration
Assert ($script:connects -eq 1) 'Five-second poll gate avoids per-tick reconnect'
Reset-State;$script:questionClient.Busy=$true;Check-Blocked 'Busy answer submission blocks refresh'
Reset-State;$script:questionClient.HasPendingResults=$true;Check-Blocked 'Queued result blocks refresh'
Reset-State;$script:questionPending=@([pscustomobject]@{requestToken='pending'});Check-Blocked 'Pending question blocks refresh'
Reset-State;$script:questionReturnTarget=[pscustomobject]@{requestToken='return'};Check-Blocked 'Native ownership handoff blocks refresh'
Reset-State;$script:questionWindow=[pscustomobject]@{IsDisposed=$false;Visible=$true;RequestToken='draft';HasUnresolvedDraft=$true;IsRequestValid=$true};Check-Blocked 'Visible draft blocks refresh'
Reset-State;$script:snapshot=@([pscustomobject]@{Path='C:\old\BridgeProxy.exe'});Check-Blocked 'Old proxy process blocks refresh'
Reset-State;$script:rejectSnapshot=$true;Check-Blocked 'Unreadable old process ownership blocks refresh'
Reset-State;$script:questionBinding.directory='C:\new';Check-Blocked 'Identical registration avoids reconnect'
Reset-State;$script:rejectCandidate=$true;Check-Blocked 'Invalid candidate preserves old connection'
Reset-State;$script:candidateId='b'*32;Check-Blocked 'Cross instance candidate blocks refresh'
Reset-State;[IO.File]::WriteAllText($script:disabledPath,'disabled');Check-Blocked 'Disabled candidate blocks refresh'
Reset-State;[IO.File]::WriteAllText((Join-Path $testRoot 'question-bridge.local.json'),'{bad');Check-Blocked 'Partial registration JSON blocks refresh'
Reset-State;[IO.File]::WriteAllText((Join-Path $testRoot 'question-bridge.local.json'),(@{schema=99;instanceId=('a'*32);directory='C:\new'}|ConvertTo-Json));Check-Blocked 'Unknown registration schema blocks refresh'
Reset-State;[IO.File]::WriteAllText((Join-Path $testRoot 'question-bridge.local.json'),(@{schema=1;instanceId=('b'*32);directory='C:\new'}|ConvertTo-Json));Check-Blocked 'Wrong registration instance blocks refresh'
Reset-State;$script:rejectPath=$true;Check-Blocked 'Unsafe registration path blocks refresh'
Reset-State;[IO.File]::WriteAllText((Join-Path $testRoot 'question-bridge.local.json'),('x'*9000));Check-Blocked 'Oversized registration blocks refresh'
Reset-State;$script:questionWindow=[pscustomobject]@{IsDisposed=$false;Visible=$false;RequestToken='hidden-draft';HasUnresolvedDraft=$true;IsRequestValid=$false};Check-Blocked 'Hidden unresolved draft blocks refresh after disconnect'
Reset-State;$script:questionWindow=[pscustomobject]@{IsDisposed=$false;Visible=$false;RequestToken='resolved-token';HasUnresolvedDraft=$false;IsRequestValid=$false};Update-QuestionBridgeRegistration;Assert ($script:connects -eq 1) 'Confirmed resolved hidden window permits registration refresh'
Reset-State;$script:questionWindow=[pscustomobject]@{IsDisposed=$true;Visible=$false;RequestToken='disposed-token';HasUnresolvedDraft=$true;IsRequestValid=$false};Update-QuestionBridgeRegistration;Assert ($script:connects -eq 1) 'Disposed window does not permanently block refresh'
[IO.File]::WriteAllText((Join-Path $testRoot 'summary.json'),(@{passed=$script:passed;testRoot=$testRoot}|ConvertTo-Json))
Write-Output ('Question registration checks passed: '+$script:passed+'; '+$testRoot)
