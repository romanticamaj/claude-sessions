<#
.SYNOPSIS
    List all Claude Code sessions across all projects on Windows.

.DESCRIPTION
    Scans ~/.claude/projects/ for session data and displays a sorted table
    showing project path, session name (slug), last modified time, and first prompt.

    Usage:
      .\claude-sessions.ps1              # List 20 most recent sessions
      .\claude-sessions.ps1 -Count 50    # List 50 sessions
      .\claude-sessions.ps1 -Filter "suno"  # Filter by keyword
      .\claude-sessions.ps1 -Filter "suno,music"  # Filter by multiple keywords (OR)
      .\claude-sessions.ps1 -Resume      # Pick a session to resume
      .\claude-sessions.ps1 -Continue    # Resume most recent session immediately
      .\claude-sessions.ps1 -All         # Include empty/aborted sessions
      .\claude-sessions.ps1 -Cleanup 30  # Delete sessions older than 30 days
      .\claude-sessions.ps1 -Search "error handling"  # Full-text search in transcripts
      .\claude-sessions.ps1 -Preview 5   # Show last 5 exchanges when resuming
      .\claude-sessions.ps1 -IncludeForks  # Show forked sessions
      .\claude-sessions.ps1 -Resume -ResumeArgs "--model opus"  # Pass extra flags to claude
#>

param(
    [int]$Count = 20,
    [string]$Filter = "",
    [string]$Search = "",
    [switch]$Resume,
    [switch]$Continue,
    [switch]$All,
    [switch]$ShowDebug,
    [switch]$IncludeForks,
    [int]$Cleanup = 0,
    [int]$Preview = 0,
    [string]$ResumeArgs = ""
)

# -- Paths -------------------------------------------------------------------
$claudeDir = Join-Path $env:USERPROFILE ".claude"
$projectsDir = Join-Path $claudeDir "projects"

if (-not (Test-Path $projectsDir)) {
    Write-Host "[X] No Claude Code projects found at: $projectsDir" -ForegroundColor Red
    Write-Host "    Make sure you've used Claude Code at least once." -ForegroundColor DarkGray
    exit 1
}

# -- Helpers -----------------------------------------------------------------
function Extract-MessageContent {
    param($MessageObj)
    $msgContent = ""
    if ($MessageObj.content -is [string]) {
        $msgContent = $MessageObj.content
    }
    elseif ($MessageObj.content -is [System.Array]) {
        foreach ($block in $MessageObj.content) {
            if ($block.type -eq "text" -and $block.text) {
                $msgContent = $block.text
                break
            }
        }
    }
    return $msgContent
}

function Clean-MessageText {
    param([string]$Text, [int]$MaxLen = 80)
    $cleaned = $Text -replace '<[^>]+>', '' -replace '[\r\n]+', ' ' -replace '\s+', ' '
    $cleaned = $cleaned.Trim()
    if ($MaxLen -gt 0 -and $cleaned.Length -gt $MaxLen) {
        $cleaned = $cleaned.Substring(0, $MaxLen - 1) + [char]0x2026
    }
    return $cleaned
}

function Decode-FolderName {
    param([string]$FolderName)
    if ($FolderName -match '^([A-Za-z])--(.+)$') {
        $drive = $Matches[1].ToUpper()
        $rest = $Matches[2] -replace '-', '\'
        return "${drive}:\${rest}"
    }
    return $FolderName
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -lt 1KB) { return "${Bytes}B" }
    if ($Bytes -lt 1MB) { return "$([Math]::Round($Bytes / 1KB, 0))K" }
    if ($Bytes -lt 1GB) { return "$([Math]::Round($Bytes / 1MB, 1))M" }
    return "$([Math]::Round($Bytes / 1GB, 1))G"
}

function Format-RelativeTime {
    param([DateTime]$Time)
    $diff = (Get-Date) - $Time
    if ($diff.TotalMinutes -lt 1)  { return "just now" }
    if ($diff.TotalMinutes -lt 60) { return "$([int]$diff.TotalMinutes)m ago" }
    if ($diff.TotalHours -lt 24)   { return "$([int]$diff.TotalHours)h ago" }
    if ($diff.TotalDays -lt 30)    { return "$([int]$diff.TotalDays)d ago" }
    return $Time.ToString("yyyy-MM-dd")
}

