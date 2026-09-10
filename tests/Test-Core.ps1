param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\test-results'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
$testRoot = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ([Guid]::NewGuid().ToString('N') + ' 中文 space')
[void][IO.Directory]::CreateDirectory($testRoot)
$official = Join-Path $testRoot 'Official'
$api = Join-Path $testRoot 'API'
[void][IO.Directory]::CreateDirectory($official)
[IO.File]::WriteAllText((Join-Path $official 'auth.json'), 'official-sentinel')
$script:passed = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Output "PASS: $Message"
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert $threw $Message
}

Assert-Throws { Assert-EnvironmentRoot $official $official } 'Reject same official and API directory'
Assert-Throws { Assert-EnvironmentRoot (Join-Path $official 'nested') $official } 'Reject API inside official directory'
Assert-Throws { Assert-EnvironmentRoot $testRoot $official } 'Reject API parent of official directory'
Assert-Throws { Get-FullDirectory 'C:\' } 'Reject drive root'
Assert-Throws { Get-FullDirectory 'relative\path' } 'Reject relative path'
Assert-Throws { Get-FullDirectory '\\server\share' } 'Reject network path'
Assert-Throws { Get-FullDirectory 'C:\abc:stream' } 'Reject alternate data stream'
$occupied = Join-Path $testRoot 'Occupied'
[void][IO.Directory]::CreateDirectory($occupied)
[IO.File]::WriteAllText((Join-Path $occupied 'keep.txt'), 'keep')
Assert-Throws { Assert-EnvironmentRoot $occupied $official } 'Reject nonempty unmanaged directory'
Assert-Throws { New-ApiConfig $api 'https://user:pass@example.com/v1' 'model' } 'Reject embedded URL credentials'
Assert-Throws { New-ApiConfig $api 'http://example.com/v1' 'model' } 'Reject remote plaintext API transport'
Assert-Throws { New-ApiConfig $api 'https://example.com/v1?key=secret' 'model' } 'Reject URL query credentials'
Assert-Throws { New-ApiConfig $api 'https://example.com/v1' "model`nmalicious=true" } 'Reject multiline model injection'
Assert-Throws { Save-ApiEnvironment $api $official 'https://example.com/v1' 'model' $null } 'Require initial key'
Assert (-not (Test-Path -LiteralPath $api)) 'Validation failure creates no environment'

$fakeKey = ConvertTo-SecureString 'test-only-not-a-real-api-key' -AsPlainText -Force
try { [void](Save-ApiEnvironment $api $official 'https://example.com/v1' 'model"quoted\name' $fakeKey) }
finally { $fakeKey.Dispose() }
$configPath = Join-Path $api 'CodexHome\config.toml'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
Assert ($config.Contains('model = "model\"quoted\\name"')) 'Escape TOML quotes and backslashes'
Assert ($config.Contains('projectlessWorkspaceRoot = ' + (ConvertTo-TomlString (Join-Path $api 'Projectless')))) 'Generate isolated task directory'
Assert (-not $config.Contains('test-only-not-a-real-api-key')) 'Keep key out of TOML'
$encrypted = Get-Content -LiteralPath (Join-Path $api 'Credentials\api-key.dpapi') -Raw -Encoding UTF8
Assert (-not $encrypted.Contains('test-only-not-a-real-api-key')) 'Store encrypted credential'
$apiAuth = Get-Content -LiteralPath (Join-Path $api 'CodexHome\auth.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($apiAuth.auth_mode -eq 'apikey' -and $apiAuth.OPENAI_API_KEY -eq 'CODEX_DUAL_ENV_KEY') 'Create non-secret API mode marker instead of copying official authentication'
Assert ($config.Contains('forced_login_method = "api"') -and $config.Contains('cli_auth_credentials_store = "file"')) 'Constrain the isolated environment to API file authentication'
$firstConfig = $config
[void](Save-ApiEnvironment $api $official 'http://localhost:1234/v1' 'new-model' $null)
Assert ((Get-Content -LiteralPath (Join-Path $api 'Credentials\api-key.dpapi') -Raw -Encoding UTF8) -eq $encrypted) 'Retain key on blank update'
$backups = @(Get-ChildItem -LiteralPath (Join-Path $api 'Backup') -Filter '*.toml')
Assert ($backups.Count -eq 1 -and [IO.File]::ReadAllText($backups[0].FullName) -eq $firstConfig) 'Preserve exact prior configuration backup'
Assert ((Get-Content -LiteralPath (Join-Path $official 'auth.json') -Raw -Encoding UTF8) -eq 'official-sentinel') 'Leave official authentication unchanged'

$savedOpenAi = $env:OPENAI_API_KEY
$savedNode = $env:NODE_OPTIONS
try {
    $env:OPENAI_API_KEY = 'inherited-test-key'
    $env:NODE_OPTIONS = '--trace-warnings'
    $info = New-CodexStartInfo -Executable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -OfficialHome $official -ApiRoot $api -Api
    Assert ($info.EnvironmentVariables['CODEX_HOME'] -eq (Join-Path $api 'CodexHome')) 'Set child CODEX_HOME'
    Assert ($info.EnvironmentVariables['CODEX_DUAL_API_KEY'] -eq 'test-only-not-a-real-api-key') 'Decrypt API credential into child environment'
    Assert (-not $info.EnvironmentVariables.ContainsKey('OPENAI_API_KEY')) 'Remove inherited API credential from child'
    Assert (-not $info.EnvironmentVariables.ContainsKey('NODE_OPTIONS')) 'Remove inherited Node options from child'
    Assert ($info.Arguments -eq ('--user-data-dir="' + (Join-Path $api 'DesktopProfile') + '"')) 'Quote profile argument with spaces and Chinese characters'
    $capturePath = Join-Path $testRoot 'capture.ps1'
    $resultPath = Join-Path $testRoot 'child.json'
    $capture = @'
param([string]$OutputPath)
@{home=$env:CODEX_HOME; keyMatches=($env:CODEX_DUAL_API_KEY -eq 'test-only-not-a-real-api-key');
  inheritedKeyPresent=[bool]$env:OPENAI_API_KEY; workdir=[Environment]::CurrentDirectory} |
    ConvertTo-Json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
'@
    [IO.File]::WriteAllText($capturePath, $capture, (New-Object Text.UTF8Encoding($true)))
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $capturePath + '" -OutputPath "' + $resultPath + '"'
    $info.CreateNoWindow = $true
    $child = [Diagnostics.Process]::Start($info)
    try {
        if (-not $child.WaitForExit(15000)) { $child.Kill(); throw 'Child environment test timed out.' }
        Assert ($child.ExitCode -eq 0) 'Run real child process successfully'
    } finally { $child.Dispose(); $info.EnvironmentVariables.Remove('CODEX_DUAL_API_KEY') }
    $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($result.home -eq (Join-Path $api 'CodexHome') -and $result.keyMatches -and -not $result.inheritedKeyPresent) 'Verify real child receives isolated credential and directory'
    Assert ($result.workdir -eq (Join-Path $api 'Projects')) 'Verify child working directory'
    Assert ($env:OPENAI_API_KEY -eq 'inherited-test-key') 'Leave parent environment unchanged'
    $officialInfo = New-CodexStartInfo -Executable 'unused.exe' -OfficialHome $official
    Assert ($officialInfo.EnvironmentVariables['CODEX_HOME'] -eq $official) 'Official child uses explicit official configuration directory'
    Assert (-not $officialInfo.EnvironmentVariables.ContainsKey('OPENAI_API_KEY') -and -not $officialInfo.EnvironmentVariables.ContainsKey('CODEX_DUAL_API_KEY')) 'Official child has no inherited API keys'
    Assert ([string]::IsNullOrEmpty($officialInfo.Arguments)) 'Official child uses original desktop profile'
} finally {
    $env:OPENAI_API_KEY = $savedOpenAi
    $env:NODE_OPTIONS = $savedNode
}
$junction = Join-Path $testRoot 'Linked'
[void](New-Item -ItemType Junction -Path $junction -Target $occupied)
Assert-Throws { Assert-EnvironmentRoot (Join-Path $junction 'API') $official } 'Reject path through directory junction'
Assert-Throws { Find-CodexExecutable (Join-Path $testRoot 'missing.exe') } 'Report missing executable'
$beforeConflict = [IO.File]::ReadAllText($configPath)
[IO.File]::WriteAllText((Join-Path $api 'CodexHome\auth.json'), '{"auth_mode":"chatgpt","OPENAI_API_KEY":null}')
Assert-Throws { Save-ApiEnvironment $api $official 'https://example.com/v1' 'changed' $null } 'Refuse to overwrite other authentication in a managed environment'
Assert ([IO.File]::ReadAllText($configPath) -eq $beforeConflict) 'Authentication conflict leaves configuration unchanged'
Assert-Throws { New-CodexStartInfo -Executable 'unused.exe' -OfficialHome $official -ApiRoot $api -Api } 'Refuse to launch if API authentication marker was changed'
Write-Output "All $script:passed assertions passed. Test output: $testRoot"
