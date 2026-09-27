[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'check', 'scan', 'list', 'cycle', 'restart', 'dashboard', 'doctor', 'version')]
    [string] $Action = 'menu',

    [Parameter(Position = 1)]
    [string] $Session,

    [switch] $Yes,

    [switch] $NoOpen,

    [string] $StateRoot = (Join-Path $env:LOCALAPPDATA 'AgentSessionContinuity'),

    [string] $CodexHome = $(
        if ($env:CODEX_HOME) { $env:CODEX_HOME }
        else { Join-Path $env:USERPROFILE '.codex' }
    ),

    [string] $ClaudeHome = $(
        if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR }
        else { Join-Path $env:USERPROFILE '.claude' }
    ),

    [string] $GrokHome = $(
        if ($env:GROK_HOME) { $env:GROK_HOME }
        else { Join-Path $env:USERPROFILE '.grok' }
    ),

    [string] $KimiHome = $(
        if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME }
        else { Join-Path $env:USERPROFILE '.kimi-code' }
    ),

    [string] $DeepCodeHome = (Join-Path $env:USERPROFILE '.deepcode')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Safety.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Dashboard.psm1') -Force

function Resolve-ExecutablePath {
    param(
        [Parameter(Mandatory)] [string[]] $Names,
        [string[]] $FallbackPaths = @()
    )

    foreach ($name in $Names) {
        $command = Get-Command $name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command -and $command.Source) {
            return [IO.Path]::GetFullPath($command.Source)
        }
    }
    foreach ($path in $FallbackPaths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) {
            return [IO.Path]::GetFullPath($path)
        }
    }
    return $null
}

$npmBin = if ($env:APPDATA) { Join-Path $env:APPDATA 'npm' } else { $null }
$script:CodexCommand = Resolve-ExecutablePath -Names @('codex.cmd', 'codex.exe', 'codex') -FallbackPaths @(
    $(if ($npmBin) { Join-Path $npmBin 'codex.cmd' })
)
$script:ClaudeCommand = Resolve-ExecutablePath -Names @('claude.exe', 'claude.cmd', 'claude') -FallbackPaths @(
    (Join-Path $env:USERPROFILE '.local\bin\claude.exe')
)
$script:GrokCommand = Resolve-ExecutablePath -Names @('grok.exe', 'grok.cmd', 'grok') -FallbackPaths @(
    (Join-Path $GrokHome 'bin\grok.exe')
)
$script:KimiCommand = Resolve-ExecutablePath -Names @('kimi.exe', 'kimi.cmd', 'kimi') -FallbackPaths @(
    (Join-Path $KimiHome 'bin\kimi.exe')
)
$script:DeepCodeCommand = Resolve-ExecutablePath -Names @('deepcode.cmd', 'deepcode.exe', 'deepcode') -FallbackPaths @(
    $(if ($npmBin) { Join-Path $npmBin 'deepcode.cmd' })
)
$script:NpmCommand = Resolve-ExecutablePath -Names @('npm.cmd', 'npm.exe', 'npm')
$script:PowerShellCommand = (Get-Process -Id $PID).Path
$script:InventoryPath = Join-Path $StateRoot 'running-sessions.json'
$script:CyclePath = Join-Path $StateRoot 'last-cycle.json'
$script:HistoryPath = Join-Path $StateRoot 'history.jsonl'
$script:LogPath = Join-Path $StateRoot 'AgentSessionContinuity.log'
$script:RegistryPath = Join-Path $StateRoot 'session-registry.json'
$script:DashboardPath = Join-Path $StateRoot 'session-dashboard.html'
$script:UuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:KimiIdPattern = 'session_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:Version = '0.1.0'

function Test-CodexExecutablePath {
    param([Parameter(Mandatory)] [string] $ExecutablePath)

    if (-not $script:CodexCommand) { return $false }
    $candidate = [IO.Path]::GetFullPath($ExecutablePath)
    $resolved = [IO.Path]::GetFullPath($script:CodexCommand)
    if ([IO.Path]::GetExtension($resolved) -ieq '.exe') {
        return $candidate -ieq $resolved
    }

    $vendorRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $resolved) 'node_modules\@openai'))
    return (Split-Path -Leaf $candidate) -ieq 'codex.exe' -and
        $candidate.StartsWith(($vendorRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Initialize-StateRoot {
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )

    Initialize-StateRoot
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format o), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
}

function Add-HistoryRecord {
    param(
        [Parameter(Mandatory)] [string] $Event,
        [hashtable] $Data = @{}
    )

    Initialize-StateRoot
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        event = $Event
        data = $Data
    }
    Add-Content -LiteralPath $script:HistoryPath -Value ($record | ConvertTo-Json -Compress -Depth 8) -Encoding utf8
}

function ConvertTo-LocalDateTime {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string] $Value)) {
        return $null
    }

    if ($Value -is [long] -or $Value -is [int] -or ([string] $Value -match '^\d{10,13}$')) {
        $number = [int64] $Value
        if ($number -gt 9999999999) {
            return [DateTimeOffset]::FromUnixTimeMilliseconds($number).LocalDateTime
        }
        return [DateTimeOffset]::FromUnixTimeSeconds($number).LocalDateTime
    }

    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string] $Value, [ref] $parsed)) {
        return $parsed.LocalDateTime
    }
    return $null
}

function Get-ProcessRecords {
    return @(Get-CimInstance Win32_Process)
}

function Get-PreviousSessions {
    if (-not (Test-Path -LiteralPath $script:InventoryPath)) {
        return @()
    }
    try {
        $saved = Get-Content -Raw -LiteralPath $script:InventoryPath | ConvertFrom-Json
        return @($saved.sessions)
    }
    catch {
        Write-Log "Could not read prior inventory: $($_.Exception.Message)" 'WARN'
        return @()
    }
}

function Initialize-RestartManagerType {
    if ('AgentSessionContinuity.RestartManager' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace AgentSessionContinuity {
    public static class RestartManager {
        [StructLayout(LayoutKind.Sequential)]
        public struct RM_UNIQUE_PROCESS {
            public int dwProcessId;
            public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
        }

        public enum RM_APP_TYPE {
            RmUnknownApp = 0,
            RmMainWindow = 1,
            RmOtherWindow = 2,
            RmService = 3,
            RmExplorer = 4,
            RmConsole = 5,
            RmCritical = 1000
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct RM_PROCESS_INFO {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
            public string strServiceShortName;
            public RM_APP_TYPE ApplicationType;
            public uint AppStatus;
            public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)]
            public bool bRestartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        public static extern int RmStartSession(out uint handle, int flags, StringBuilder key);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        public static extern int RmRegisterResources(uint handle, uint fileCount, string[] files,
            uint appCount, RM_UNIQUE_PROCESS[] apps, uint serviceCount, string[] services);

        [DllImport("rstrtmgr.dll")]
        public static extern int RmGetList(uint handle, out uint needed, ref uint count,
            [In, Out] RM_PROCESS_INFO[] affected, ref uint rebootReasons);

        [DllImport("rstrtmgr.dll")]
        public static extern int RmEndSession(uint handle);
    }
}
'@
}

function Get-FileLockerPids {
    param([Parameter(Mandatory)] [string] $Path)

    Initialize-RestartManagerType
    $key = [Text.StringBuilder]::new(33)
    [uint32] $handle = 0
    $result = [AgentSessionContinuity.RestartManager]::RmStartSession([ref] $handle, 0, $key)
    if ($result -ne 0) {
        return @()
    }

    try {
        $result = [AgentSessionContinuity.RestartManager]::RmRegisterResources(
            $handle, 1, @($Path), 0, $null, 0, $null
        )
        if ($result -ne 0) {
            return @()
        }

        [uint32] $needed = 0
        [uint32] $count = 0
        [uint32] $reasons = 0
        $null = [AgentSessionContinuity.RestartManager]::RmGetList(
            $handle, [ref] $needed, [ref] $count, $null, [ref] $reasons
        )
        if ($needed -eq 0) {
            return @()
        }

        $items = New-Object 'AgentSessionContinuity.RestartManager+RM_PROCESS_INFO[]' $needed
        $count = $needed
        $result = [AgentSessionContinuity.RestartManager]::RmGetList(
            $handle, [ref] $needed, [ref] $count, $items, [ref] $reasons
        )
        if ($result -ne 0) {
            return @()
        }
        return @($items | ForEach-Object { [int] $_.Process.dwProcessId })
    }
    finally {
        $null = [AgentSessionContinuity.RestartManager]::RmEndSession($handle)
    }
}

function Get-ResumeIdFromCommandLine {
    param([string] $CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $null
    }
    $patterns = @(
        ('(?i)(?:resume|--resume|-r)\s+["'']?({0})' -f $script:UuidPattern),
        ('(?i)--session-id\s+["'']?({0})' -f $script:UuidPattern)
    )
    foreach ($pattern in $patterns) {
        if ($CommandLine -match $pattern) {
            return $Matches[1]
        }
    }
    return $null
}

function Get-CodexNameMap {
    $map = @{}
    $path = Join-Path $CodexHome 'session_index.jsonl'
    if (-not (Test-Path -LiteralPath $path)) {
        return $map
    }

    foreach ($line in [IO.File]::ReadLines($path)) {
        try {
            $item = $line | ConvertFrom-Json
            if ($item.id) {
                $map[[string] $item.id] = [string] $item.thread_name
            }
        }
        catch { }
    }
    return $map
}

function Get-CodexSessionCatalog {
    $root = Join-Path $CodexHome 'sessions'
    if (-not (Test-Path -LiteralPath $root)) {
        return @()
    }

    $catalog = foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.jsonl') {
        try {
            $firstLine = Get-Content -LiteralPath $file.FullName -TotalCount 1
            $meta = $firstLine | ConvertFrom-Json
            $payload = $meta.payload
            if (-not $payload.id) { continue }
            [pscustomobject]@{
                Id = [string] $payload.id
                Cwd = [string] $payload.cwd
                StartedAt = ConvertTo-LocalDateTime ($meta.timestamp ?? $payload.timestamp)
                LastWriteTime = $file.LastWriteTime
                Path = $file.FullName
            }
        }
        catch { }
    }
    return @($catalog)
}

