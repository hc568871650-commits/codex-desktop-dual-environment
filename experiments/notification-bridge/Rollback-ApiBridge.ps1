param([string]$TrialDirectory=$PSScriptRoot)
. "$PSScriptRoot\Trial.Common.ps1"
$m=Read-BridgeTrial $TrialDirectory
# Stop admission first. Do not terminate Codex, send a default answer, or delete data.
$disabled=Join-Path $m.root 'DISABLED'
$temp=$disabled+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
[IO.File]::WriteAllText($temp,'Disabled by rollback at '+[DateTime]::UtcNow.ToString('o'))
if(Test-Path -LiteralPath $disabled){[IO.File]::Replace($temp,$disabled,[NullString]::Value)}else{[IO.File]::Move($temp,$disabled)}
$record=@{schema=1;trialId=$m.id;utc=[DateTime]::UtcNow.ToString('o');bridgeDisabled=$true;nextLaunch='without-bridge';processesTerminated=0;originalInstallationModified=$false}
Write-TrialJson (Join-Path $m.root 'rollback-result.json') $record
Write-Output '桥接已停用。运行中的代理在下一次处理消息时停止接受外部回答，原 Codex 窗口仍可作答。'
Write-Output '如需彻底绕过代理，请仅关闭隔离测试窗口，再运行 Start-WithoutBridge.cmd。本脚本没有结束进程，也没有删除聊天或配置。'
Write-Output '日常 API 版和官方版均未被本次隔离实验修改。'
