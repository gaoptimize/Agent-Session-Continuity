[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$failures = [Collections.Generic.List[string]]::new()
$passes = [Collections.Generic.List[string]]::new()

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($Condition) { $passes.Add($Name) }
    else { $failures.Add($Name) }
}

$required = @(
    'AgentSessionContinuity.bat',
    'AgentSessionContinuity.ps1',
    'src\AgentSessionContinuity.ps1',
    'src\Safety.psm1',
    'src\Dashboard.psm1',
    'README.md',
    'LICENSE',
    'SECURITY.md',
    'docs\ARCHITECTURE.md',
    'docs\ADAPTERS.md'
)
foreach ($relative in $required) {
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf) -Name "required: $relative"
}

foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1', '*.psm1') {
    try {
        [void] [scriptblock]::Create((Get-Content -Raw -LiteralPath $file.FullName))
        $passes.Add("parse: $($file.FullName.Substring($root.Length + 1))")
    }
    catch {
        $failures.Add("parse: $($file.FullName.Substring($root.Length + 1)): $($_.Exception.Message)")
    }
}

$forbidden = @(
    ('Tschae' + 'fer'),
    ('D:' + '\rapl'),
    ('R:' + '\lmstudio'),
    ('C:' + '\Users\')
)
$distributionFiles = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.Extension -in @('.ps1', '.psm1', '.bat', '.md', '.txt', '.json', '.yml', '.yaml') }
foreach ($marker in $forbidden) {
    $hits = @($distributionFiles | Select-String -SimpleMatch -Pattern $marker)
    Assert-True -Condition ($hits.Count -eq 0) -Name "no machine-specific marker: $marker"
}

$license = Get-Content -Raw -LiteralPath (Join-Path $root 'LICENSE')
Assert-True -Condition ($license.StartsWith('MIT License')) -Name 'MIT license text present'

$entry = Join-Path $root 'AgentSessionContinuity.ps1'
$versionOutput = & $entry version
$versionSucceeded = $?
Assert-True -Condition ($versionSucceeded -and $versionOutput -match '^\d+\.\d+\.\d+$') -Name 'version command from strict-mode caller'

$safetyModule = Join-Path $root 'src\Safety.psm1'
Import-Module $safetyModule -Force
$currentProcess = Get-Process -Id $PID
Assert-True -Condition (Test-ProcessStartIdentity -Expected $currentProcess.StartTime.ToString('o') `
    -Actual $currentProcess.StartTime) -Name 'process identity accepts matching PID start time'
Assert-True -Condition (-not (Test-ProcessStartIdentity -Expected $currentProcess.StartTime.AddMinutes(-1).ToString('o') `
    -Actual $currentProcess.StartTime)) -Name 'process identity rejects reused PID start time'