function Get-CodexSessions {
    param(
        [object[]] $Processes,
        [object[]] $Previous
    )

    $native = @($Processes | Where-Object {
        $_.Name -ieq 'codex.exe' -and $_.ExecutablePath -and
        (Test-CodexExecutablePath -ExecutablePath $_.ExecutablePath)
    })
    if ($native.Count -eq 0) {
        return @()
    }

    $processById = @{}
    foreach ($process in $Processes) {
        $processById[[int] $process.ProcessId] = $process
    }

    $catalog = @(Get-CodexSessionCatalog)
    $nameMap = Get-CodexNameMap
    $lockMap = @{}
    foreach ($entry in $catalog) {
        foreach ($lockerProcessId in Get-FileLockerPids -Path $entry.Path) {
            $lockMap[$lockerProcessId] = $entry
        }
    }

    $usedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sessions = foreach ($process in $native) {
        $processId = [int] $process.ProcessId
        $start = [datetime] $process.CreationDate
        $parent = $processById[[int] $process.ParentProcessId]
        $sessionId = $null
        $matched = $null
        $confidence = 'Unmapped'
        $method = 'none'

        if ($lockMap.ContainsKey($processId)) {
            $matched = $lockMap[$processId]
            $sessionId = $matched.Id
            $confidence = 'Exact'
            $method = 'journal-lock'
        }

        if (-not $sessionId -and $null -ne $parent) {
            $sessionId = Get-ResumeIdFromCommandLine $parent.CommandLine
            if ($sessionId) {
                $matched = $catalog | Where-Object Id -eq $sessionId | Select-Object -First 1
                $confidence = 'Exact'
                $method = 'resume-command'
            }
        }

        if (-not $sessionId) {
            $prior = $Previous | Where-Object {
                $_.tool -eq 'codex' -and [int] $_.pid -eq $processId -and $_.sessionId -and
                (Test-ProcessStartIdentity -Expected ([string] $_.processStart) -Actual $start)
            } | Select-Object -First 1
            if ($prior) {
                $sessionId = [string] $prior.sessionId
                $matched = $catalog | Where-Object Id -eq $sessionId | Select-Object -First 1
                $confidence = 'Tracked'
                $method = 'prior-inventory'
            }
        }

        if (-not $sessionId) {
            $candidates = @($catalog |
                Where-Object { $_.StartedAt -and -not $usedIds.Contains($_.Id) } |
                ForEach-Object {
                    [pscustomobject]@{ Entry = $_; Distance = [math]::Abs(($_.StartedAt - $start).TotalSeconds) }
                })
            $winner = Select-UniqueLowestDistance -Candidates $candidates -WindowSeconds 600
            if ($winner) {
                $matched = $winner.Entry
                $sessionId = $matched.Id
                $confidence = 'High'
                $method = 'start-time'
            }
        }

        if ($sessionId) { $null = $usedIds.Add($sessionId) }
        $cwd = if ($matched) { [string] $matched.Cwd } else { '' }
        $name = if ($sessionId -and $nameMap.ContainsKey($sessionId)) { $nameMap[$sessionId] } else { '' }

        [pscustomobject][ordered]@{
            tool = 'codex'
            pid = $processId
            parentPid = [int] $process.ParentProcessId
            processStart = $start.ToString('o')
            lastActivity = $(if ($matched) { $matched.LastWriteTime.ToString('o') } else { $start.ToString('o') })
            sessionId = $sessionId
            name = $name
            cwd = $cwd
            confidence = $confidence
            matchMethod = $method
            sessionFile = if ($matched) { $matched.Path } else { '' }
            command = $script:CodexCommand
        }
    }
    return @($sessions)
}

function Get-ClaudeSessionHead {
    param([Parameter(Mandatory)] [IO.FileInfo] $File)

    $sessionId = $File.BaseName
    $cwd = ''
    $startedAt = $null
    $count = 0
    foreach ($line in [IO.File]::ReadLines($File.FullName)) {
        $count++
        try {
            $item = $line | ConvertFrom-Json
            if ($item.sessionId) { $sessionId = [string] $item.sessionId }
            if ($item.cwd) { $cwd = [string] $item.cwd }
            if (-not $startedAt -and $item.timestamp) {
                $startedAt = ConvertTo-LocalDateTime $item.timestamp
            }
        }
        catch { }
        if ($sessionId -and $cwd) { break }
        if ($count -ge 80) { break }
    }

    return [pscustomobject]@{
        Id = $sessionId
        Cwd = $cwd
        Path = $File.FullName
        StartedAt = $startedAt
        CreationTime = $File.CreationTime
        LastWriteTime = $File.LastWriteTime
    }
}