function Shorten-Path {
    param([string]$FullPath, [int]$MaxLen = 25)
    $short = $FullPath -replace [regex]::Escape($env:USERPROFILE), '~'
    if ($short.Length -gt $MaxLen) {
        $parts = $short -split '[\\\/]'
        if ($parts.Count -gt 3) {
            $short = "$($parts[0])\...\$($parts[-2])\$($parts[-1])"
        }
        if ($short.Length -gt $MaxLen) {
            $short = ".." + $short.Substring($short.Length - $MaxLen + 2)
        }
    }
    return $short
}

# -- Parse a .jsonl: extract cwd, slug, first/last user message, /rename, stats, fork --
function Parse-SessionJsonl {
    param([string]$FilePath)

    $result = @{
        Cwd = $null; Summary = $null; LastActivity = $null
        Name = $null; Slug = $null; UserTurns = 0
        ForkedFrom = $null
    }
    if (-not (Test-Path $FilePath)) { return $result }

    try {
        # Read head (first 200 lines) for cwd, slug, first prompt, fork info
        $headLines = Get-Content $FilePath -TotalCount 200 -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($line in $headLines) {
            if (-not $line) { continue }
            try {
                $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                if (-not $obj) { continue }

                if (-not $result.Slug -and $obj.slug) {
                    $result.Slug = $obj.slug
                }

                # Detect fork relationship
                if (-not $result.ForkedFrom -and $obj.forkedFrom -and $obj.forkedFrom.sessionId) {
                    $result.ForkedFrom = $obj.forkedFrom.sessionId
                }

                if ($obj.type -eq "user" -and $obj.message) {
                    $result.UserTurns++

                    if (-not $result.Cwd -and $obj.cwd) {
                        $result.Cwd = $obj.cwd
                    }

                    $msgContent = Extract-MessageContent $obj.message

                    # Check for /rename
                    if ($msgContent -match '<command-name>/rename</command-name>\s*<command-args>([^<]+)</command-args>') {
                        $result.Name = $Matches[1].Trim()
                    }
                    elseif ($msgContent -match '^\s*/rename\s+(.+)') {
                        $result.Name = $Matches[1].Trim()
                    }

                    # First real user message as summary
                    if (-not $result.Summary -and $msgContent.Length -gt 0) {
                        $cleaned = Clean-MessageText $msgContent 80
                        if ($cleaned.Length -gt 0 -and $cleaned -notmatch '^/\w+') {
                            $result.Summary = $cleaned
                        }
                    }
                }
            }
            catch { continue }
        }

        # Read tail for last activity, late /rename, and remaining turn count
        # Use Get-Content -Tail for efficiency (avoids loading entire file)
        $tailLines = Get-Content $FilePath -Tail 100 -Encoding UTF8 -ErrorAction SilentlyContinue

        # Count remaining user turns via streaming (skip first 200 already counted)
        $lineNum = 0
        foreach ($line in [System.IO.File]::ReadLines($FilePath)) {
            $lineNum++
            if ($lineNum -le 200) { continue }
            if ($line -match '"type"\s*:\s*"user"') {
                $result.UserTurns++
            }
        }

        # Scan tail for last activity and late /rename
        $lastUserMsg = $null
        foreach ($l in $tailLines) {
            if (-not $l) { continue }
            try {
                $obj = $l | ConvertFrom-Json -ErrorAction SilentlyContinue
                if (-not $obj) { continue }

                if (-not $result.Slug -and $obj.slug) {
                    $result.Slug = $obj.slug
                }

                if ($obj.type -eq "user" -and $obj.message) {
                    $msgContent = Extract-MessageContent $obj.message

                    # Late /rename overrides earlier ones
                    if ($msgContent -match '<command-name>/rename</command-name>\s*<command-args>([^<]+)</command-args>') {
                        $result.Name = $Matches[1].Trim()
                    }
                    elseif ($msgContent -match '^\s*/rename\s+(.+)') {
                        $result.Name = $Matches[1].Trim()
                    }

                    # Track last user message
                    if ($msgContent.Length -gt 0) {
                        $cleaned = Clean-MessageText $msgContent 60
                        if ($cleaned.Length -gt 0 -and $cleaned -notmatch '^/\w+') {
                            $lastUserMsg = $cleaned
                        }
                    }
                }
            }
            catch { continue }
        }

        # Only set LastActivity if it differs from Summary
        if ($lastUserMsg -and $lastUserMsg -ne $result.Summary) {
            $result.LastActivity = $lastUserMsg
        }
    }
    catch {}

    return $result
}