Assert-True -Condition (-not (Test-ProcessStartIdentity -Expected 'not-a-time' `
    -Actual $currentProcess.StartTime)) -Name 'process identity rejects malformed saved start time'

$unique = Select-UniqueLowestDistance -Candidates @(
    [pscustomobject]@{ Id = 'winner'; Distance = 1 }
    [pscustomobject]@{ Id = 'outside-window'; Distance = 30 }
) -WindowSeconds 20
Assert-True -Condition ($unique.Id -eq 'winner') -Name 'temporal matcher accepts the sole in-window candidate'
$ambiguous = Select-UniqueLowestDistance -Candidates @(
    [pscustomobject]@{ Id = 'one'; Distance = 1 }
    [pscustomobject]@{ Id = 'two'; Distance = 10 }
) -WindowSeconds 20
Assert-True -Condition ($null -eq $ambiguous) -Name 'temporal matcher rejects any in-window runner-up'

$coordinatorSource = Get-Content -Raw -LiteralPath (Join-Path $root 'src\AgentSessionContinuity.ps1')
Assert-True -Condition ($coordinatorSource -match 'Stop-Process\s+-InputObject') -Name 'stop path uses validated process objects'
Assert-True -Condition ($coordinatorSource -notmatch 'Stop-Process\s+-Id') -Name 'stop path never terminates by bare PID'
Assert-True -Condition ($coordinatorSource -match '-Executable \$script:CodexCommand -Arguments @\(''update''\)') `
    -Name 'Codex uses its documented update command'
Assert-True -Condition ($coordinatorSource -match '-Executable \$script:GrokCommand -Arguments @\(''update''\)') `
    -Name 'Grok uses its documented update command'
Assert-True -Condition ($coordinatorSource -match '''grok''\s+\{[^\r\n]+--resume') `
    -Name 'Grok uses its documented resume flag'
Assert-True -Condition ($coordinatorSource -match '-Executable \$script:KimiCommand -Arguments @\(''update'', ''-y''\)') `
    -Name 'Kimi uses its documented noninteractive update command'
Assert-True -Condition ($coordinatorSource -match '''kimi''\s+\{[^\r\n]+--session') `
    -Name 'Kimi uses its documented session resume flag'
Assert-True -Condition ($coordinatorSource -notmatch 'Get-Content[^\r\n]*wire\.jsonl') `
    -Name 'Kimi adapter never reads the conversation event stream'
Assert-True -Condition ($coordinatorSource -notmatch 'assistantReply|assistantThinking|assistantRefusal') `
    -Name 'DeepCode adapter does not copy reply, thinking, or refusal fields'

$testState = Join-Path ([IO.Path]::GetTempPath()) ('asc-test-' + [guid]::NewGuid().ToString('N'))
try {
    $fakeGrokHome = Join-Path $testState 'fake-grok'
    $workspace = Join-Path (Join-Path $fakeGrokHome 'sessions') ([Uri]::EscapeDataString('D:\example\grok-project'))
    $fakeSessionId = '11111111-2222-4333-8444-555555555555'
    $fakeSession = Join-Path $workspace $fakeSessionId
    New-Item -ItemType Directory -Path $fakeSession -Force | Out-Null
    [ordered]@{
        generated_title = 'Review the release boundary'
        created_at = '2026-09-26T12:00:00Z'
        updated_at = '2026-09-26T12:30:00Z'
        last_active_at = '2026-09-26T12:30:00Z'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fakeSession 'summary.json') -Encoding utf8
    $minimalSessionId = '66666666-7777-4888-8999-aaaaaaaaaaaa'
    $minimalSession = Join-Path $workspace $minimalSessionId
    New-Item -ItemType Directory -Path $minimalSession -Force | Out-Null
    @{ info = 'legacy-schema-fixture' } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $minimalSession 'summary.json') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fakeGrokHome 'active_sessions.json') -Value '[]' -Encoding utf8

    $fakeKimiHome = Join-Path $testState 'fake-kimi'
    $fakeKimiSessionId = 'session_bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'
    $fakeKimiSession = Join-Path (Join-Path (Join-Path $fakeKimiHome 'sessions') 'wd_example_hash') $fakeKimiSessionId
    New-Item -ItemType Directory -Path (Join-Path $fakeKimiSession 'agents\main') -Force | Out-Null
    [ordered]@{
        id = $fakeKimiSessionId
        cwd = 'D:\example\kimi-project'
        title = 'Inspect the metadata boundary'
        createdAt = 1790424000000
        updatedAt = 1790425800000
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fakeKimiSession 'state.json') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fakeKimiSession 'agents\main\wire.jsonl') -Value '' -Encoding utf8
    [ordered]@{
        sessionId = $fakeKimiSessionId
        sessionDir = $fakeKimiSession
        workDir = 'D:\example\kimi-project'
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $fakeKimiHome 'session_index.jsonl') -Encoding utf8
    $outsideKimiId = 'session_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    $outsideKimiSession = Join-Path $testState $outsideKimiId
    New-Item -ItemType Directory -Path $outsideKimiSession -Force | Out-Null
    @{ id=$outsideKimiId; cwd='D:\outside'; title='Must not import' } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $outsideKimiSession 'state.json') -Encoding utf8
    [ordered]@{
        sessionId = $outsideKimiId
        sessionDir = $outsideKimiSession
        workDir = 'D:\outside'
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $fakeKimiHome 'session_index.jsonl') -Encoding utf8

    $fakeDeepCodeHome = Join-Path $testState 'fake-deepcode'
    $fakeDeepCodeProject = Join-Path $fakeDeepCodeHome 'projects\D-example'
    New-Item -ItemType Directory -Path $fakeDeepCodeProject -Force | Out-Null
    $fakeDeepCodeId = '12345678-9abc-4def-8123-456789abcdef'
    [ordered]@{
        version = 1
        originalPath = 'D:\example\deepcode-project'
        entries = @(
            [ordered]@{
                id = $fakeDeepCodeId
                summary = 'Map the local session index'
                assistantReply = 'ASSISTANT-REPLY-SENTINEL'
                assistantThinking = 'THINKING-SENTINEL'
                createTime = '2026-08-06T19:59:06Z'
                updateTime = '2026-08-06T20:58:41Z'
                status = 'completed'
            }
        )
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fakeDeepCodeProject 'sessions-index.json') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fakeDeepCodeProject "$fakeDeepCodeId.jsonl") -Value 'TRANSCRIPT-SENTINEL' -Encoding utf8
    $outsideDeepCode = Join-Path $testState 'outside-deepcode'
    New-Item -ItemType Directory -Path $outsideDeepCode -Force | Out-Null
    @{
        originalPath = 'D:\outside'
        entries = @(@{ id = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'; summary = 'Must not import' })
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outsideDeepCode 'sessions-index.json') -Encoding utf8

    & $entry scan -StateRoot $testState -GrokHome $fakeGrokHome -KimiHome $fakeKimiHome -DeepCodeHome $fakeDeepCodeHome |
        Out-Null
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $testState 'running-sessions.json')) -Name 'scan writes inventory'
    $inventory = Get-Content -Raw -LiteralPath (Join-Path $testState 'running-sessions.json') | ConvertFrom-Json
    Assert-True -Condition ($inventory.schemaVersion -eq 1) -Name 'inventory schema version'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $testState 'session-registry.json')) `
        -Name 'scan updates persistent session registry'
    $registry = Get-Content -Raw -LiteralPath (Join-Path $testState 'session-registry.json') | ConvertFrom-Json
    $catalogedGrok = @($registry.sessions | Where-Object { $_.tool -eq 'grok' -and $_.sessionId -eq $fakeSessionId })
    Assert-True -Condition ($catalogedGrok.Count -eq 1 -and -not $catalogedGrok[0].active -and
        $catalogedGrok[0].name -eq 'Review the release boundary') `
        -Name 'Grok catalog sessions appear as inactive dashboard history'
    Assert-True -Condition (@($registry.sessions | Where-Object sessionId -eq $minimalSessionId).Count -eq 1) `
        -Name 'Grok catalog tolerates missing optional summary fields'
    $catalogedKimi = @($registry.sessions | Where-Object { $_.tool -eq 'kimi' -and $_.sessionId -eq $fakeKimiSessionId })
    Assert-True -Condition ($catalogedKimi.Count -eq 1 -and -not $catalogedKimi[0].active -and
        $catalogedKimi[0].name -eq 'Inspect the metadata boundary' -and
        $catalogedKimi[0].cwd -eq 'D:\example\kimi-project') `
        -Name 'Kimi metadata catalog sessions appear as inactive dashboard history'
    Assert-True -Condition (@($registry.sessions | Where-Object sessionId -eq $outsideKimiId).Count -eq 0) `
        -Name 'Kimi catalog rejects indexed paths outside its session root'
    $catalogedDeepCode = @($registry.sessions | Where-Object { $_.tool -eq 'deepcode' -and $_.sessionId -eq $fakeDeepCodeId })
    Assert-True -Condition ($catalogedDeepCode.Count -eq 1 -and -not $catalogedDeepCode[0].active -and
        $catalogedDeepCode[0].name -eq 'Map the local session index' -and
        $catalogedDeepCode[0].cwd -eq 'D:\example\deepcode-project') `
        -Name 'DeepCode index sessions appear as inactive dashboard history'
    $registryText = Get-Content -Raw -LiteralPath (Join-Path $testState 'session-registry.json')
    Assert-True -Condition ($registryText -notmatch 'ASSISTANT-REPLY-SENTINEL|THINKING-SENTINEL|TRANSCRIPT-SENTINEL') `
        -Name 'DeepCode registry omits replies, thinking, and transcripts'
    Assert-True -Condition (@($registry.sessions | Where-Object sessionId -eq 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee').Count -eq 0) `
        -Name 'DeepCode catalog ignores indexes outside its projects root'

    $dashboardOutput = & $entry dashboard -NoOpen -StateRoot $testState -GrokHome $fakeGrokHome -KimiHome $fakeKimiHome -DeepCodeHome $fakeDeepCodeHome
    $dashboardSucceeded = $?
    $dashboardPath = Join-Path $testState 'session-dashboard.html'
    Assert-True -Condition ($dashboardSucceeded -and (Test-Path -LiteralPath $dashboardPath)) `
        -Name 'dashboard command writes browser panel without opening it'
    $dashboard = Get-Content -Raw -LiteralPath $dashboardPath
    Assert-True -Condition ($dashboard -match '<th class="agent-col">Agent</th>' -and
        $dashboard -match 'Home / initiation folder' -and $dashboard -match 'Recent actions') `
        -Name 'dashboard contains requested session columns'
    Assert-True -Condition ($dashboard -match 'Conversation messages are never copied') `
        -Name 'dashboard states its privacy boundary'
    Assert-True -Condition ($dashboard -match "kimi:'Kimi Code'") `
        -Name 'dashboard labels Kimi Code sessions'
    $payloadMatch = [regex]::Match($dashboard, "const payload = '([^']+)';")
    $payloadText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadMatch.Groups[1].Value))
    Assert-True -Condition ($dashboard -match "deepcode:'DeepCode'" -and
        $payloadText -match 'Map the local session index' -and
        $payloadText -notmatch 'ASSISTANT-REPLY-SENTINEL|THINKING-SENTINEL|TRANSCRIPT-SENTINEL') `
        -Name 'dashboard lists DeepCode without reply or transcript text'
    Assert-True -Condition ($dashboard -match 'className = ''expander''' -and $dashboard -match 'aria-expanded' -and
        $dashboard -match 'other sessions') `
        -Name 'dashboard groups other sessions behind a click'
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedState = [IO.Path]::GetFullPath($testState)
    if ($resolvedState.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedState)) {
        Remove-Item -LiteralPath $resolvedState -Recurse -Force
    }
}

foreach ($name in $passes) { Write-Host "PASS $name" -ForegroundColor Green }
foreach ($name in $failures) { Write-Host "FAIL $name" -ForegroundColor Red }
Write-Host "`n$($passes.Count) passed; $($failures.Count) failed."

if ($failures.Count -gt 0) { exit 1 }