function Get-ClaudeSessions {
    param(
        [object[]] $Processes,
        [object[]] $Previous
    )

    if (-not $script:ClaudeCommand) {
        return @()
    }
    $claudePath = [IO.Path]::GetFullPath($script:ClaudeCommand)
    $native = @($Processes | Where-Object {
        $_.Name -ieq 'claude.exe' -and $_.ExecutablePath -and
        [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $claudePath
    })
    if ($native.Count -eq 0) {
        return @()
    }

    $projectRoot = Join-Path $ClaudeHome 'projects'
    $catalog = @()
    if (Test-Path -LiteralPath $projectRoot) {
        $catalog = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Filter '*.jsonl' |
            Where-Object { $_.BaseName -notlike 'agent-*' } |
            ForEach-Object { Get-ClaudeSessionHead -File $_ })
    }

    $usedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sessions = foreach ($process in $native) {
        $processId = [int] $process.ProcessId
        $start = [datetime] $process.CreationDate
        $runtimePath = Join-Path (Join-Path $ClaudeHome 'sessions') "$processId.json"
        $runtime = $null
        $matched = $null
        $sessionId = $null
        $name = ''
        $cwd = ''
        $confidence = 'Unmapped'
        $method = 'none'

        if (Test-Path -LiteralPath $runtimePath) {
            try {
                $runtime = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json
                if ([int] $runtime.pid -eq $processId -and $runtime.sessionId) {
                    $sessionId = [string] $runtime.sessionId
                    $cwd = [string] $runtime.cwd
                    $name = [string] $runtime.name
                    $matched = $catalog | Where-Object Id -eq $sessionId | Select-Object -First 1
                    $confidence = 'Exact'
                    $method = 'runtime-metadata'
                }
            }
            catch { }
        }

        if (-not $sessionId) {
            $sessionId = Get-ResumeIdFromCommandLine $process.CommandLine
            if ($sessionId) {
                $matched = $catalog | Where-Object Id -eq $sessionId | Select-Object -First 1
                $confidence = 'Exact'
                $method = 'resume-command'
            }
        }

        if (-not $sessionId) {
            $prior = $Previous | Where-Object {
                $_.tool -eq 'claude' -and [int] $_.pid -eq $processId -and $_.sessionId -and
                (Test-ProcessStartIdentity -Expected ([string] $_.processStart) -Actual $start)
            } | Select-Object -First 1
            if ($prior) {
                $sessionId = [string] $prior.sessionId
                $cwd = [string] $prior.cwd
                $name = [string] $prior.name
                $matched = $catalog | Where-Object Id -eq $sessionId | Select-Object -First 1
                $confidence = 'Tracked'
                $method = 'prior-inventory'
            }
        }

        if (-not $sessionId) {
            $candidates = @()
            foreach ($entry in $catalog | Where-Object { $_.StartedAt -and -not $usedIds.Contains($_.Id) }) {
                $distance = [math]::Abs(($entry.StartedAt - $start).TotalSeconds)
                $candidates += [pscustomobject]@{ Entry = $entry; Distance = $distance }
            }
            $winner = Select-UniqueLowestDistance -Candidates $candidates -WindowSeconds 180
            if ($winner) {
                $matched = $winner.Entry
                $sessionId = $matched.Id
                $cwd = $matched.Cwd
                $confidence = 'High'
                $method = 'journal-start-time'
            }
        }

        if ($matched -and -not $cwd) { $cwd = $matched.Cwd }
        if (-not $name -and $cwd) { $name = Split-Path -Leaf $cwd }
        if ($sessionId) { $null = $usedIds.Add($sessionId) }

        [pscustomobject][ordered]@{
            tool = 'claude'
            pid = $processId
            parentPid = [int] $process.ParentProcessId
            processStart = $start.ToString('o')
            lastActivity = $(if ($matched) { $matched.LastWriteTime.ToString('o') } else { $start.ToString('o') })
            sessionId = $sessionId
            name = $name
            cwd = $cwd
            confidence = $confidence
            matchMethod = $method
            sessionFile = if ($matched) { $matched.Path } else { '' }
            command = $script:ClaudeCommand
        }
    }
    return @($sessions)
}

function Get-DeepCodeSessionCatalog {
    $root = Join-Path $DeepCodeHome 'projects'
    if (-not (Test-Path -LiteralPath $root -PathType Container -ErrorAction SilentlyContinue)) {
        return @()
    }

    $resolvedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    $byId = [ordered]@{}
    foreach ($project in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        $indexPath = Join-Path $project.FullName 'sessions-index.json'
        if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { continue }
        try { $fullIndex = [IO.Path]::GetFullPath($indexPath) }
        catch { continue }
        if (-not $fullIndex.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }

        try { $index = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json }
        catch { continue }
        $cwd = if ($index.PSObject.Properties['originalPath'] -and $index.originalPath) {
            [string] $index.originalPath
        }
        else { '' }
        $indexFile = Get-Item -LiteralPath $indexPath
        if (-not $index.PSObject.Properties['entries']) { continue }

        foreach ($entry in @($index.entries)) {
            if (-not $entry.PSObject.Properties['id'] -or -not $entry.id) { continue }
            $sessionId = [string] $entry.id
            if ($sessionId -notmatch ('^{0}$' -f $script:UuidPattern)) { continue }

            $name = ''
            if ($entry.PSObject.Properties['summary'] -and $entry.summary) {
                $name = [string] $entry.summary
            }
            if ($name.Length -gt 200) { $name = $name.Substring(0, 197) + '...' }

            $createdValue = if ($entry.PSObject.Properties['createTime']) { $entry.createTime } else { $null }
            $updatedValue = if ($entry.PSObject.Properties['updateTime']) { $entry.updateTime } else { $null }
            $created = ConvertTo-LocalDateTime $createdValue
            $updated = ConvertTo-LocalDateTime $updatedValue
            if (-not $created) { $created = $indexFile.CreationTime }
            if (-not $updated) { $updated = $created }

            $byId[$sessionId] = [pscustomobject][ordered]@{
                tool = 'deepcode'
                sessionId = $sessionId
                name = $name
                cwd = $cwd
                confidence = 'Catalog'
                matchMethod = 'local-session-index'
                firstSeen = $created.ToString('o')
                lastActivity = $updated.ToString('o')
                UpdatedAt = $updated
                sessionFile = $indexPath
            }
        }
    }
    return @($byId.Values)
}

function Get-DeepCodeSessions {
    param(
        [object[]] $Processes,
        [object[]] $Previous,
        [object[]] $Catalog
    )

    $running = @($Processes | Where-Object {
        $_.Name -ieq 'node.exe' -and $_.CommandLine -match '(?i)(@vegamo[\\/]deepcode-cli|deepcode-cli[\\/]cli\.js)'
    })
    if ($running.Count -eq 0) {
        return @()
    }

    $index = @($Catalog)
    $usedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sessions = foreach ($process in $running) {
        $processId = [int] $process.ProcessId
        $start = [datetime] $process.CreationDate
        $sessionId = Get-ResumeIdFromCommandLine $process.CommandLine
        $confidence = if ($sessionId) { 'Exact' } else { 'Unmapped' }
        $method = if ($sessionId) { 'resume-command' } else { 'none' }

        if (-not $sessionId) {
            $prior = $Previous | Where-Object {
                $_.tool -eq 'deepcode' -and [int] $_.pid -eq $processId -and $_.sessionId -and
                (Test-ProcessStartIdentity -Expected ([string] $_.processStart) -Actual $start)
            } | Select-Object -First 1
            if ($prior) {
                $sessionId = [string] $prior.sessionId
                $confidence = 'Tracked'
                $method = 'prior-inventory'
            }
        }

        if (-not $sessionId) {
            $candidates = @($index | Where-Object { $_.UpdatedAt -and -not $usedIds.Contains($_.sessionId) } |
                ForEach-Object {
                    [pscustomobject]@{ Entry = $_; Distance = [math]::Abs(($_.UpdatedAt - $start).TotalSeconds) }
                })
            $winner = Select-UniqueLowestDistance -Candidates $candidates -WindowSeconds 600
            if ($winner) {
                $sessionId = $winner.Entry.sessionId
                $confidence = 'High'
                $method = 'start-time'
            }
        }

        if ($sessionId) { $null = $usedIds.Add($sessionId) }
        $matched = $index | Where-Object sessionId -eq $sessionId | Select-Object -First 1
        [pscustomobject][ordered]@{
            tool = 'deepcode'
            pid = $processId
            parentPid = [int] $process.ParentProcessId
            processStart = $start.ToString('o')
            lastActivity = $(if ($matched -and $matched.UpdatedAt) { $matched.UpdatedAt.ToString('o') } else { $start.ToString('o') })
            sessionId = $sessionId
            name = if ($matched) { [string] $matched.name } else { '' }
            cwd = if ($matched) { [string] $matched.cwd } else { '' }
            confidence = $confidence
            matchMethod = $method
            sessionFile = if ($matched) { [string] $matched.sessionFile } else { '' }
            command = $script:DeepCodeCommand
        }
    }
    return @($sessions)
}

