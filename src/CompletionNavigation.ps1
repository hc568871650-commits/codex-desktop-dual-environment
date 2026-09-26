# Only validated IDs become links. Never invoke the global codex protocol handler.
function Test-TaskIdentifier([string]$Id) {return $Id -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'}
function Get-CompletionTaskTitle($Instance,[string]$ThreadId) {
    if(-not (Test-TaskIdentifier $ThreadId)){return '任务已完成'}
    $path=Join-Path $Instance.home 'session_index.jsonl'
    if(-not [IO.File]::Exists($path)){return '任务已完成'}
    try{
      Assert-NoReparsePoint $path
      $stream=New-Object IO.FileStream($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
      try{
        $start=[Math]::Max(0,$stream.Length-262144);$stream.Position=$start
        $buffer=New-Object byte[] ([int][Math]::Min(262144,$stream.Length-$start))
        $count=$stream.Read($buffer,0,$buffer.Length);$text=[Text.Encoding]::UTF8.GetString($buffer,0,$count)
      }finally{$stream.Dispose()}
    }catch{return '任务已完成'}
    $lines=$text -split "`n"
    for($n=$lines.Count-1;$n -ge $(if($start -gt 0){1}else{0});$n--){
        try{
            $item=$lines[$n]|ConvertFrom-Json -ErrorAction Stop
            if((Get-ObjectValue $item 'id' '') -ne $ThreadId){continue}
            $title=[string](Get-ObjectValue $item 'thread_name' '')
            $title=($title -replace '[\p{Cc}\p{Cf}]',' ').Trim()
            if($title){if($title.Length -gt 100){$title=$title.Substring(0,99)+'…'};return $title}
        }catch{}
    }
    return '任务已完成'
}
function Request-InstanceTask($Instance,$Process,[string]$ThreadId) {
    if(-not (Test-TaskIdentifier $ThreadId)){throw '任务标识无效，未发送打开请求。'}
    try{$store=Find-CodexExecutable ''}catch{return 'Unsupported'}
    if(-not (Test-SamePath $Process.Path $store)){return 'Unsupported'}
    Invoke-InstanceLocked $Instance {
        [void](Assert-CurrentIdentity $Instance $Process)
        $userData=[CodexDual.Native]::ElectronUserData($Process.Id)
        if($Instance.profile -and (-not $userData -or -not (Test-SamePath $userData $Instance.profile))){return 'Unsupported'}
        if(-not $Instance.profile -and $userData){return 'Unsupported'}
        $info=New-CodexStartInfo -Executable $Process.Path -OfficialHome $Instance.home
        if($userData){$info.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH']=$userData}
        $info.WorkingDirectory=$Instance.projects
        $info.Arguments=if($Instance.profile){'--user-data-dir="'+$Instance.profile+'" '}else{''}
        $info.Arguments+='"codex://threads/'+([guid]$ThreadId).ToString()+'"'
        $secondary=[CodexDual.Native]::StartDetached($info)
        for($n=0;$n -lt 40;$n++){
            # Query only this short-lived activation process; don't enumerate the desktop.
            try{$probe=[Diagnostics.Process]::GetProcessById($secondary)}
            catch [ArgumentException]{[void](Assert-CurrentIdentity $Instance $Process);return 'Requested'}
            $probe.Dispose()
            Start-Sleep -Milliseconds 100
        }
        throw '任务打开请求尚未完成；为避免重复启动，未再次发送。'
    }
}
