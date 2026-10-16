[CmdletBinding()]
param([Parameter(Mandatory)][string]$Installation, [switch]$Apply)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'TitleIntegrationLaunch.ps1')
$planPath=Join-Path $Installation 'install-plan.json'
Assert-TitleRegularPath $planPath
$plan=Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($plan.schema -ne 1 -or -not (Test-TitlePath $plan.destination $Installation)) { throw 'title-rollback-plan-mismatch' }
Assert-TitleRegularPath $plan.launcher
if ((Get-TitleSha256 $plan.backupPath) -ne $plan.originalHash) { throw 'title-rollback-backup-changed' }
$currentHash=Get-TitleSha256 $plan.launcher
$current=[IO.File]::ReadAllText($plan.launcher)
if ($currentHash -eq $plan.originalHash) {
    if ($Apply) { [IO.File]::WriteAllText((Join-Path $Installation 'DISABLED'),'Disabled by rollback.') }
    [pscustomobject]@{state='already-original';changed=$false}; return
}
# Remove exactly our reviewed block; preserve unrelated launcher edits made after installation.
if (($current.Split(@([string]$plan.after),[StringSplitOptions]::None)).Length -ne 2) { throw 'title-rollback-block-drifted' }
$replacement=$current.Replace([string]$plan.after,[string]$plan.before)
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseInput($replacement,[ref]$tokens,[ref]$errors)
if (@($errors).Count) { throw 'title-rollback-syntax-invalid' }
if (-not $Apply) { [pscustomobject]@{state='rollback-ready';launcher=$plan.launcher;preservesUnrelatedChanges=($currentHash -ne $plan.stagedHash)}; return }
[IO.File]::WriteAllText((Join-Path $Installation 'DISABLED'),'Disabled by rollback.')
$rollbackBackup=Join-Path $Installation ('launcher.before-rollback-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.ps1')
[IO.File]::Copy($plan.launcher,$rollbackBackup,$false)
$temp=$plan.launcher+'.title-rollback-'+[Guid]::NewGuid().ToString('N')+'.tmp'
try {
    if ($currentHash -eq $plan.stagedHash) { [IO.File]::Copy($plan.backupPath,$temp,$false) }
    else {
        $bytes=[IO.File]::ReadAllBytes($plan.launcher)
        $hasBom=$bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
        [IO.File]::WriteAllText($temp,$replacement,(New-Object Text.UTF8Encoding($hasBom)))
    }
    if ((Get-TitleSha256 $plan.launcher) -ne $currentHash) { throw 'title-rollback-concurrent-change' }
    [IO.File]::Replace($temp,$plan.launcher,[NullString]::Value)
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force} }
if ([IO.File]::ReadAllText($plan.launcher) -cne $replacement) { throw 'title-rollback-verification-failed' }
[pscustomobject]@{state='rolled-back';launcher=$plan.launcher;backup=$rollbackBackup;desktopRestarted=$false;note='Owned loader exits after observing DISABLED; existing renderer UI clears on next full app start.'}