# -- Full-text search in transcripts -----------------------------------------
function Search-SessionTranscript {
    param([string]$FilePath, [string]$Query)
    # Quick regex search across the file
    try {
        $matches = Select-String -Path $FilePath -Pattern $Query -SimpleMatch -ErrorAction SilentlyContinue
        return ($null -ne $matches -and $matches.Count -gt 0)
    }
    catch { return $false }
}

# -- Show transcript preview -------------------------------------------------
function Show-TranscriptPreview {
    param([string]$FilePath, [int]$ExchangeCount = 5)

    $exchanges = [System.Collections.Generic.List[object]]::new()

    try {
        # Read tail for recent exchanges
        $tailLines = Get-Content $FilePath -Tail 500 -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($l in $tailLines) {
            if (-not $l) { continue }
            try {
                $obj = $l | ConvertFrom-Json -ErrorAction SilentlyContinue
                if (-not $obj) { continue }

                if ($obj.type -eq "user" -and $obj.message) {
                    # User messages: extract text content, skip tool_results
                    $content = ""
                    if ($obj.message.content -is [string]) {
                        $content = $obj.message.content
                    }
                    elseif ($obj.message.content -is [System.Array]) {
                        foreach ($block in $obj.message.content) {
                            if ($block.type -eq "text" -and $block.text) {
                                $content = $block.text
                                break
                            }
                        }
                    }
                    if ($content.Length -gt 0) {
                        $cleaned = Clean-MessageText $content 120
                        if ($cleaned.Length -gt 0) {
                            $exchanges.Add(@{ Role = "user"; Text = $cleaned })
                        }
                    }
                }
                elseif ($obj.type -eq "assistant" -and $obj.message) {
                    # Assistant messages: extract text blocks (skip thinking/tool_use)
                    $content = ""
                    if ($obj.message.content -is [string]) {
                        $content = $obj.message.content
                    }
                    elseif ($obj.message.content -is [System.Array]) {
                        foreach ($block in $obj.message.content) {
                            if ($block.type -eq "text" -and $block.text) {
                                $content = $block.text
                                break
                            }
                        }
                    }
                    if ($content.Length -gt 0) {
                        $cleaned = Clean-MessageText $content 120
                        if ($cleaned.Length -gt 0) {
                            $exchanges.Add(@{ Role = "assistant"; Text = $cleaned })
                        }
                    }
                }
            }
            catch { continue }
        }
    }
    catch {}

    if ($exchanges.Count -eq 0) {
        Write-Host "    (no transcript available)" -ForegroundColor DarkGray
        return
    }

    # Show last N exchanges
    $startIdx = [Math]::Max(0, $exchanges.Count - ($ExchangeCount * 2))
    Write-Host ""
    Write-Host "    Transcript (last $ExchangeCount exchanges):" -ForegroundColor DarkGray
    Write-Host ("    " + ("-" * 80)) -ForegroundColor DarkGray

    for ($i = $startIdx; $i -lt $exchanges.Count; $i++) {
        $ex = $exchanges[$i]
        if ($ex.Role -eq "user") {
            Write-Host "    You: " -NoNewline -ForegroundColor Cyan
            Write-Host $ex.Text -ForegroundColor White
        }
        else {
            Write-Host "    AI:  " -NoNewline -ForegroundColor DarkYellow
            Write-Host $ex.Text -ForegroundColor Gray
        }
    }
    Write-Host ("    " + ("-" * 80)) -ForegroundColor DarkGray
}

# -- Collect sessions ---------------------------------------------------------
$sessions = [System.Collections.Generic.List[object]]::new()
$projectDirs = Get-ChildItem -Path $projectsDir -Directory -ErrorAction SilentlyContinue

