param([string]$OutputDirectory=(Join-Path $PSScriptRoot '..\..\..\test-results'))
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\AdaptiveBridge.ps1"
$testRoot=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('adaptive-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:passed=0;$script:runs=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:passed++;Write-Output ('PASS: '+$Message)}
function Throws([scriptblock]$Action,[string]$Message){$threw=$false;try{& $Action|Out-Null}catch{$threw=$true};Assert $threw $Message}
foreach($name in @('Desktop.exe','codex.exe','BridgeProxy.exe','fixture.ps1')){[IO.File]::WriteAllText((Join-Path $testRoot $name),$name)}
$instance=[pscustomobject]@{role='api';id=('a'*32);home=(Join-Path $testRoot 'home');profile=(Join-Path $testRoot 'profile')}
$desktop=Join-Path $testRoot 'Desktop.exe';$cli=Join-Path $testRoot 'codex.exe';$proxy=Join-Path $testRoot 'BridgeProxy.exe';$fixture=Join-Path $testRoot 'fixture.ps1'
$runtime=[pscustomobject]@{desktopExe=$desktop;realCli=$cli;instanceId=$instance.id;apiHome=$instance.home;profile=$instance.profile}
$runner={param($c,$p,$o) $script:runs++;Write-AdaptiveJson (Join-Path $o 'report.json') @{schema=1;success=$true;suiteVersion='adaptive-protocol-v1';cliHash=(Get-AdaptiveHash $c);proxyHash=(Get-AdaptiveHash $p);checks=@(@{name='sync';success=$true},@{name='async';success=$true},@{name='multiconnection';success=$true})}}
$root=Join-Path $testRoot 'ready'
$argsBase=@{Root=$root;Instance=$instance;Runtime=$runtime;ProxyPath=$proxy;CompatibilityScript=$fixture;CompatibilityRunner=$runner}
$first=Invoke-AdaptiveBridgeUpdate @argsBase
Assert ($first.state -eq 'waiting_restart') 'Successful fixture prepares a pending binding'
Assert ($script:runs -eq 1) 'Exactly one fixture execution'
$valid=Get-ApiQuestionBridgeValidation -Directory $first.candidateDirectory -ApiHome $instance.home -Profile $instance.profile -DesktopExecutable $desktop -InstanceId $instance.id
Assert $valid.valid 'Prepared binding passes production validator'
Assert ($valid.binding.config.multiConnection -eq $true) 'Multi connection enabled'
Assert ($null -ne (Test-AdaptiveBridgeCandidate -Root $root -Instance $instance -CandidateDirectory $first.candidateDirectory -DesktopExecutable $desktop)) 'Promotion validator accepts complete evidence'
$second=Invoke-AdaptiveBridgeUpdate @argsBase
Assert ($script:runs -eq 1 -and $second.candidateDirectory -eq $first.candidateDirectory) 'Hash cache avoids repeated fixture'
Assert (-not (Test-Path -LiteralPath (Join-Path $root 'binding.json'))) 'Preparation never promotes active binding'
Assert (Test-Path -LiteralPath (Join-Path $root 'state\status.json')) 'Status lives at shared contract path'
$cachePath=Join-Path (Join-Path $root 'cache') ($first.fingerprint+'.json')
[IO.File]::WriteAllText($cachePath,'{bad')
$third=Invoke-AdaptiveBridgeUpdate @argsBase
Assert ($script:runs -eq 2 -and $third.state -eq 'waiting_restart') 'Corrupt cache reruns compatibility safely'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'cache') -Filter '*.invalid.*').Count -eq 1) 'Corrupt cache preserved for diagnosis'
[IO.File]::AppendAllText($cli,'changed')
$fourth=Invoke-AdaptiveBridgeUpdate @argsBase
Assert ($script:runs -eq 3 -and $fourth.fingerprint -ne $third.fingerprint) 'Changed runtime invalidates cache'
Assert ($null -eq (Test-AdaptiveBridgeCandidate -Root $root -Instance $instance -CandidateDirectory $third.candidateDirectory -DesktopExecutable $desktop)) 'Old candidate rejected after CLI upgrade'
$other=[pscustomobject]@{role='api';id=('b'*32);home=(Join-Path $testRoot 'otherhome');profile=(Join-Path $testRoot 'otherprofile')}
Assert ($null -eq (Test-AdaptiveBridgeCandidate -Root $root -Instance $other -CandidateDirectory $fourth.candidateDirectory -DesktopExecutable $desktop)) 'Cross instance candidate rejected'
$bad=Invoke-AdaptiveBridgeUpdate -Root (Join-Path $testRoot 'cross') -Instance $other -Runtime $runtime -ProxyPath $proxy -CompatibilityScript $fixture -CompatibilityRunner $runner
Assert ($bad.state -eq 'needs_adaptation' -and $script:runs -eq 3) 'Cross instance runtime never invokes fixture'
[IO.File]::WriteAllText((Join-Path $root 'DISABLED'),'user disabled')
$disabled=Invoke-AdaptiveBridgeUpdate @argsBase
Assert ($disabled.state -eq 'disabled' -and $script:runs -eq 3) 'Manual disable preserved'
Assert ($null -eq (Test-AdaptiveBridgeCandidate -Root $root -Instance $instance -CandidateDirectory $fourth.candidateDirectory -DesktopExecutable $desktop)) 'Disabled root cannot promote'
$failRoot=Join-Path $testRoot 'failed'
$failRunner={param($c,$p,$o) $script:runs++;throw 'fixture protocol rejected'}
$fail1=Invoke-AdaptiveBridgeUpdate -Root $failRoot -Instance $instance -Runtime $runtime -ProxyPath $proxy -CompatibilityScript $fixture -CompatibilityRunner $failRunner
$fail2=Invoke-AdaptiveBridgeUpdate -Root $failRoot -Instance $instance -Runtime $runtime -ProxyPath $proxy -CompatibilityScript $fixture -CompatibilityRunner $failRunner
Assert ($fail1.state -eq 'needs_adaptation' -and $fail2.reason -eq 'COMPATIBILITY_FAILED_COOLDOWN' -and $script:runs -eq 4) 'Failed fingerprint has bounded cooldown'
$unknownRunner={param($c,$p,$o) $script:runs++;Write-AdaptiveJson (Join-Path $o 'report.json') @{schema=99;success=$true;cliHash=(Get-AdaptiveHash $c);proxyHash=(Get-AdaptiveHash $p)}}
$unknown=Invoke-AdaptiveBridgeUpdate -Root (Join-Path $testRoot 'unknown') -Instance $instance -Runtime $runtime -ProxyPath $proxy -CompatibilityScript $fixture -CompatibilityRunner $unknownRunner
Assert ($unknown.state -eq 'needs_adaptation' -and -not $unknown.candidateDirectory) 'Unknown report schema fails closed'
$missingRunner={param($c,$p,$o) Write-AdaptiveJson (Join-Path $o 'report.json') @{schema=1;success=$true;suiteVersion='adaptive-protocol-v1';cliHash=(Get-AdaptiveHash $c);proxyHash=(Get-AdaptiveHash $p);checks=@(@{name='sync';success=$true})}}
$missing=Invoke-AdaptiveBridgeUpdate -Root (Join-Path $testRoot 'missingchecks') -Instance $instance -Runtime $runtime -ProxyPath $proxy -CompatibilityScript $fixture -CompatibilityRunner $missingRunner
Assert ($missing.state -eq 'needs_adaptation') 'Success flag cannot replace required protocol checks'
$changeRunner={param($c,$p,$o) & $runner $c $p $o;[IO.File]::AppendAllText($c,'during')}
$changed=Invoke-AdaptiveBridgeUpdate -Root (Join-Path $testRoot 'changed') -Instance $instance -Runtime $runtime -ProxyPath $proxy -CompatibilityScript $fixture -CompatibilityRunner $changeRunner
Assert ($changed.state -eq 'needs_adaptation' -and -not $changed.candidateDirectory) 'Runtime changed during fixture cannot produce binding'
$snap=@([pscustomobject]@{Id=100;ParentId=0;Path=$desktop;Name='Desktop.exe';Started='1000';Command=('"'+$desktop+'" --user-data-dir="'+$instance.profile+'"')},[pscustomobject]@{Id=101;ParentId=100;Path=$cli;Name='codex.exe';Started='1100';Command=('"'+$cli+'" app-server')})
$reader={param($n) $instance.home}
$found=Get-AdaptiveBridgeRuntime -Instance $instance -Snapshot $snap -DesktopExecutable $desktop -HomeReader $reader
Assert ($found.cliProcess.Id -eq 101) 'Direct child app server discovered from verified API desktop'
$snap[1].ParentId=999
Throws {Get-AdaptiveBridgeRuntime -Instance $instance -Snapshot $snap -DesktopExecutable $desktop -HomeReader $reader} 'Arbitrary descendants rejected'
$snap[1].ParentId=100
$badReader={param($n) if($n -eq 100){$instance.home}else{$other.home}}
Throws {Get-AdaptiveBridgeRuntime -Instance $instance -Snapshot $snap -DesktopExecutable $desktop -HomeReader $badReader} 'CLI wrong home rejected'
$duplicate=@($snap)+@([pscustomobject]@{Id=102;ParentId=100;Path=$cli;Name='codex.exe';Started='1200';Command=('"'+$cli+'" app-server')})
Throws {Get-AdaptiveBridgeRuntime -Instance $instance -Snapshot $duplicate -DesktopExecutable $desktop -HomeReader $reader} 'Multiple direct CLI processes rejected'
$activeRoot=Join-Path $testRoot 'active'
$active=Invoke-AdaptiveBridgeUpdate -Root $activeRoot -Instance $instance -Runtime $runtime -ProxyPath $proxy -CompatibilityScript $fixture -CompatibilityRunner $runner
$activeBinding=Test-AdaptiveBridgeCandidate -Root $activeRoot -Instance $instance -CandidateDirectory $active.candidateDirectory -DesktopExecutable $desktop -ProxyPath $proxy -CompatibilityScript $fixture
$bridgeSnap=@($snap[0],[pscustomobject]@{Id=103;ParentId=100;Path=$activeBinding.proxy;Name='BridgeProxy.exe';Started='1050';Command=('"'+$activeBinding.proxy+'" app-server')},[pscustomobject]@{Id=104;ParentId=103;Path=$cli;Name='codex.exe';Started='1100';Command=('"'+$cli+'" app-server')})
$observed=Get-AdaptiveBridgeRuntime -Instance $instance -Snapshot $bridgeSnap -DesktopExecutable $desktop -HomeReader $reader -ValidatedBinding $activeBinding
Assert ($observed.cliProcess.Id -eq 104 -and $observed.bridgeProcess.Id -eq 103) 'Validated direct bridge to direct CLI chain accepted'
$normal=Invoke-AdaptiveBridgeUpdate -Root $activeRoot -Instance $instance -Runtime $observed -ProxyPath $proxy -CompatibilityScript $fixture -CompatibilityRunner $runner
Assert ($normal.state -eq 'normal' -and $normal.reason -eq 'BOUND_NOT_CONNECTED') 'Existing running bound bridge not reported as freshly promoted or connected'
[IO.File]::AppendAllText((Join-Path $active.candidateDirectory 'report.json'),' ')
Assert ($null -eq (Test-AdaptiveBridgeCandidate -Root $activeRoot -Instance $instance -CandidateDirectory $active.candidateDirectory -DesktopExecutable $desktop -ProxyPath $proxy -CompatibilityScript $fixture)) 'Tampered report rejected even when JSON still valid'
$repaired=Invoke-AdaptiveBridgeUpdate -Root $activeRoot -Instance $instance -Runtime $runtime -ProxyPath $proxy -CompatibilityScript $fixture -CompatibilityRunner $runner
Assert ($repaired.state -eq 'waiting_restart' -and $repaired.candidateDirectory -ne $active.candidateDirectory) 'Corrupt immutable candidate preserved and replaced by a new candidate'
[IO.File]::AppendAllText($fixture,'new suite')
Assert ($null -eq (Test-AdaptiveBridgeCandidate -Root $activeRoot -Instance $instance -CandidateDirectory $repaired.candidateDirectory -DesktopExecutable $desktop -ProxyPath $proxy -CompatibilityScript $fixture)) 'Changed compatibility suite invalidates promotion evidence'
$disableRoot=Join-Path $testRoot 'disable-during'
$disableRunner={param($c,$p,$o) & $runner $c $p $o;[IO.File]::WriteAllText((Join-Path $disableRoot 'DISABLED'),'disabled during validation')}
$during=Invoke-AdaptiveBridgeUpdate -Root $disableRoot -Instance $instance -Runtime $runtime -ProxyPath $proxy -CompatibilityScript $fixture -CompatibilityRunner $disableRunner
Assert ($during.state -eq 'disabled' -and -not $during.candidateDirectory) 'Manual disable during validation prevents candidate publication'
Write-AdaptiveJson (Join-Path $testRoot 'summary.json') @{passed=$script:passed;testRoot=$testRoot}
Write-Output ('Adaptive bridge checks passed: '+$script:passed+'; '+$testRoot)