function Get-GrokSessionCatalog {
    $root = Join-Path $GrokHome 'sessions'
    if (-not (Test-Path -LiteralPath $root -PathType Container -ErrorAction SilentlyContinue)) {
        return @()
    }

    $catalog = [Collections.Generic.List[object]]::new()
    foreach ($workspace in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        $cwd = [Uri]::UnescapeDataString($workspace.Name)
        foreach ($sessionDir in Get-ChildItem -LiteralPath $workspace.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match ('^{0}$' -f $script:UuidPattern) }) {
            $summaryPath = Join-Path $sessionDir.FullName 'summary.json'
            $summary = $null
            if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
                try { $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json }
                catch { }
            }

            $activity = $sessionDir.LastWriteTime
            $created = $sessionDir.CreationTime
            $name = ''
            if ($summary) {
                if ($summary.PSObject.Properties['generated_title'] -and $summary.generated_title) {
                    $name = [string] $summary.generated_title
                }
                $activityValue = if ($summary.PSObject.Properties['last_active_at']) {
                    $summary.last_active_at
                }
                elseif ($summary.PSObject.Properties['updated_at']) { $summary.updated_at }
                else { $null }
                $parsedActivity = ConvertTo-LocalDateTime $activityValue
                if ($parsedActivity) { $activity = $parsedActivity }
                $createdValue = if ($summary.PSObject.Properties['created_at']) { $summary.created_at } else { $null }
                $parsedCreated = ConvertTo-LocalDateTime $createdValue
                if ($parsedCreated) { $created = $parsedCreated }
            }

            $catalog.Add([pscustomobject][ordered]@{
                tool = 'grok'
                sessionId = $sessionDir.Name
                name = $name
                cwd = $cwd
                confidence = 'Catalog'
                matchMethod = 'local-session-summary'
                firstSeen = $created.ToString('o')
                lastActivity = $activity.ToString('o')
                sessionFile = $(if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { $summaryPath } else { '' })
            })
        }
    }
    return @($catalog)
}

function Get-GrokSessions {
    param(
        [object[]] $Processes,
        [object[]] $Catalog
    )

    if (-not $script:GrokCommand) { return @() }
    $grokPath = [IO.Path]::GetFullPath($script:GrokCommand)
    $running = @($Processes | Where-Object {
        $_.Name -ieq 'grok.exe' -and $_.ExecutablePath -and
        [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $grokPath
    })
    if ($running.Count -eq 0) { return @() }

    $activeByPid = @{}
    $activePath = Join-Path $GrokHome 'active_sessions.json'
    if (Test-Path -LiteralPath $activePath -PathType Leaf) {
        try {
            foreach ($record in @(Get-Content -Raw -LiteralPath $activePath | ConvertFrom-Json)) {
                if ($record.pid) { $activeByPid[[int] $record.pid] = $record }
            }
        }
        catch { }
    }

    $sessions = foreach ($process in $running) {
        $processId = [int] $process.ProcessId
        $start = [datetime] $process.CreationDate
        $record = if ($activeByPid.ContainsKey($processId)) { $activeByPid[$processId] } else { $null }
        $sessionId = if ($record -and $record.session_id) { [string] $record.session_id } else { $null }
        $matched = if ($sessionId) { $Catalog | Where-Object sessionId -eq $sessionId | Select-Object -First 1 } else { $null }

        [pscustomobject][ordered]@{
            tool = 'grok'
            pid = $processId
            parentPid = [int] $process.ParentProcessId
            processStart = $start.ToString('o')
            lastActivity = $(if ($matched) { [string] $matched.lastActivity } else { $start.ToString('o') })
            sessionId = $sessionId
            name = $(if ($matched) { [string] $matched.name } else { '' })
            cwd = $(if ($record -and $record.cwd) { [string] $record.cwd } elseif ($matched) { [string] $matched.cwd } else { '' })
            confidence = $(if ($sessionId) { 'Exact' } else { 'Unmapped' })
            matchMethod = $(if ($sessionId) { 'vendor-active-registry' } else { 'none' })
            sessionFile = $(if ($matched) { [string] $matched.sessionFile } else { '' })
            command = $script:GrokCommand
        }
    }
    return @($sessions)
}

function Get-KimiSessionCatalog {
    $indexPath = Join-Path $KimiHome 'session_index.jsonl'
    $sessionRoot = Join-Path $KimiHome 'sessions'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf -ErrorAction SilentlyContinue) -or
        -not (Test-Path -LiteralPath $sessionRoot -PathType Container -ErrorAction SilentlyContinue)) {
        return @()
    }

    $resolvedRoot = [IO.Path]::GetFullPath($sessionRoot).TrimEnd('\') + '\'
    $byId = [ordered]@{}
    foreach ($line in [IO.File]::ReadLines($indexPath)) {
        try { $record = $line | ConvertFrom-Json }
        catch { continue }
        if (-not $record.sessionId -or -not $record.sessionDir) { continue }

        $sessionId = [string] $record.sessionId
        if ($sessionId -notmatch ('^{0}$' -f $script:KimiIdPattern)) { continue }
        try { $sessionDir = [IO.Path]::GetFullPath([string] $record.sessionDir) }
        catch { continue }
        if (-not $sessionDir.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }

        $statePath = Join-Path $sessionDir 'state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
        try { $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json }
        catch { continue }

        $stateFile = Get-Item -LiteralPath $statePath
        $cwd = if ($state.PSObject.Properties['cwd'] -and $state.cwd) {
            [string] $state.cwd
        }
        else { [string] $record.workDir }
        $name = if ($state.PSObject.Properties['title'] -and $state.title) {
            [string] $state.title
        }
        else { '' }
        if ($name.Length -gt 200) { $name = $name.Substring(0, 197) + '...' }

        $createdValue = if ($state.PSObject.Properties['createdAt']) { $state.createdAt } else { $null }
        $updatedValue = if ($state.PSObject.Properties['updatedAt']) { $state.updatedAt } else { $null }
        $created = ConvertTo-LocalDateTime $createdValue
        $activity = ConvertTo-LocalDateTime $updatedValue
        if (-not $created) { $created = $stateFile.CreationTime }
        if (-not $activity) { $activity = $stateFile.LastWriteTime }

        $byId[$sessionId] = [pscustomobject][ordered]@{
            tool = 'kimi'
            sessionId = $sessionId
            name = $name
            cwd = $cwd
            confidence = 'Catalog'
            matchMethod = 'local-session-index'
            firstSeen = $created.ToString('o')
            lastActivity = $activity.ToString('o')
            sessionFile = $statePath
            wirePath = (Join-Path $sessionDir 'agents\main\wire.jsonl')
        }
    }
    return @($byId.Values)
}

