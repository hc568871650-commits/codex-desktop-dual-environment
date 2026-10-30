param([Parameter(Mandatory)][ValidateSet('enable','disable')][string]$Mode,[string]$ConfigPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'instances.local.json'),[string]$Model='')
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\src\Instances.ps1"
$config=Read-ControllerConfig $ConfigPath
$path=Join-Path $config.stateDirectory 'dotnet-title.local.json';Assert-NoReparsePoint $path
$settings=if(Test-Path -LiteralPath $path){Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}else{[pscustomobject]@{schema=1;enabled=$false;model='';transport='codex-cli';credentialFiles=[pscustomobject]@{}}}
if($Mode -eq 'enable'){
 if(-not $Model -and -not $settings.model){throw 'Specify -Model using a model supported by your provider.'}
 if($Model){$settings.model=$Model}
 $api=@($config.instances|Where-Object {$_.role -eq 'api'})[0]
 if($api.launchMode -eq 'managed-api'){
  $settings.credentialFiles|Add-Member -NotePropertyName 'CODEX_DUAL_API_KEY' -NotePropertyValue (Join-Path $api.apiRoot 'Credentials\api-key.dpapi') -Force
 }
}
$settings.enabled=$Mode -eq 'enable'
[void][IO.Directory]::CreateDirectory($config.stateDirectory)
Write-AtomicText $path ($settings|ConvertTo-Json -Depth 6)
Write-Output 'Title setting saved. Restart the controller. Enabling requires restarting API Desktop after its tasks finish; external launchers require the documented loopback debugging arguments.'
