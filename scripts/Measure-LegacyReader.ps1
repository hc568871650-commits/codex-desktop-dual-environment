param([Parameter(Mandatory)][string]$Fixture,[Parameter(Mandatory)][string]$Report)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\src\CompletionReader.ps1')
$measurements=@()
for($n=0;$n -lt 6;$n++){
    $cursor=New-CompletionCursor -Path $Fixture -InstanceId ('a'*32) -FromStart
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $result=Read-NewCompletions $cursor
        if($result.Completions.Count -ne 1){throw 'Benchmark correctness failed'}
        if($n -gt 0){$measurements+=$watch.Elapsed.TotalMilliseconds}
    }finally{Close-CompletionCursor $cursor}
}
@{runtime=$PSVersionTable.PSVersion.ToString();bytes=(Get-Item -LiteralPath $Fixture).Length;milliseconds=$measurements;note='Identical synthetic fixture; warm iterations; no model call'}|ConvertTo-Json|Set-Content -LiteralPath $Report -Encoding UTF8
