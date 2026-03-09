# claude-sessions

List, search, and resume [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions on Windows.

Claude Code stores session data in `~/.claude/projects/` as `.jsonl` files, but there's no built-in way to browse them. This script parses those files and gives you a sortable, filterable table with one-click resume.

Inspired by [cc-sessions](https://github.com/chronologos/cc-sessions) (Rust CLI for macOS/Linux) — this is a zero-dependency PowerShell alternative for Windows.

## Example Output

```
  Claude Code Sessions (5 results)
  ----------------------------------------------------------------------------------------------------------------------------------
     #  MODIFIED  STATS   PROJECT                   SESSION NAME           FIRST PROMPT / LAST ACTIVITY
  ----------------------------------------------------------------------------------------------------------------------------------
     1) just now  12t 328K D:\myproject              lucky-inventing-sundae read the config file and suggest improvements
                                                     > implement all of them
     2) 3h ago    88t 1.4M D:\webapp                 swirling-giggling-wirt +1f Add dark mode to the dashboard
                                                     > Catch you later!
     3) 1d ago    2t 60K   D:\tools                  misty-drifting-turing  help me install the CLI tool
     4) 2d ago    251t 2.1M D:\myproject              -                     Fix the authentication bug
     5) 5d ago    1t 2K    D:\myproject              -                     hello
  ----------------------------------------------------------------------------------------------------------------------------------
```

**Columns:**
- `MODIFIED` - relative time since last activity
- `STATS` - user turn count + session file size (e.g., `12t 328K` = 12 user turns, 328KB file)
- `PROJECT` - working directory (shortened)
- `SESSION NAME` - session slug or `/rename` name

**Indicators:**
- `+Nf` - session has N forked children
- Renamed sessions (via `/rename`) are tracked and displayed

## Prerequisites

- **Windows 10/11** with PowerShell 5.1+ (pre-installed)
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** installed and used at least once

## Install

### Quick Install (one command)

```powershell
git clone https://github.com/romanticamaj/claude-sessions.git "$env:USERPROFILE\claude-sessions"
```

Then run from anywhere:

```powershell
& "$env:USERPROFILE\claude-sessions\claude-sessions.ps1"
```

### Optional: Add to PATH

Add this line to your PowerShell profile (`$PROFILE`) for quick access:

```powershell
Set-Alias cs "$env:USERPROFILE\claude-sessions\claude-sessions.ps1"
```

Then just run `cs` from any terminal.

## Usage

```powershell
# List 20 most recent sessions (default)
.\claude-sessions.ps1

# List more sessions
.\claude-sessions.ps1 -Count 50

# Filter by keyword
.\claude-sessions.ps1 -Filter "myproject"

# Filter by multiple keywords (OR match)
.\claude-sessions.ps1 -Filter "auth,login"

# Full-text search inside session transcripts
.\claude-sessions.ps1 -Search "error handling"

# Include empty/aborted sessions
.\claude-sessions.ps1 -All

# Show forked sessions (hidden by default)
.\claude-sessions.ps1 -IncludeForks

# Interactive resume: shows list, pick a number
.\claude-sessions.ps1 -Resume

# Resume with transcript preview (last 5 exchanges)
.\claude-sessions.ps1 -Resume -Preview 5

# Auto-resume the most recent session
.\claude-sessions.ps1 -Continue

# Resume with extra Claude CLI flags
.\claude-sessions.ps1 -Resume -ResumeArgs "--model opus"

# Delete sessions older than 30 days (shows preview, asks confirmation)
.\claude-sessions.ps1 -Cleanup 30

# Debug mode: show parsing details
.\claude-sessions.ps1 -ShowDebug
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Count` | int | 20 | Number of sessions to display |
| `-Filter` | string | | Keyword filter (comma-separated for OR) |
| `-Search` | string | | Full-text search inside session transcripts |
| `-Resume` | switch | | Interactive session picker to resume |
| `-Continue` | switch | | Auto-resume the most recent session |
| `-Preview` | int | 0 | Show last N exchanges before resuming |
| `-All` | switch | | Include empty/aborted sessions |
| `-IncludeForks` | switch | | Show forked sessions (hidden by default) |
| `-Cleanup` | int | 0 | Delete sessions older than N days |
| `-ResumeArgs` | string | | Extra flags to pass to `claude` CLI |
| `-ShowDebug` | switch | | Show debug/parsing output |

## Features

### Fork Detection
Sessions created by forking (branching) from an existing session are detected via `forkedFrom.sessionId` in the JSONL data. Forked sessions are hidden by default — use `-IncludeForks` to show them. Parent sessions show `+Nf` indicating how many forks they have.

### Full-Text Transcript Search
`-Search "query"` scans the full content of every session file to find sessions that mention a specific term. Useful for finding sessions where you discussed a particular topic, even if the first prompt doesn't mention it.

### Transcript Preview
`-Preview N` shows the last N exchanges (user/assistant messages) before resuming a session, so you can refresh your context without opening the session. Works with both `-Resume` and `-Continue`.

## Agent Install Instructions

If you are an AI agent installing this tool for a user on Windows, follow these steps:

```
1. Clone the repo:
   git clone https://github.com/romanticamaj/claude-sessions.git "$env:USERPROFILE\claude-sessions"

2. Verify it works:
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\claude-sessions\claude-sessions.ps1"

3. (Optional) Add alias to user's PowerShell profile:
   $profileDir = Split-Path $PROFILE -Parent
   if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force }
   if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force }
   Add-Content $PROFILE "`nSet-Alias cs `"$env:USERPROFILE\claude-sessions\claude-sessions.ps1`""

4. Confirm:
   - Run: cs
   - Expected: A table of Claude Code sessions sorted by last modified time
   - If output says "No Claude Code projects found", the user hasn't used Claude Code yet
```

## How It Works

1. Scans `~/.claude/projects/` for `.jsonl` session files
2. Parses the first 200 lines for: working directory, session slug, first user prompt, fork relationships
3. Streams through the file to count user turns efficiently (without loading the full file into memory)
4. Reads the last 100 lines via `Get-Content -Tail` for: last user message, late `/rename` commands
5. Detects fork relationships via `forkedFrom.sessionId` references
6. Decodes Claude's folder naming convention (e.g., `D--myproject` -> `D:\myproject`)
7. Displays a formatted, color-coded table sorted by last modified time

## License

MIT
