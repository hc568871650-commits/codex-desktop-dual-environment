[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CodexHome,
    [Parameter(Mandatory)][string]$DesktopProfile,
    [Parameter(Mandatory)][string]$Cli,
    [string]$Model,
    [string]$CredentialFile,
    [string]$KeyEnvName
)
$ErrorActionPreference = 'Stop'
if ($CredentialFile -and $KeyEnvName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'CredentialFile requires an explicit valid KeyEnvName.' }
if ($KeyEnvName -and -not $CredentialFile) { throw 'KeyEnvName requires CredentialFile; otherwise inherit an existing environment variable.' }
$prior = $null
$secretPointer = [IntPtr]::Zero
try {
    if ($CredentialFile) {
        $prior = [Environment]::GetEnvironmentVariable($KeyEnvName, 'Process')
        $secure = (Get-Content -LiteralPath $CredentialFile -Raw).Trim() | ConvertTo-SecureString
        $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        [Environment]::SetEnvironmentVariable($KeyEnvName, [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer), 'Process')
    }
    $runArgs = @('-3', (Join-Path $PSScriptRoot 'title_service.py'), '--live', '--home', $CodexHome, '--desktop-profile', $DesktopProfile, '--cli', $Cli)
    if ($Model) { $runArgs += @('--model', $Model) }
    & py @runArgs
    if ($LASTEXITCODE -ne 0) { throw 'Title preview service exited with a failure.' }
}
finally {
    if ($CredentialFile) { [Environment]::SetEnvironmentVariable($KeyEnvName, $prior, 'Process') }
    if ($secretPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer) }
}