foreach ($projDir in $projectDirs) {
    $folderName = $projDir.Name

    if ($ShowDebug) {
        Write-Host "  [DBG] Folder: $folderName" -ForegroundColor DarkGray
    }

    $jsonlFiles = Get-ChildItem -Path $projDir.FullName -Filter "*.jsonl" -ErrorAction SilentlyContinue

    foreach ($jsonl in $jsonlFiles) {
        $id = $jsonl.BaseName

        # Skip agent sub-session files
        if ($id -like "agent-*") { continue }

        # Skip tiny files (likely empty/aborted)
        if ($jsonl.Length -lt 100 -and -not $All) { continue }

        $parsed = Parse-SessionJsonl $jsonl.FullName

        $projectPath = if ($parsed.Cwd) { $parsed.Cwd } else { Decode-FolderName $folderName }
        $summary = $parsed.Summary
        # /rename overrides slug
        $sessionName = if ($parsed.Name) { $parsed.Name } elseif ($parsed.Slug) { $parsed.Slug } else { "" }

        # Skip forked sessions by default
        if ($parsed.ForkedFrom -and -not $IncludeForks) { continue }

        # Skip sessions with no content unless -All
        if (-not $summary -and -not $All) { continue }
        if (-not $summary) { $summary = "(empty session)" }

        $sessions.Add([PSCustomObject]@{
            SessionId    = $id
            Project      = $projectPath
            Name         = $sessionName
            Summary      = $summary
            LastActivity = $parsed.LastActivity
            UserTurns    = $parsed.UserTurns
            FileSize     = $jsonl.Length
            LastModified = $jsonl.LastWriteTime
            FilePath     = $jsonl.FullName
            ForkedFrom   = $parsed.ForkedFrom
            IsRenamed    = ($null -ne $parsed.Name -and $parsed.Name.Length -gt 0)
        })

        if ($ShowDebug) {
            $nameTag = if ($sessionName) { " [$sessionName]" } else { "" }
            $forkTag = if ($parsed.ForkedFrom) { " (fork)" } else { "" }
            Write-Host "  [DBG]   $id$nameTag$forkTag | $projectPath | $summary" -ForegroundColor DarkGray
        }
    }
}

# -- Full-text search --------------------------------------------------------
if ($Search) {
    Write-Host ""
    Write-Host "  Searching transcripts for: '$Search' ..." -ForegroundColor DarkYellow
    $sessions = [System.Collections.Generic.List[object]]::new(
        @($sessions | Where-Object {
            Search-SessionTranscript $_.FilePath $Search
        })
    )
    Write-Host "  Found $($sessions.Count) matching session(s)." -ForegroundColor DarkYellow
}

# -- Filter (supports comma-separated multi-keyword OR) ----------------------
if ($Filter) {
    $keywords = $Filter -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }
    $sessions = [System.Collections.Generic.List[object]]::new(
        @($sessions | Where-Object {
            $s = $_
            $match = $false
            foreach ($kw in $keywords) {
                if ($s.Project -like "*$kw*" -or
                    $s.Summary -like "*$kw*" -or
                    $s.Name -like "*$kw*" -or
                    $s.LastActivity -like "*$kw*") {
                    $match = $true
                    break
                }
            }
            $match
        })
    )
}

# -- Sort & limit (Cleanup overrides Count to scan all) ----------------------
if ($Cleanup -gt 0) { $Count = [int]::MaxValue }
$sorted = $sessions | Sort-Object LastModified -Descending | Select-Object -First $Count
$sessions = [System.Collections.Generic.List[object]]::new(@($sorted))

if ($sessions.Count -eq 0) {
    Write-Host "No sessions found." -ForegroundColor Yellow
    exit 0
}

# -- Build fork lookup for display -------------------------------------------
$forkChildCount = @{}
foreach ($s in $sessions) {
    if ($s.ForkedFrom) {
        if (-not $forkChildCount.ContainsKey($s.ForkedFrom)) {
            $forkChildCount[$s.ForkedFrom] = 0
        }
        $forkChildCount[$s.ForkedFrom]++
    }
}