function Get-KimiResumeIdFromCommandLine {
    param([string] $CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    if ($CommandLine -match ('(?i)(?:--session|--resume|-S|-r)\s+["'']?({0})' -f $script:KimiIdPattern)) {
        return $Matches[1]
    }
    return $null
}

function Get-KimiSessions {
    param(
        [object[]] $Processes,
        [object[]] $Previous,
        [object[]] $Catalog
    )

    if (-not $script:KimiCommand) { return @() }
    $kimiPath = [IO.Path]::GetFullPath($script:KimiCommand)
    $running = @($Processes | Where-Object {
        $_.Name -ieq 'kimi.exe' -and $_.ExecutablePath -and
        [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $kimiPath
    })
    if ($running.Count -eq 0) { return @() }

    $lockCandidates = @{}
    foreach ($entry in $Catalog | Where-Object { $_.wirePath -and (Test-Path -LiteralPath $_.wirePath -PathType Leaf) }) {
        foreach ($lockerProcessId in Get-FileLockerPids -Path $entry.wirePath) {
            if (-not $lockCandidates.ContainsKey($lockerProcessId)) {
                $lockCandidates[$lockerProcessId] = [Collections.Generic.List[object]]::new()
            }
            $lockCandidates[$lockerProcessId].Add($entry)
        }
    }

    $sessions = foreach ($process in $running) {
        $processId = [int] $process.ProcessId
        $start = [datetime] $process.CreationDate
        $sessionId = Get-KimiResumeIdFromCommandLine $process.CommandLine
        $matched = if ($sessionId) { $Catalog | Where-Object sessionId -eq $sessionId | Select-Object -First 1 } else { $null }
        $confidence = if ($sessionId) { 'Exact' } else { 'Unmapped' }
        $method = if ($sessionId) { 'resume-command' } else { 'none' }

        if (-not $sessionId -and $lockCandidates.ContainsKey($processId) -and
            $lockCandidates[$processId].Count -eq 1) {
            $matched = $lockCandidates[$processId][0]
            $sessionId = $matched.sessionId
            $confidence = 'Exact'
            $method = 'wire-lock'
        }

        if (-not $sessionId) {
            $prior = $Previous | Where-Object {
                $_.tool -eq 'kimi' -and [int] $_.pid -eq $processId -and $_.sessionId -and
                (Test-ProcessStartIdentity -Expected ([string] $_.processStart) -Actual $start)
            } | Select-Object -First 1
            if ($prior) {
                $sessionId = [string] $prior.sessionId
                $matched = $Catalog | Where-Object sessionId -eq $sessionId | Select-Object -First 1
                $confidence = 'Tracked'
                $method = 'prior-inventory'
            }
        }

        if (-not $sessionId) {
            $candidates = @($Catalog | Where-Object firstSeen | ForEach-Object {
                $created = ConvertTo-LocalDateTime $_.firstSeen
                if ($created) {
                    [pscustomobject]@{
                        Entry = $_
                        Distance = [math]::Abs(($created - $start).TotalSeconds)
                    }
                }
            })
            $winner = Select-UniqueLowestDistance -Candidates $candidates -WindowSeconds 600
            if ($winner) {
                $matched = $winner.Entry
                $sessionId = $matched.sessionId
                $confidence = 'High'
                $method = 'session-start-time'
            }
        }

        [pscustomobject][ordered]@{
            tool = 'kimi'
            pid = $processId
            parentPid = [int] $process.ParentProcessId
            processStart = $start.ToString('o')
            lastActivity = $(if ($matched) { [string] $matched.lastActivity } else { $start.ToString('o') })
            sessionId = $sessionId
            name = $(if ($matched) { [string] $matched.name } else { '' })
            cwd = $(if ($matched) { [string] $matched.cwd } else { '' })
            confidence = $confidence
            matchMethod = $method
            sessionFile = $(if ($matched) { [string] $matched.sessionFile } else { '' })
            command = $script:KimiCommand
        }
    }
    return @($sessions)
}

function Save-Inventory {
    param([object[]] $Sessions)

    Initialize-StateRoot
    $payload = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString('o')
        machine = $env:COMPUTERNAME
        sessions = @($Sessions)
    }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:InventoryPath -Encoding utf8
}

function Get-Inventory {
    $previous = @(Get-PreviousSessions)
    $processes = @(Get-ProcessRecords)
    $grokCatalog = @(Get-GrokSessionCatalog)
    $kimiCatalog = @(Get-KimiSessionCatalog)
    $deepCodeCatalog = @(Get-DeepCodeSessionCatalog)
    $sessions = @()
    $sessions += @(Get-CodexSessions -Processes $processes -Previous $previous)
    $sessions += @(Get-ClaudeSessions -Processes $processes -Previous $previous)
    $sessions += @(Get-GrokSessions -Processes $processes -Catalog $grokCatalog)
    $sessions += @(Get-KimiSessions -Processes $processes -Previous $previous -Catalog $kimiCatalog)
    $sessions += @(Get-DeepCodeSessions -Processes $processes -Previous $previous -Catalog $deepCodeCatalog)
    Save-Inventory -Sessions $sessions
    Update-SessionRegistry -Sessions $sessions -CatalogSessions @($grokCatalog + $kimiCatalog + $deepCodeCatalog) -Path $script:RegistryPath
    Add-HistoryRecord -Event 'scan' -Data @{ count = $sessions.Count }
    return $sessions
}

function Show-Dashboard {
    $null = @(Get-Inventory)
    $path = New-SessionDashboard -RegistryPath $script:RegistryPath -OutputPath $script:DashboardPath
    Write-Host "Session dashboard refreshed: $path" -ForegroundColor Green
    if (-not $NoOpen) {
        Start-Process -FilePath $path | Out-Null
    }
    else {
        Write-Output $path
    }
}

function Show-Sessions {
    param([object[]] $Sessions)

    if ($Sessions.Count -eq 0) {
        Write-Host 'No running supported CLI sessions were found.' -ForegroundColor Yellow
        return
    }

    $number = 0
    $rows = foreach ($item in $Sessions) {
        $number++
        [pscustomobject]@{
            No = $number
            Tool = $item.tool
            Name = $item.name
            Session = $item.sessionId
            PID = $item.pid
            Match = $item.confidence
            Directory = $item.cwd
        }
    }
    $rows | Format-Table -AutoSize -Wrap
}

function Get-NpmPackageStatus {
    param(
        [Parameter(Mandatory)] [string] $Tool,
        [Parameter(Mandatory)] [string] $Package
    )

    if (-not $script:NpmCommand) {
        return [pscustomobject]@{ Tool=$Tool; Installed='No'; Current=''; Latest=''; Pending='Unknown'; Note='npm.cmd not found' }
    }

    $rootOutput = & $script:NpmCommand root -g 2>$null
    $root = (@($rootOutput) | Select-Object -Last 1).Trim()
    $packageJson = Join-Path (Join-Path $root $Package) 'package.json'
    if (-not (Test-Path -LiteralPath $packageJson)) {
        return [pscustomobject]@{ Tool=$Tool; Installed='No'; Current=''; Latest=''; Pending='No'; Note=$Package }
    }

    $current = (Get-Content -Raw -LiteralPath $packageJson | ConvertFrom-Json).version
    $latestOutput = & $script:NpmCommand view $Package version --json 2>$null
    $latest = ''
    if ($LASTEXITCODE -eq 0 -and $latestOutput) {
        try { $latest = [string] (($latestOutput -join "`n") | ConvertFrom-Json) }
        catch { $latest = [string] (@($latestOutput) | Select-Object -Last 1) }
    }
    $pending = if (-not $latest) { 'Unknown' } elseif ($current -eq $latest) { 'No' } else { 'Yes' }
    return [pscustomobject]@{ Tool=$Tool; Installed='Yes'; Current=$current; Latest=$latest; Pending=$pending; Note=$Package }
}

function Get-UpdateStatus {
    $rows = @()
    $rows += Get-NpmPackageStatus -Tool 'Codex' -Package '@openai/codex'
    $rows += Get-NpmPackageStatus -Tool 'DeepCode' -Package '@vegamo/deepcode-cli'

    if ($script:ClaudeCommand -and (Test-Path -LiteralPath $script:ClaudeCommand)) {
        $versionOutput = & $script:ClaudeCommand --version 2>$null
        $version = [string] (@($versionOutput) | Select-Object -First 1)
        $rows += [pscustomobject]@{
            Tool = 'Claude Code'
            Installed = 'Yes'
            Current = $version
            Latest = 'native latest channel'
            Pending = 'Checked by claude update'
            Note = 'Native installer'
        }
    }
    else {
        $rows += [pscustomobject]@{ Tool='Claude Code'; Installed='No'; Current=''; Latest=''; Pending='No'; Note=$script:ClaudeCommand }
    }

    if ($script:GrokCommand -and (Test-Path -LiteralPath $script:GrokCommand)) {
        $versionOutput = & $script:GrokCommand --no-auto-update version 2>$null
        $version = [string] (@($versionOutput) | Select-Object -First 1)
        $rows += [pscustomobject]@{
            Tool = 'Grok'
            Installed = 'Yes'
            Current = $version
            Latest = 'native stable channel'
            Pending = 'Checked by grok update'
            Note = 'Native installer'
        }
    }
    else {
        $rows += [pscustomobject]@{ Tool='Grok'; Installed='No'; Current=''; Latest=''; Pending='No'; Note=$script:GrokCommand }
    }

    if ($script:KimiCommand -and (Test-Path -LiteralPath $script:KimiCommand)) {
        $priorNoAutoUpdate = [Environment]::GetEnvironmentVariable('KIMI_CODE_NO_AUTO_UPDATE', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('KIMI_CODE_NO_AUTO_UPDATE', '1', 'Process')
            $versionOutput = & $script:KimiCommand --version 2>$null
            $version = [string] (@($versionOutput) | Select-Object -First 1)
        }
        finally {
            [Environment]::SetEnvironmentVariable('KIMI_CODE_NO_AUTO_UPDATE', $priorNoAutoUpdate, 'Process')
        }
        $rows += [pscustomobject]@{
            Tool = 'Kimi Code'
            Installed = 'Yes'
            Current = $version
            Latest = 'native stable channel'
            Pending = 'Checked by kimi update'
            Note = 'Native installer'
        }
    }
    else {
        $rows += [pscustomobject]@{ Tool='Kimi Code'; Installed='No'; Current=''; Latest=''; Pending='No'; Note=$script:KimiCommand }
    }

    return $rows
}

function Show-UpdateStatus {
    Write-Host "`nUpdate status" -ForegroundColor Cyan
    Get-UpdateStatus | Format-Table -AutoSize -Wrap
}

function Show-Doctor {
    $rows = @(
        [pscustomobject]@{ Check='Operating system'; Value=[Environment]::OSVersion.VersionString; Ready=$IsWindows }
        [pscustomobject]@{ Check='PowerShell'; Value=$PSVersionTable.PSVersion.ToString(); Ready=($PSVersionTable.PSVersion.Major -ge 7) }
        [pscustomobject]@{ Check='Codex command'; Value=$script:CodexCommand; Ready=[bool] $script:CodexCommand }
        [pscustomobject]@{ Check='Claude command'; Value=$script:ClaudeCommand; Ready=[bool] $script:ClaudeCommand }
        [pscustomobject]@{ Check='Grok command'; Value=$script:GrokCommand; Ready=[bool] $script:GrokCommand }
        [pscustomobject]@{ Check='Kimi command'; Value=$script:KimiCommand; Ready=[bool] $script:KimiCommand }
        [pscustomobject]@{ Check='DeepCode command'; Value=$script:DeepCodeCommand; Ready=[bool] $script:DeepCodeCommand }
        [pscustomobject]@{ Check='npm command'; Value=$script:NpmCommand; Ready=[bool] $script:NpmCommand }
        [pscustomobject]@{ Check='Codex home'; Value=$CodexHome; Ready=(Test-Path -LiteralPath $CodexHome -PathType Container) }
        [pscustomobject]@{ Check='Claude home'; Value=$ClaudeHome; Ready=(Test-Path -LiteralPath $ClaudeHome -PathType Container) }
        [pscustomobject]@{ Check='Grok home'; Value=$GrokHome; Ready=(Test-Path -LiteralPath $GrokHome -PathType Container) }
        [pscustomobject]@{ Check='Kimi home'; Value=$KimiHome; Ready=(Test-Path -LiteralPath $KimiHome -PathType Container) }
        [pscustomobject]@{ Check='DeepCode home'; Value=$DeepCodeHome; Ready=(Test-Path -LiteralPath $DeepCodeHome -PathType Container) }
        [pscustomobject]@{ Check='State root'; Value=$StateRoot; Ready=(Test-Path -LiteralPath $StateRoot -PathType Container) }
    )
    Write-Host "Agent Session Continuity $script:Version`n" -ForegroundColor Cyan
    $rows | Format-Table -AutoSize -Wrap
}

function Assert-CoordinatorIndependent {
    param([object[]] $Sessions)

    $processes = @(Get-CimInstance Win32_Process)
    $byId = @{}
    foreach ($process in $processes) {
        $byId[[int] $process.ProcessId] = $process
    }

    $ancestors = [Collections.Generic.HashSet[int]]::new()
    $cursor = [int] $PID
    while ($byId.ContainsKey($cursor)) {
        $parentId = [int] $byId[$cursor].ParentProcessId
        if ($parentId -le 0 -or -not $ancestors.Add($parentId)) { break }
        $cursor = $parentId
    }

    $hosted = @($Sessions | Where-Object { $ancestors.Contains([int] $_.pid) })
    if ($hosted.Count -gt 0) {
        throw ('The updater is running inside a session it would stop (PID {0}). ' +
            'Launch AgentSessionContinuity.bat by double-clicking it in Explorer or from an independent PowerShell window.' -f
            ($hosted.pid -join ', '))
    }
}

function Get-ProcessTreePostOrder {
    param(
        [Parameter(Mandatory)] [int] $RootProcessId,
        [Parameter(Mandatory)] [object[]] $Processes
    )

    $result = [Collections.Generic.List[int]]::new()
    $visited = [Collections.Generic.HashSet[int]]::new()

    function Add-ProcessAndChildren {
        param([int] $CurrentProcessId)
        if (-not $visited.Add($CurrentProcessId)) { return }
        foreach ($child in $Processes | Where-Object { [int] $_.ParentProcessId -eq $CurrentProcessId }) {
            Add-ProcessAndChildren -CurrentProcessId ([int] $child.ProcessId)
        }
        $result.Add($CurrentProcessId)
    }

    Add-ProcessAndChildren -CurrentProcessId $RootProcessId
    return @($result)
}

function Stop-ManagedSessions {
    param([object[]] $Sessions)

    $duplicatePids = @($Sessions | Group-Object { [int] $_.pid } | Where-Object Count -gt 1)
    if ($duplicatePids.Count -gt 0) {
        throw "The inventory contains duplicate process IDs: $($duplicatePids.Name -join ', '). Nothing was stopped."
    }

    # Build and validate every process tree before terminating anything. Each
    # System.Diagnostics.Process object is forced to acquire a process handle;
    # that handle continues to identify the original process even if Windows
    # later reuses its numeric PID.
    $processes = @(Get-CimInstance Win32_Process)
    $byId = @{}
    foreach ($process in $processes) { $byId[[int] $process.ProcessId] = $process }
    $plans = [Collections.Generic.List[object]]::new()

    foreach ($item in $Sessions) {
        $rootId = [int] $item.pid
        if (-not $byId.ContainsKey($rootId)) {
            throw "PID $rootId exited after inventory. Nothing was stopped. Scan again."
        }
        if (-not (Test-ProcessStartIdentity -Expected ([string] $item.processStart) `
                -Actual ([datetime] $byId[$rootId].CreationDate))) {
            throw "PID $rootId no longer identifies the inventoried $($item.tool) process. Nothing was stopped. Scan again."
        }

        $targets = [Collections.Generic.List[object]]::new()
        foreach ($treeProcessId in @(Get-ProcessTreePostOrder -RootProcessId $rootId -Processes $processes)) {
            if ($treeProcessId -eq [int] $PID) {
                throw "Refusing to terminate the session-cycle coordinator itself (PID $PID)."
            }
            if (-not $byId.ContainsKey($treeProcessId)) {
                throw "Process tree changed while validating PID $rootId. Nothing was stopped. Scan again."
            }

            $live = Get-Process -Id $treeProcessId -ErrorAction SilentlyContinue
            if (-not $live) {
                throw "Process tree changed while validating PID $rootId. Nothing was stopped. Scan again."
            }
            $null = $live.SafeHandle
            $expectedStart = if ($treeProcessId -eq $rootId) {
                [string] $item.processStart
            }
            else {
                ([datetime] $byId[$treeProcessId].CreationDate).ToString('o')
            }
            if (-not (Test-ProcessStartIdentity -Expected $expectedStart -Actual $live.StartTime)) {
                throw "PID $treeProcessId changed identity while the stop plan was being validated. Nothing was stopped."
            }
            $targets.Add([pscustomobject]@{
                Process = $live
                ExpectedStart = $expectedStart
            })
        }
        $plans.Add([pscustomobject]@{ Session = $item; Targets = @($targets) })
    }

    foreach ($plan in $plans) {
        $item = $plan.Session
        Write-Host "Stopping $($item.tool) '$($item.name)' (PID $($item.pid))..."
        Write-Log "Stopping $($item.tool) session $($item.sessionId), PID $($item.pid)."
        foreach ($target in $plan.Targets) {
            if ($target.Process.HasExited) { continue }
            if (-not (Test-ProcessStartIdentity -Expected $target.ExpectedStart -Actual $target.Process.StartTime)) {
                throw "A validated process changed identity before termination. The remaining stop was aborted."
            }
            Stop-Process -InputObject $target.Process -Force -ErrorAction Stop
        }
    }

    $deadline = (Get-Date).AddSeconds(20)
    do {
        $remaining = @($plans | Where-Object {
            $root = $_.Targets | Select-Object -Last 1
            $root -and -not $root.Process.HasExited
        })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    if ($remaining.Count -gt 0) {
        throw "One or more validated session processes did not exit before the timeout."
    }
}

function Invoke-UpdateCommand {
    param(
        [Parameter(Mandatory)] [string] $Tool,
        [Parameter(Mandatory)] [string] $Executable,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    Write-Host "Updating $Tool..." -ForegroundColor Cyan
    Write-Log "Updating $Tool with $Executable $($Arguments -join ' ')."
    $output = & $Executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in @($output)) {
        Write-Host $line
        Add-Content -LiteralPath $script:LogPath -Value ([string] $line) -Encoding utf8
    }
    if ($exitCode -ne 0) {
        Write-Log "$Tool update failed with exit code $exitCode." 'ERROR'
        return $false
    }
    Write-Log "$Tool update succeeded."
    return $true
}

function Invoke-Updates {
    $results = [ordered]@{}
    if ($script:CodexCommand -and (Test-Path -LiteralPath $script:CodexCommand)) {
        $results.codex = Invoke-UpdateCommand -Tool 'Codex' -Executable $script:CodexCommand -Arguments @('update')
    }
    if ($script:ClaudeCommand -and (Test-Path -LiteralPath $script:ClaudeCommand)) {
        $results.claude = Invoke-UpdateCommand -Tool 'Claude Code' -Executable $script:ClaudeCommand -Arguments @('update')
    }
    if ($script:GrokCommand -and (Test-Path -LiteralPath $script:GrokCommand)) {
        $results.grok = Invoke-UpdateCommand -Tool 'Grok' -Executable $script:GrokCommand -Arguments @('update')
    }
    if ($script:KimiCommand -and (Test-Path -LiteralPath $script:KimiCommand)) {
        $results.kimi = Invoke-UpdateCommand -Tool 'Kimi Code' -Executable $script:KimiCommand -Arguments @('update', '-y')
    }
    if ($script:NpmCommand -and (Test-Path -LiteralPath $script:DeepCodeCommand)) {
        $results.deepcode = Invoke-UpdateCommand -Tool 'DeepCode' -Executable $script:NpmCommand -Arguments @('install', '-g', '@vegamo/deepcode-cli@latest')
    }
    return $results
}

function Refresh-ToolCommands {
    $script:CodexCommand = Resolve-ExecutablePath -Names @('codex.cmd', 'codex.exe', 'codex') -FallbackPaths @(
        $(if ($npmBin) { Join-Path $npmBin 'codex.cmd' })
    )
    $script:ClaudeCommand = Resolve-ExecutablePath -Names @('claude.exe', 'claude.cmd', 'claude') -FallbackPaths @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe')
    )
    $script:GrokCommand = Resolve-ExecutablePath -Names @('grok.exe', 'grok.cmd', 'grok') -FallbackPaths @(
        (Join-Path $GrokHome 'bin\grok.exe')
    )
    $script:KimiCommand = Resolve-ExecutablePath -Names @('kimi.exe', 'kimi.cmd', 'kimi') -FallbackPaths @(
        (Join-Path $KimiHome 'bin\kimi.exe')
    )
    $script:DeepCodeCommand = Resolve-ExecutablePath -Names @('deepcode.cmd', 'deepcode.exe', 'deepcode') -FallbackPaths @(
        $(if ($npmBin) { Join-Path $npmBin 'deepcode.cmd' })
    )
}

function Get-ToolCommandPath {
    param([Parameter(Mandatory)] [string] $Tool)

    switch ($Tool) {
        'codex' { return $script:CodexCommand }
        'claude' { return $script:ClaudeCommand }
        'grok' { return $script:GrokCommand }
        'kimi' { return $script:KimiCommand }
        'deepcode' { return $script:DeepCodeCommand }
        default { throw "No command resolver exists for tool '$Tool'." }
    }
}

function Get-RestartScript {
    param([Parameter(Mandatory)] $Item)

    $titleName = if ($Item.name) { $Item.name } else { $Item.sessionId }
    $title = "$($Item.tool): $titleName".Replace("'", "''")
    $exe = [string] (Get-ToolCommandPath -Tool $Item.tool)
    if (-not $exe) {
        throw "Cannot restart $($Item.tool): its command was not found after the update."
    }
    $quotedExe = $exe.Replace("'", "''")
    $quotedId = ([string] $Item.sessionId).Replace("'", "''")
    $lines = @(
        "`$Host.UI.RawUI.WindowTitle = '$title'"
    )
    switch ($Item.tool) {
        'codex' { $lines += "& '$quotedExe' resume '$quotedId'" }
        'claude' { $lines += "& '$quotedExe' --resume '$quotedId'" }
        'grok' { $lines += "& '$quotedExe' --resume '$quotedId'" }
        'kimi' { $lines += "& '$quotedExe' --session '$quotedId'" }
        'deepcode' { $lines += "& '$quotedExe' --resume '$quotedId'" }
        default { throw "No restart adapter exists for tool '$($Item.tool)'." }
    }
    return ($lines -join "`r`n")
}

function Start-SavedSession {
    param([Parameter(Mandatory)] $Item)

    if (-not $Item.sessionId) {
        throw "Cannot restart $($Item.tool) PID $($Item.pid): no session ID was mapped."
    }
    $toolCommand = Get-ToolCommandPath -Tool $Item.tool
    if (-not $toolCommand -or -not (Test-Path -LiteralPath $toolCommand)) {
        throw "Cannot restart $($Item.tool): its command is not installed or discoverable."
    }

    $cwd = [string] $Item.cwd
    if (-not $cwd -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
        $cwd = $env:USERPROFILE
    }
    $restartScript = Get-RestartScript -Item $Item
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($restartScript))
    Write-Host "Restarting $($Item.tool) '$($Item.name)' in $cwd..." -ForegroundColor Green
    Write-Log "Restarting $($Item.tool) session $($Item.sessionId) in $cwd."
    Start-Process -FilePath $script:PowerShellCommand `
        -ArgumentList @('-NoLogo', '-NoExit', '-NoProfile', '-EncodedCommand', $encoded) `
        -WorkingDirectory $cwd | Out-Null
    Start-Sleep -Seconds 1
}

function Start-AllSavedSessions {
    param([object[]] $Sessions)

    $failures = [Collections.Generic.List[object]]::new()
    $succeeded = 0
    foreach ($item in $Sessions) {
        try {
            Start-SavedSession -Item $item
            $succeeded++
        }
        catch {
            Write-Warning "Could not restart $($item.tool) '$($item.name)': $($_.Exception.Message)"
            Write-Log "Restart failed for $($item.tool) session $($item.sessionId): $($_.Exception.Message)" 'ERROR'
            $failures.Add([pscustomobject]@{
                tool = $item.tool
                sessionId = $item.sessionId
                message = $_.Exception.Message
            })
        }
    }
    return [pscustomobject]@{ succeeded = $succeeded; failures = @($failures) }
}

function Save-CyclePlan {
    param(
        [object[]] $Sessions,
        [string] $Status,
        $UpdateResults = $null,
        $RestartResults = $null
    )

    Initialize-StateRoot
    $plan = [ordered]@{
        schemaVersion = 1
        savedAt = (Get-Date).ToString('o')
        status = $Status
        sessions = @($Sessions)
        updates = $UpdateResults
        restarts = $RestartResults
    }
    $plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:CyclePath -Encoding utf8
}

function Invoke-Cycle {
    $sessions = @(Get-Inventory)
    Write-Host "`nSessions that will be stopped and resumed" -ForegroundColor Cyan
    Show-Sessions -Sessions $sessions
    Show-UpdateStatus

    $unmapped = @($sessions | Where-Object { -not $_.sessionId -or $_.confidence -eq 'Unmapped' })
    if ($unmapped.Count -gt 0) {
        Write-Host "`nCycle aborted: $($unmapped.Count) running session(s) could not be mapped safely." -ForegroundColor Red
        Write-Host 'Nothing was stopped. See the inventory file and name those sessions manually before adding an adapter.'
        exit 2
    }
    if ($sessions.Count -eq 0) {
        Write-Host 'No sessions need to be stopped. Updates can be run manually.' -ForegroundColor Yellow
        return
    }

    $duplicateSessions = @($sessions | Where-Object sessionId |
        Group-Object { "$($_.tool)|$($_.sessionId)" } | Where-Object Count -gt 1)
    if ($duplicateSessions.Count -gt 0) {
        Write-Host "`nCycle aborted: more than one process maps to the same durable session." -ForegroundColor Red
        Write-Host 'Nothing was stopped. Scan again after closing duplicate or ambiguous sessions.'
        exit 2
    }

    if (-not $Yes) {
        Write-Host "`nMake sure every agent is idle. An in-progress model turn will be interrupted." -ForegroundColor Yellow
        $answer = Read-Host "Type UPDATE to save the list, stop these sessions, update the CLIs, and reopen them"
        if ($answer -cne 'UPDATE') {
            Write-Host 'Cancelled. Nothing was stopped or updated.'
            return
        }
    }

    Save-CyclePlan -Sessions $sessions -Status 'captured'
    Add-SessionRegistryAction -Sessions $sessions -Path $script:RegistryPath -Text 'Queued for CLI update'
    Add-HistoryRecord -Event 'cycle-start' -Data @{ sessions = $sessions.Count }
    Assert-CoordinatorIndependent -Sessions $sessions
    Stop-ManagedSessions -Sessions $sessions
    Add-SessionRegistryAction -Sessions $sessions -Path $script:RegistryPath -Text 'Stopped for CLI update' -Active $false
    Save-CyclePlan -Sessions $sessions -Status 'stopped'

    $updateResults = Invoke-Updates
    Add-SessionRegistryAction -Sessions $sessions -Path $script:RegistryPath -Text 'CLI update stage completed' -Active $false
    Save-CyclePlan -Sessions $sessions -Status 'updated' -UpdateResults $updateResults
    Refresh-ToolCommands

    $restartResults = Start-AllSavedSessions -Sessions $sessions
    $failedIds = @($restartResults.failures | ForEach-Object { [string] $_.sessionId })
    $resumed = @($sessions | Where-Object { $failedIds -notcontains [string] $_.sessionId })
    $failed = @($sessions | Where-Object { $failedIds -contains [string] $_.sessionId })
    if ($resumed.Count -gt 0) {
        Add-SessionRegistryAction -Sessions $resumed -Path $script:RegistryPath -Text 'Resume window opened' -Active $false
    }
    if ($failed.Count -gt 0) {
        Add-SessionRegistryAction -Sessions $failed -Path $script:RegistryPath -Text 'Resume failed; manual recovery needed' -Active $false
    }
    $restartStatus = if ($restartResults.failures.Count -eq 0) { 'restarted' } else { 'restart-partial' }
    Save-CyclePlan -Sessions $sessions -Status $restartStatus -UpdateResults $updateResults -RestartResults $restartResults
    if ($restartResults.failures.Count -gt 0) {
        throw "$($restartResults.failures.Count) session(s) failed to restart; all saved sessions were attempted. See last-cycle.json."
    }
    Add-HistoryRecord -Event 'cycle-complete' -Data @{ sessions = $sessions.Count }
    Write-Host "`nCycle complete. New terminal windows were opened for all saved sessions." -ForegroundColor Green
}

function Get-SavedCycleSessions {
    if (-not (Test-Path -LiteralPath $script:CyclePath)) {
        throw "No saved cycle exists at $script:CyclePath"
    }
    $cycle = Get-Content -Raw -LiteralPath $script:CyclePath | ConvertFrom-Json
    return @($cycle.sessions)
}

function Resolve-SavedSession {
    param(
        [object[]] $Sessions,
        [Parameter(Mandatory)] [string] $Selector
    )

    $exact = @($Sessions | Where-Object {
        $_.sessionId -ieq $Selector -or $_.name -ieq $Selector
    })
    if ($exact.Count -eq 1) { return $exact[0] }
    if ($exact.Count -gt 1) { throw "'$Selector' exactly matches more than one saved session." }

    $number = 0
    if ([int]::TryParse($Selector, [ref] $number)) {
        if ($number -ge 1 -and $number -le $Sessions.Count) {
            return $Sessions[$number - 1]
        }
        throw "Session number must be between 1 and $($Sessions.Count)."
    }

    $partial = @($Sessions | Where-Object {
        $_.sessionId -like "$Selector*" -or $_.name -like "*$Selector*"
    })
    if ($partial.Count -eq 1) { return $partial[0] }
    if ($partial.Count -gt 1) { throw "'$Selector' matches more than one saved session." }
    throw "No saved session matches '$Selector'."
}

function Invoke-RestartSelection {
    $sessions = @(Get-SavedCycleSessions)
    Show-Sessions -Sessions $sessions
    $selector = $Session
    if (-not $selector) {
        $selector = Read-Host 'Enter a session number, full/partial UUID, or exact/partial name'
    }
    $item = Resolve-SavedSession -Sessions $sessions -Selector $selector
    Start-SavedSession -Item $item
    Add-SessionRegistryAction -Sessions @($item) -Path $script:RegistryPath -Text 'Manual resume window opened' -Active $false
}

function Show-Menu {
    while ($true) {
        Write-Host "`nCLI Session Cycle" -ForegroundColor Cyan
        Write-Host '  1. Check for updates'
        Write-Host '  2. Scan and save running sessions'
        Write-Host '  3. List last saved running-session inventory'
        Write-Host '  4. Cycle: save, stop, update, and restart'
        Write-Host '  5. Restart one session from the last cycle'
        Write-Host '  6. Doctor: show discovered commands and data roots'
        Write-Host '  7. Open the local session dashboard'
        Write-Host '  0. Exit'
        $choice = Read-Host 'Choose'
        switch ($choice) {
            '1' { Show-UpdateStatus }
            '2' { $items = @(Get-Inventory); Show-Sessions -Sessions $items; Write-Host "Saved to $script:InventoryPath" }
            '3' {
                if (Test-Path -LiteralPath $script:InventoryPath) {
                    $saved = Get-Content -Raw -LiteralPath $script:InventoryPath | ConvertFrom-Json
                    Show-Sessions -Sessions @($saved.sessions)
                }
                else { Write-Host 'No saved inventory yet.' -ForegroundColor Yellow }
            }
            '4' { Invoke-Cycle }
            '5' { Invoke-RestartSelection }
            '6' { Show-Doctor }
            '7' { Show-Dashboard }
            '0' { return }
            default { Write-Host 'Unknown choice.' -ForegroundColor Yellow }
        }
    }
}

Initialize-StateRoot
try {
    switch ($Action) {
        'menu' { Show-Menu }
        'check' { Show-UpdateStatus }
        'scan' {
            $items = @(Get-Inventory)
            Show-Sessions -Sessions $items
            Write-Host "`nSaved to $script:InventoryPath"
        }
        'list' {
            if (-not (Test-Path -LiteralPath $script:InventoryPath)) {
                throw 'No saved inventory exists. Run scan first.'
            }
            $saved = Get-Content -Raw -LiteralPath $script:InventoryPath | ConvertFrom-Json
            Show-Sessions -Sessions @($saved.sessions)
        }
        'cycle' { Invoke-Cycle }
        'restart' { Invoke-RestartSelection }
        'dashboard' { Show-Dashboard }
        'doctor' { Show-Doctor }
        'version' { Write-Output $script:Version }
    }
}
catch {
    Write-Log $_.Exception.ToString() 'ERROR'
    Write-Error $_
    exit 1
}
