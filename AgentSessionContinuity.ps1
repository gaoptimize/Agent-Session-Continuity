& (Join-Path $PSScriptRoot 'src\AgentSessionContinuity.ps1') @args
if (-not $?) { exit 1 }
exit 0