# -- Cleanup mode -------------------------------------------------------------
if ($Cleanup -gt 0) {
    $cutoff = (Get-Date).AddDays(-$Cleanup)
    $toDelete = $sessions | Where-Object { $_.LastModified -lt $cutoff }

    if ($toDelete.Count -eq 0) {
        Write-Host "  No sessions older than $Cleanup days found." -ForegroundColor Yellow
        exit 0
    }

    Write-Host ""
    Write-Host "  Sessions older than $Cleanup days ($($toDelete.Count) found):" -ForegroundColor Yellow
    Write-Host ("  " + ("-" * 90)) -ForegroundColor DarkGray
    foreach ($s in $toDelete) {
        $timeStr = $s.LastModified.ToString("yyyy-MM-dd")
        $shortProj = Shorten-Path $s.Project 30
        Write-Host ("    {0}  {1,-30}  {2}" -f $timeStr, $shortProj, $s.Summary) -ForegroundColor DarkGray
    }
    Write-Host ("  " + ("-" * 90)) -ForegroundColor DarkGray
    Write-Host ""

    $confirm = Read-Host "  Delete these $($toDelete.Count) session files? (yes/N)"
    if ($confirm -eq "yes") {
        $deleted = 0
        foreach ($s in $toDelete) {
            try {
                Remove-Item $s.FilePath -Force -ErrorAction Stop
                $deleted++
            }
            catch {
                Write-Host "  [!] Failed to delete: $($s.FilePath)" -ForegroundColor Red
            }
        }
        Write-Host "  Deleted $deleted session(s)." -ForegroundColor Green
    }
    else {
        Write-Host "  Cancelled." -ForegroundColor DarkGray
    }
    exit 0
}

# -- Continue mode (auto-resume most recent) ----------------------------------
if ($Continue) {
    $latest = $sessions[0]
    Write-Host ""
    if ($latest.Name) {
        Write-Host "  Resuming latest session: $($latest.Name)" -ForegroundColor Cyan
    }
    Write-Host "  Prompt:   $($latest.Summary)" -ForegroundColor White
    Write-Host "  Project:  $($latest.Project)" -ForegroundColor DarkGray
    Write-Host "  ID:       $($latest.SessionId)" -ForegroundColor DarkGray

    if ($Preview -gt 0) {
        Show-TranscriptPreview $latest.FilePath $Preview
    }

    Write-Host ""

    $originalPath = $latest.Project
    $clArgs = @("--resume", $latest.SessionId)
    if ($ResumeArgs) {
        $clArgs += ($ResumeArgs -split '\s+')
    }

    if (Test-Path $originalPath) {
        Push-Location $originalPath
        & claude @clArgs
        Pop-Location
    }
    else {
        Write-Host "  [!] Project path not found: $originalPath" -ForegroundColor Yellow
        Write-Host "  Trying resume from current directory..." -ForegroundColor DarkGray
        & claude @clArgs
    }
    exit 0
}

# -- Display ------------------------------------------------------------------
Write-Host ""
Write-Host "  Claude Code Sessions ($($sessions.Count) results)" -ForegroundColor Cyan
Write-Host ("  " + ("-" * 130)) -ForegroundColor DarkGray
Write-Host ("  {0,4}  {1,-9} {2,-7} {3,-25} {4,-22} {5}" -f "#", "MODIFIED", "STATS", "PROJECT", "SESSION NAME", "FIRST PROMPT / LAST ACTIVITY") -ForegroundColor DarkGray
Write-Host ("  " + ("-" * 130)) -ForegroundColor DarkGray

$index = 0
foreach ($s in $sessions) {
    $index++
    $timeStr = Format-RelativeTime $s.LastModified
    $projectStr = Shorten-Path $s.Project 25
    $nameStr = if ($s.Name) { $s.Name } else { "-" }
    $nameStr = $nameStr.Substring(0, [Math]::Min($nameStr.Length, 22))

    # Stats: turn count + file size
    $sizeStr = Format-FileSize $s.FileSize
    $statsStr = "$($s.UserTurns)t $sizeStr"

    # Fork/rename indicators
    $forkCount = if ($forkChildCount.ContainsKey($s.SessionId)) { $forkChildCount[$s.SessionId] } else { 0 }
    $indicators = ""
    if ($s.IsRenamed) { $indicators += [char]0x2605 }  # star for renamed
    if ($s.ForkedFrom) { $indicators += [char]0x21B3 }  # arrow for fork
    if ($forkCount -gt 0) { $indicators += " +${forkCount}f" }
    if ($indicators) { $indicators = " $indicators" }

    Write-Host ("  {0,4}) " -f $index) -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,-9} " -f $timeStr) -NoNewline -ForegroundColor DarkYellow
    Write-Host ("{0,-7} " -f $statsStr) -NoNewline -ForegroundColor DarkCyan
    Write-Host ("{0,-25} " -f $projectStr) -NoNewline -ForegroundColor Green
    if ($s.Name) {
        Write-Host ("{0,-22}" -f $nameStr) -NoNewline -ForegroundColor Cyan
    }
    else {
        Write-Host ("{0,-22}" -f $nameStr) -NoNewline -ForegroundColor DarkGray
    }
    if ($indicators) {
        Write-Host $indicators -NoNewline -ForegroundColor Magenta
    }
    Write-Host " $($s.Summary)" -ForegroundColor White

    # Show last activity on a second line if available
    if ($s.LastActivity) {
        $indent = "        " + (" " * 44)
        Write-Host "${indent}> $($s.LastActivity)" -ForegroundColor DarkGray
    }
}

