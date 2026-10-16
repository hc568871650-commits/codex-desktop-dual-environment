[CmdletBinding()]
param([Parameter(Mandatory)][string]$Installation,[switch]$Apply)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$rollbackApply=$Apply
. (Join-Path $PSScriptRoot 'Install-AdaptiveBridge.ps1') -FunctionsOnly
Assert-AbiPlainPath $Installation
$plan=[IO.File]::ReadAllText((Join-Path $Installation 'install-plan.json'))|ConvertFrom-Json
if($plan.schema -ne 1 -or -not(Test-AbiPath $plan.destination $Installation)){throw 'ADAPTIVE_ROLLBACK_PLAN_INVALID'}
if((Get-AbiHash $plan.backupPath) -ne $plan.originalHash){throw 'ADAPTIVE_ROLLBACK_BACKUP_CHANGED'}
$current=[IO.File]::ReadAllText($plan.launcher);$hash=Get-AbiHash $plan.launcher
$newline=if($current.Contains("`r`n")){"`r`n"}else{"`n"}
$nativeSafety='        # ADAPTIVE ROLLBACK NATIVE SAFETY: do not reactivate an obsolete bridge binding.'+$newline+'        Remove-Item Env:\CODEX_CLI_PATH -ErrorAction SilentlyContinue'+$newline
$questionRestored=[string]$plan.questionBefore+$nativeSafety
if($current.Contains([string]$plan.questionAfter)) {
    foreach($block in @($plan.questionAfter,$plan.observerAfter)){if($current.Split(@([string]$block),[StringSplitOptions]::None).Length -ne 2){throw 'ADAPTIVE_ROLLBACK_BLOCK_DRIFTED'}}
    $replacement=$current.Replace([string]$plan.questionAfter,$questionRestored).Replace([string]$plan.observerAfter,[string]$plan.observerBefore)
}elseif($current.Contains($questionRestored) -and -not $current.Contains('# BEGIN CODEX ADAPTIVE OBSERVER')){
    $replacement=$current
}elseif($hash -eq $plan.originalHash){$replacement=$current.Replace([string]$plan.questionBefore,$questionRestored)}else{throw 'ADAPTIVE_ROLLBACK_BLOCK_MISSING'}
Assert-AbiSyntax $replacement
if(-not $rollbackApply){[pscustomobject]@{state='rollback-ready';preservesUnrelatedChanges=$true;restartsDesktop=$false};return}
# Do not stop an active bridge, restore a stale registration, or overwrite a newer
# controller binding. Disabling new launches and restoring only our two blocks
# leaves existing pending questions and title integration undisturbed.
[IO.File]::WriteAllText((Join-Path $Installation 'DISABLED'),'Disabled by explicit rollback.')
$backup=Join-Path $Installation ('launcher.before-rollback-'+[Guid]::NewGuid().ToString('N')+'.ps1')
[IO.File]::Copy($plan.launcher,$backup,$false)
if($replacement -cne $current){Write-AbiLauncherReplacement $plan.launcher $replacement $hash}
$registration=Join-Path $plan.stateDirectory 'adaptive-bridge.local.json'
if(Test-Path -LiteralPath $registration){Assert-AbiPlainPath $registration;$saved=[IO.File]::ReadAllText($registration)|ConvertFrom-Json;if($saved.schema -eq 1 -and (Test-AbiPath $saved.root $Installation)){$saved.enabled=$false;Write-AbiJson $registration $saved}}
[pscustomobject]@{state='rolled-back';backup=$backup;desktopRestarted=$false;questionBindingPreserved=$true;note='Existing bridge remains owned until normal exit. Future launches explicitly use native CLI; title integration is preserved.'}