Write-Host ("  " + ("-" * 130)) -ForegroundColor DarkGray

# -- Resume mode --------------------------------------------------------------
if ($Resume) {
    Write-Host ""
    $choice = Read-Host "  Enter session number to resume (or Enter to cancel)"
    if ($choice -match '^\d+$') {
        $idx = [int]$choice - 1
        if ($idx -ge 0 -and $idx -lt $sessions.Count) {
            $selected = $sessions[$idx]
            Write-Host ""
            if ($selected.Name) {
                Write-Host "  Session:  $($selected.Name)" -ForegroundColor Cyan
            }
            Write-Host "  Prompt:   $($selected.Summary)" -ForegroundColor White
            Write-Host "  Project:  $($selected.Project)" -ForegroundColor DarkGray
            Write-Host "  ID:       $($selected.SessionId)" -ForegroundColor DarkGray
            Write-Host "  Turns:    $($selected.UserTurns) | Size: $(Format-FileSize $selected.FileSize)" -ForegroundColor DarkGray
            if ($selected.ForkedFrom) {
                Write-Host "  Fork of:  $($selected.ForkedFrom.Substring(0, 8))..." -ForegroundColor Magenta
            }

            if ($Preview -gt 0) {
                Show-TranscriptPreview $selected.FilePath $Preview
            }

            Write-Host ""

            $originalPath = $selected.Project
            $clArgs = @("--resume", $selected.SessionId)
            if ($ResumeArgs) {
                $clArgs += ($ResumeArgs -split '\s+')
            }

            if (Test-Path $originalPath) {
                Push-Location $originalPath
                & claude @clArgs
                Pop-Location
            }
            else {
                Write-Host "  [!] Project path not found: $originalPath" -ForegroundColor Yellow
                Write-Host "  Trying resume from current directory..." -ForegroundColor DarkGray
                & claude @clArgs
            }
        }
        else {
            Write-Host "  Invalid selection." -ForegroundColor Red
        }
    }
}
else {
    Write-Host ""
    Write-Host "  Tip: .\claude-sessions.ps1 -Resume              (pick & resume)" -ForegroundColor DarkGray
    Write-Host "       .\claude-sessions.ps1 -Continue            (resume most recent)" -ForegroundColor DarkGray
    Write-Host "       .\claude-sessions.ps1 -Filter X            (search by keyword)" -ForegroundColor DarkGray
    Write-Host "       .\claude-sessions.ps1 -Filter ""a,b""        (multi-keyword OR)" -ForegroundColor DarkGray
    Write-Host "       .\claude-sessions.ps1 -Search ""query""       (full-text transcript search)" -ForegroundColor DarkGray
    Write-Host "       .\claude-sessions.ps1 -All                 (include empty sessions)" -ForegroundColor DarkGray
    Write-Host "       .\claude-sessions.ps1 -IncludeForks        (show forked sessions)" -ForegroundColor DarkGray
    Write-Host "       .\claude-sessions.ps1 -Resume -Preview 5   (preview last 5 exchanges)" -ForegroundColor DarkGray
    Write-Host "       .\claude-sessions.ps1 -Cleanup 30          (delete sessions >30 days)" -ForegroundColor DarkGray
    Write-Host "       .\claude-sessions.ps1 -Resume -ResumeArgs ""--model opus""" -ForegroundColor DarkGray
    Write-Host ""
}
