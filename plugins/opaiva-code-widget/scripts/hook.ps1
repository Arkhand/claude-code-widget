# opaiva-code-widget: Claude Code hook (Windows PowerShell 5.1).
# One script for every event; Invoke-Hook routes on hook_event_name:
#   PermissionRequest            -> queue\req-<id>.json (kind=permission), waits for queue\res-<id>.json,
#                                   prints allow/deny.
#   PreToolUse (AskUserQuestion) -> queue\req-<id>.json (kind=question), waits for the answers,
#                                   prints permissionDecision=allow + updatedInput.answers.
#   Stop                         -> queue\done-<session>-<ms>.json ("Claude finished"), unless you are
#                                   already looking at that session's window.
#   UserPromptSubmit             -> removes that session's "finished" notice (you are back in it) and
#                                   remembers the window in front (sessions\<session>.json) when it
#                                   belongs to this Claude Code session: VS Code or a terminal.
#   SessionStart / -EnsureWidget -> only makes sure the widget is running.
#   Notification                 -> a "waiting in VS Code" marker for Telegram (see Get-NotificationWaitKind).
# With Telegram ready it also writes the alert queue files of common.ps1 (tg-, wait-, seen-); the widget
# sends them. The hook itself never touches the network.
# Computer idle (no mouse/keyboard for $AwaySecs): requests and questions skip the widget and go
# straight to VS Code (and to your phone/browser when Remote Control is on).
# No answer ("in VS Code", widget closed, idle or timeout) = no output -> Claude Code's normal flow.
# Stop/UserPromptSubmit/SessionStart/Notification never print anything (it would end up in Claude's context).
# Dot-sourcing this file (tests) only defines the functions; see the end of the file.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI. UI text lives in
# strings.json (read explicitly as UTF-8).
param([switch]$EnsureWidget)
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'common.ps1')

$WidgetScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'widget.ps1'))
# Plugin data dir survives plugin updates; fallback for running the scripts outside a plugin
$Data = if ($env:CLAUDE_PLUGIN_DATA) { $env:CLAUDE_PLUGIN_DATA } else { Join-Path $env:USERPROFILE '.claude\opaiva-code-widget' }
$Data = [IO.Path]::GetFullPath($Data).TrimEnd('\')
$Queue = Join-Path $Data 'queue'
$Sessions = Join-Path $Data 'sessions'
# Sessions working right now (busy\<session>.json) and the sessions of the current round
$Busy = Join-Path $Data 'busy'
$RoundPath = Join-Path $Data 'busy-round.json'
$BusyMaxAgeMs = 12 * 3600 * 1000
# Esc ends a turn without a Stop: a session whose transcript has not grown for this long is not working
$BusyQuietMs = 15 * 60 * 1000
$LogPath = Join-Path $Data 'hook.log'
# Processes that own a terminal window (classic console, Windows Terminal and common alternatives)
$TerminalHosts = @('windowsterminal.exe', 'openconsole.exe', 'conhost.exe', 'powershell.exe', 'pwsh.exe', 'cmd.exe',
    'wezterm-gui.exe', 'alacritty.exe', 'mintty.exe', 'tabby.exe', 'hyper.exe')
# Processes that own a VS Code window
$VsCodeProcesses = @('code.exe', 'code - insiders.exe')
$AwaySecs = ConvertTo-AwaySecs $env:CLAUDE_WIDGET_AWAY_SECS

$Lang = Resolve-Lang $env:CLAUDE_WIDGET_LANG
$S = Get-Strings $Lang

# One widget per data dir; the widget computes the same name
$MutexName = Get-MutexName $Data
$script:waitEnd = $null
# Wait-Response queued the Telegram alert of the request while it was still on the card
$script:alertQueued = $false

function Write-HookLog([string]$msg) { Write-LogLine $LogPath $msg }

function Test-Widget {
    try { [System.Threading.Mutex]::OpenExisting($MutexName).Dispose(); return $true } catch { return $false }
}

# -NoWait: launch and return at once, without waiting for the widget to come up (the caller left its work
# on disk for it)
function Start-Widget([switch]$NoWait) {
    if (Test-Widget) {
        # After a plugin update the old widget keeps running from the old folder: replace it
        $info = $null
        try { $info = [IO.File]::ReadAllText((Join-Path $Data 'widget.json'), $Utf8) | ConvertFrom-Json } catch {}
        if (-not $info -or -not $info.script -or
            [string]::Equals([IO.Path]::GetFullPath([string]$info.script), $WidgetScript, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        # A widget from a newer version (another session already updated) stays
        if (-not (Test-WidgetOlder ([string]$info.script) $WidgetScript)) { return $true }
        Write-HookLog "restarting widget from an older version ($($info.script))"
        # Ask it to close itself first (it removes its tray icon); kill it if it does not within 4 s
        $quit = Join-Path $Data 'quit.flag'
        try { [IO.File]::WriteAllText($quit, '') } catch {}
        for ($i = 0; $i -lt 40 -and (Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
        if (Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue) {
            try { Stop-Process -Id ([int]$info.pid) -Force } catch {}
        }
        Remove-Item -LiteralPath $quit -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 30 -and (Test-Widget); $i++) { Start-Sleep -Milliseconds 100 }
    }
    New-Item -ItemType Directory -Force -Path $Data | Out-Null
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -DataDir "{1}" -Lang {2}' -f $WidgetScript, $Data, $Lang
    # Through WMI the widget is created outside Claude Code's process tree, so it outlives the session
    $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; ProcessStartupInformation = $si } | Out-Null
    if ($NoWait) { return $true }
    # The very first start of new scripts can take ~10 s (antivirus scan); later starts take ~1-2 s
    for ($i = 0; $i -lt 200; $i++) {
        if (Test-Widget) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# Hook output as pure ASCII (\uXXXX), independent of the PowerShell 5.1 console encoding
function ConvertTo-AsciiJson($obj) {
    $json = $obj | ConvertTo-Json -Depth 12 -Compress
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

function Remove-Done([string]$sid) {
    if (-not $sid) { return }
    Get-ChildItem -LiteralPath $Queue -Filter "done-$sid-*.json" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Test-Away { return (Get-IdleSeconds) -ge $AwaySecs }

function Initialize-Win32 {
    if ('ClaudeWidget.Win' -as [type]) { return }
    Add-Type -Namespace ClaudeWidget -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
'@
}

function Get-WindowTitle([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder 512
    [void][ClaudeWidget.Win]::GetWindowText($h, $sb, 512)
    return $sb.ToString()
}

# This hook's ancestors (Claude Code, its shell, the terminal or VS Code) + a pid -> process map
function Get-ProcessTree {
    $map = @{}
    foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name) { $map[[int]$p.ProcessId] = $p }
    $ancestors = @{}
    $cur = [int]$PID
    for ($i = 0; $i -lt 16 -and $map.ContainsKey($cur); $i++) {
        $parent = [int]$map[$cur].ParentProcessId
        if ($parent -eq 0 -or $ancestors.ContainsKey($parent)) { break }
        $ancestors[$parent] = $true
        $cur = $parent
    }
    return @{ map = $map; ancestors = $ancestors }
}

# vscode / terminal / other, from the name of the process that owns the window
function Get-WindowKind([string]$ProcessName) {
    $name = $ProcessName.ToLowerInvariant()
    if ($VsCodeProcesses -contains $name) { return 'vscode' }
    if ($TerminalHosts -contains $name) { return 'terminal' }
    return 'other'
}

# On UserPromptSubmit the window in front is almost always where you typed. Remember it, but only
# if it really belongs to this session: its owner (or the owner's parent, for a classic console
# whose window belongs to conhost.exe) must be one of this hook's ancestors. A prompt sent from
# your phone (Remote Control) leaves some unrelated window in front and is ignored.
function Save-SessionWindow([string]$sid, [string]$logTag) {
    if (-not $sid) { return }
    try {
        Initialize-Win32
        $fg = [ClaudeWidget.Win]::GetForegroundWindow()
        if ($fg -eq [IntPtr]::Zero) { return }
        $ownerPid = [uint32]0
        [void][ClaudeWidget.Win]::GetWindowThreadProcessId($fg, [ref]$ownerPid)
        $tree = Get-ProcessTree
        $owner = $tree.map[[int]$ownerPid]
        $ownerParent = if ($owner) { [int]$owner.ParentProcessId } else { 0 }
        if (-not ($tree.ancestors.ContainsKey([int]$ownerPid) -or $tree.ancestors.ContainsKey($ownerParent))) {
            Write-HookLog "$logTag window in front is not this session's, not saved"
            return
        }
        $name = if ($owner) { ([string]$owner.Name).ToLowerInvariant() } else { '' }
        $kind = Get-WindowKind $name
        New-Item -ItemType Directory -Force -Path $Sessions | Out-Null
        [IO.File]::WriteAllText((Join-Path $Sessions "$sid.json"), (@{ hwnd = $fg.ToInt64(); kind = $kind; process = $name } | ConvertTo-Json -Compress), $Utf8)
        Write-HookLog "$logTag session window saved ($kind, $name)"
        # Forget sessions untouched for a week
        Get-ChildItem -LiteralPath $Sessions -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { Write-HookLog "$logTag session window: $($_.Exception.Message)" }
}

# This session's Claude Code process: the first ancestor named claude.exe, else node.exe (npm
# install), else 0 (unknown)
function Get-ClaudePid {
    try {
        $map = (Get-ProcessTree).map
        $node = 0
        $cur = [int]$PID
        for ($i = 0; $i -lt 16 -and $map.ContainsKey($cur); $i++) {
            $parent = [int]$map[$cur].ParentProcessId
            if ($parent -eq 0 -or -not $map.ContainsKey($parent)) { break }
            $name = ([string]$map[$parent].Name).ToLowerInvariant()
            if ($name -eq 'claude.exe') { return $parent }
            if ($name -eq 'node.exe' -and $node -eq 0) { $node = $parent }
            $cur = $parent
        }
        return $node
    } catch { return 0 }
}

# Ids of the sessions still working (see Get-BusySessions)
function Get-WorkingSessions {
    foreach ($b in @(Get-BusySessions $Busy $BusyMaxAgeMs $BusyQuietMs)) { $b.id }
}

# UserPromptSubmit: this session is working. With nothing else working, a new round starts.
function Set-SessionBusy([string]$Sid, [string]$Transcript = '', [string]$Cwd = '') {
    if (-not $Sid) { return }
    try {
        $others = @(Get-WorkingSessions | Where-Object { $_ -ne $Sid })
        $round = @()
        if ($others.Count -gt 0 -and (Test-Path -LiteralPath $RoundPath)) {
            try { $round = @(([IO.File]::ReadAllText($RoundPath, $Utf8) | ConvertFrom-Json).sessions) } catch {}
        }
        if ($round -notcontains $Sid) { $round += $Sid }
        New-Item -ItemType Directory -Force -Path $Busy | Out-Null
        $file = Join-Path $Busy "$Sid.json"
        Remove-Item -LiteralPath $file, $RoundPath -Force -ErrorAction SilentlyContinue
        Write-JsonAtomic $file ([ordered]@{ pid = Get-ClaudePid; since = Get-NowMs; transcript = $Transcript; cwd = $Cwd })
        Write-JsonAtomic $RoundPath @{ sessions = @($round) }
    } catch {}
}

# Stop: this session is done. $true ("all done") when nothing else is working and the round had at
# least two sessions; with a single session the usual "finished" sound stays.
function Complete-SessionBusy([string]$Sid) {
    try {
        if ($Sid) { Remove-Item -LiteralPath (Join-Path $Busy "$Sid.json") -Force -ErrorAction SilentlyContinue }
        if (@(Get-WorkingSessions).Count -gt 0) { return $false }
        $round = @()
        try { $round = @(([IO.File]::ReadAllText($RoundPath, $Utf8) | ConvertFrom-Json).sessions) } catch {}
        Remove-Item -LiteralPath $RoundPath -Force -ErrorAction SilentlyContinue
        return @($round | Select-Object -Unique).Count -ge 2
    } catch { return $false }
}

# The session's remembered window, if it still exists
function Get-SessionWindow([string]$sid) {
    if (-not $sid) { return $null }
    $path = Join-Path $Sessions "$sid.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $w = [IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json
        Initialize-Win32
        if ([ClaudeWidget.Win]::IsWindow([IntPtr]::new([int64]$w.hwnd))) { return $w }
    } catch {}
    return $null
}

# Are you already looking at this session? Then no "finished" notice is needed.
# With a remembered window: is it in front? Without one: is this project's VS Code window in front?
function Test-UserWatching([string]$cwd, $sessionWindow) {
    try {
        Initialize-Win32
        $fg = [ClaudeWidget.Win]::GetForegroundWindow()
        if ($sessionWindow) { return $fg.ToInt64() -eq [int64]$sessionWindow.hwnd }
        if (-not $cwd) { return $false }
        $title = Get-WindowTitle $fg
        $project = Split-Path -Leaf $cwd
        return ($title.IndexOf('Visual Studio Code', [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
               (Test-TitleHasProject $title $project)
    } catch { return $false }
}

# Text of Claude's last reply: the event field when present, otherwise the end of the transcript
function Get-LastAssistantText($evt) {
    if ($evt.last_assistant_message) { return [string]$evt.last_assistant_message }
    $tp = [string]$evt.transcript_path
    if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { return '' }
    try {
        $lines = @(Get-Content -LiteralPath $tp -Tail 80 -Encoding UTF8)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -notlike '*"assistant"*') { continue }
            try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
            if ($o.type -ne 'assistant') { continue }
            $texts = @($o.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
            if ($texts.Count -gt 0) { return ($texts -join ' ') }
        }
    } catch {}
    return ''
}

# The question the Claude desktop app shows in its "next step" box at the end of this turn, from the last
# mcp__ccd_turn__wrap_up call after your last prompt: Ask (its `ask`, '' when there is none) and Choices
# (the labels of its answer buttons, at most 3).
function Get-PendingAsk([string]$TranscriptPath) {
    $none = @{ Ask = ''; Choices = @() }
    if (-not $TranscriptPath -or -not (Test-Path -LiteralPath $TranscriptPath)) { return $none }
    try {
        # Get-Content -Tail takes ~25 s on a few MB of long JSON lines: read the last 4 MB directly
        # (shared, Claude Code is still writing the file)
        $fs = [IO.File]::Open($TranscriptPath, 'Open', 'Read', 'ReadWrite')
        try {
            $count = [int][math]::Min($fs.Length, 4MB)
            [void]$fs.Seek(-$count, 'End')
            $buf = New-Object byte[] $count
            $read = 0
            while ($read -lt $count) { $n = $fs.Read($buf, $read, $count - $read); if ($n -le 0) { break }; $read += $n }
        } finally { $fs.Dispose() }
        # The first line may be cut in half: it is only ever skipped (no match) or parsed and dropped
        $lines = $Utf8.GetString($buf, 0, $read) -split "`n"
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            # Only parse the lines that matter: some (api-request-blob) are hundreds of KB
            if ($line -like '*"mcp__ccd_turn__wrap_up"*') {
                try { $o = $line | ConvertFrom-Json } catch { continue }
                if ($o.type -ne 'assistant') { continue }
                foreach ($c in @($o.message.content)) {
                    if ($c.type -eq 'tool_use' -and $c.name -eq 'mcp__ccd_turn__wrap_up') {
                        $labels = @(@($c.input.actions) | ForEach-Object { ([string]$_.label).Trim() } | Where-Object { $_ })
                        return @{ Ask = [string]$c.input.ask; Choices = @($labels | Select-Object -First 3) }
                    }
                }
            }
            # Your prompt starts the turn: nothing before it counts
            elseif ($line -like '*"type":"user"*' -and $line -notlike '*"tool_result"*') { return $none }
        }
    } catch {}
    return $none
}

# Markdown -> short plain text
function Format-Snippet([string]$text) {
    $t = $text -replace '(?s)```.*?```', ' '
    $t = $t -replace '\[([^\]]+)\]\([^)]*\)', '$1'
    $t = $t -replace '[`*_#>|]', '' -replace '\s+', ' '
    $t = $t.Trim()
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300).TrimEnd() + '...' }
    return $t
}

# Waits for the widget's queue\res-<id>.json. $null = gave up ($script:waitEnd says why).
# $Alert (Telegram ready and a session; see Send-RequestAlert): still unanswered after $AlertSecs, and before the
# card closes, the alert goes out ($script:alertQueued) and the card stays while you are at the computer; if you
# are away at that moment it is handed over, so the phone can answer it.
function Wait-Response([string]$id, [int]$TimeoutSecs, [int]$AlertSecs = 0, [hashtable]$Alert = $null, [string]$LogTag = '') {
    $script:alertQueued = $false
    $resPath = Join-Path $Queue "res-$id.json"
    $parentPid = $null
    try { $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId } catch {}
    $start = Get-Date
    $deadline = $start.AddSeconds($TimeoutSecs)
    # Closing first (or at the same time) alerts as before, through the caller ('timeout')
    $alertAt = if ($Alert -and $AlertSecs -gt 0 -and $AlertSecs -lt $TimeoutSecs) { $start.AddSeconds($AlertSecs) } else { $null }
    $tick = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resPath) {
            try { return ([IO.File]::ReadAllText($resPath, $Utf8) | ConvertFrom-Json) } catch { return $null }
        }
        $tick++
        if ($tick % 5 -eq 0) {
            if (-not (Test-Widget)) { $script:waitEnd = 'widget closed'; return $null }
            if ($parentPid -and -not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { $script:waitEnd = 'session ended'; return $null }
            if ($alertAt -and -not $script:alertQueued -and (Get-Date) -ge $alertAt) {
                Send-RequestAlert $Alert 'unanswered' $LogTag ''
                $script:alertQueued = $true
                if (Test-Away) { $script:waitEnd = 'idle'; return $null }
                Write-HookLog "$LogTag alerted at $AlertSecs s, the card stays"
            }
            # You walked away with the card on screen: hand it to VS Code / your phone
            if (Test-Away) { $script:waitEnd = 'idle'; return $null }
            # "Do not disturb" was turned on after this request was written: the widget is hidden
            if (Test-Dnd $Data) { $script:waitEnd = 'do not disturb'; return $null }
        }
        Start-Sleep -Milliseconds 300
    }
    $script:waitEnd = 'timeout'
    return $null
}

# $session lets a Notification event tell whether the widget holds a request of that session
function New-Request([string]$kind, [string]$cwd, [string]$session, [int]$TimeoutSecs, [hashtable]$fields) {
    New-Item -ItemType Directory -Force -Path $Queue | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $req = [ordered]@{
        id      = $id
        pid     = $PID
        kind    = $kind
        created = Get-NowMs
        timeout = $TimeoutSecs
        cwd     = $cwd
        session = $session
    }
    foreach ($k in $fields.Keys) { $req[$k] = $fields[$k] }
    Write-JsonAtomic (Join-Path $Queue "req-$id.json") $req
    return $id
}

function Remove-Request([string]$id) {
    Remove-Item -LiteralPath (Join-Path $Queue "req-$id.json"), (Join-Path $Queue "res-$id.json") -Force -ErrorAction SilentlyContinue
}

# How long a request waits for the widget: the "Close automatically" preference (closeAfter; Never = the
# 60-minute limit hooks.json gives the hook), read when the request is created. The request file carries it
# to the widget's countdown.
function Get-RequestTimeout($Prefs) {
    # TESTS ONLY: a few seconds instead of minutes, so the e2e tests can reach a timeout quickly. Not a
    # user setting: it is not documented and the widget never reads it.
    if ($env:CLAUDE_WIDGET_WAIT_SECS) { return [int]$env:CLAUDE_WIDGET_WAIT_SECS }
    return [int]((Get-CloseAfterMs $Prefs) / 1000)
}

# When a request still on the card alerts on Telegram: the "Alert after" preference (notifyAfter)
function Get-AlertSecs($Prefs) {
    # TESTS ONLY, like CLAUDE_WIDGET_WAIT_SECS: not a user setting, not documented
    if ($env:CLAUDE_WIDGET_ALERT_SECS) { return [int]$env:CLAUDE_WIDGET_ALERT_SECS }
    return [int]$Prefs.notifyAfter * 60
}

# Does the widget hold a request of this session (a req-*.json written by New-Request)?
function Test-RequestPending([string]$Queue, [string]$Session) {
    if (-not $Session -or -not (Test-Path -LiteralPath $Queue)) { return $false }
    foreach ($f in @(Get-ChildItem -LiteralPath $Queue -Filter 'req-*.json' -File -ErrorAction SilentlyContinue)) {
        try { if ([string]([IO.File]::ReadAllText($f.FullName, $Utf8) | ConvertFrom-Json).session -eq $Session) { return $true } } catch {}
    }
    return $false
}

# Notification event (Claude Code hooks reference, https://code.claude.com/docs/en/hooks, checked
# 2026-10-25). Input: the common fields (session_id, transcript_path, cwd, hook_event_name) plus
# message (the notification text), title (optional) and notification_type. It cannot block, and its
# output is discarded. The types that mean "a prompt waits for you" give the marker's kind:
#   permission_prompt       a tool use (or a sandboxed network request) waits for approval, ~6 s after it
#                           appeared (in VS Code / the desktop app: unless a PermissionRequest hook answered)
#   elicitation_dialog      an MCP server's form waits for an answer
#   elicitation_url_dialog  an MCP server asks you to open a URL
# Every other type is ignored, idle_prompt above all (finished ~60 s ago and you have not typed: the
# finished notice covers it), and also auth_success, elicitation_complete/response, agent_needs_input /
# agent_completed (background sessions in agent view), quota_auto_resume_* and plugin_notification.
# hooks.json registers Notification with a matcher of these same three types, so the others do not even
# start powershell.exe; this list stays the authoritative filter. Change both together.
function Get-NotificationWaitKind([string]$Type) {
    switch ($Type) {
        'permission_prompt' { return 'permission' }
        'elicitation_dialog' { return 'question' }
        'elicitation_url_dialog' { return 'question' }
    }
    return $null
}

# Writes one Telegram queue file. A failure is logged and never stops the hook; nothing reaches the
# pipeline (Claude Code reads stdout).
function Invoke-AlertWrite([scriptblock]$Write, [string]$LogTag) {
    try { & $Write | Out-Null } catch { Write-HookLog "$LogTag telegram: $($_.Exception.Message)" }
}

# What Telegram makes of a request that left the widget without an answer: 'wait' (handed to VS Code:
# waiting in VS Code), 'timeout' or 'idle' (alert now), or $null (answered, or the session ended, ...)
# Do not disturb turned on, or the widget gone, while the card was up: the request now waits in VS Code just
# like a hand-over, so it keeps its Telegram coverage.
function Get-AlertAction($Res, [string]$WaitEnd) {
    if ($Res) { if ([string]$Res.decision -eq 'vscode') { return 'wait' } return $null }
    if ($WaitEnd -in @('timeout', 'idle')) { return $WaitEnd }
    if ($WaitEnd -in @('do not disturb', 'widget closed')) { return 'wait' }
    return $null
}

# Queues the Telegram side of a request that goes to VS Code. Callers build $Alert only when Telegram is
# ready and the event has a session. $Why: 'wait' -> "waiting in VS Code" marker; 'away', 'timeout', 'idle',
# 'unanswered' (still on the card at notifyAfter, see Wait-Response) -> outbox entry to send now, with that
# reason, plus the session's alerted- stamp (the Notification that Claude Code sends a few seconds later for
# the same prompt must not queue a second alert). The title is
# read only here, unless the caller already has it. For 'away' the widget (the sender) is launched after
# the entry is on disk, without waiting for it: the request goes to VS Code / your phone at once.
function Send-RequestAlert([hashtable]$Alert, [string]$Why, [string]$LogTag, [string]$Transcript) {
    if (-not $Alert -or -not $Alert.session) { return }
    if (-not $Alert.ContainsKey('title')) { $Alert.title = Get-SessionTitle $Transcript $Alert.session }
    if ($Why -eq 'wait') { Invoke-AlertWrite { Set-WaitMarker $Queue $Alert } $LogTag; return }
    $item = $Alert.Clone()
    $item.reason = $Why
    Invoke-AlertWrite { Add-AlertOutbox $Queue $item } $LogTag
    Invoke-AlertWrite { Write-JsonAtomic (Join-Path $Queue "alerted-$($item.session).json") ([ordered]@{ session = $item.session; at = Get-NowMs }) -Replace } $LogTag
    if ($Why -eq 'away') { [void](Start-Widget -NoWait) }
}

# The "at" of a session stamp (seen-<session>.json, alerted-<session>.json), 0 when there is none
function Get-StampAt([string]$Queue, [string]$Prefix, [string]$Session) {
    try { return [int64]([IO.File]::ReadAllText((Join-Path $Queue "$Prefix-$Session.json"), $Utf8) | ConvertFrom-Json).at } catch { return [int64]0 }
}

# What the permission card shows: the command, file, URL or query; otherwise the raw input
function Get-PermissionDetail($ToolInput) {
    if ($ToolInput.command) { $detail = [string]$ToolInput.command }
    elseif ($ToolInput.file_path) { $detail = [string]$ToolInput.file_path }
    elseif ($ToolInput.notebook_path) { $detail = [string]$ToolInput.notebook_path }
    elseif ($ToolInput.url) { $detail = [string]$ToolInput.url }
    elseif ($ToolInput.query) { $detail = [string]$ToolInput.query }
    else { $detail = [string]($ToolInput | ConvertTo-Json -Depth 4 -Compress) }
    if ($detail.Length -gt 2000) { $detail = $detail.Substring(0, 2000) + ' ...' }
    return $detail
}

# PermissionRequest answer in Claude Code's hook format; deny carries a message for Claude
# The file change of an Edit, MultiEdit or Write for the widget's diff (texts cut at 4000 characters,
# at most 5 edits); $null for other tools or when there is nothing to show
function New-ChangeInfo([string]$Tool, $ToolInput) {
    if (-not $ToolInput) { return $null }
    function Limit-Text($t) { $t = [string]$t; if ($t.Length -gt 4000) { return $t.Substring(0, 4000) } return $t }
    if ($Tool -eq 'Write') {
        return @{ kind = 'write'; content = (Limit-Text $ToolInput.content) }
    }
    $edits = @()
    if ($Tool -eq 'Edit') { $edits = @($ToolInput) }
    elseif ($Tool -eq 'MultiEdit') { $edits = @($ToolInput.edits) }
    else { return $null }
    $all = @($edits | Where-Object { $_ })
    $list = @($all | Select-Object -First 5 | ForEach-Object { @{ old = (Limit-Text $_.old_string); new = (Limit-Text $_.new_string) } })
    if ($list.Count -eq 0) { return $null }
    return @{ kind = 'edit'; edits = $list; droppedEdits = [math]::Max(0, $all.Count - 5) }
}

# The suggestions of Claude Code the widget may offer as "Always allow", with their original index:
# rules that allow, the modes below bypassPermissions, and directories. Never rules that remove or
# replace the user's rules, nor anything that denies.
function Get-OfferedSuggestions($Suggestions) {
    $i = -1
    foreach ($s in @($Suggestions)) {
        $i++
        if (-not $s) { continue }
        $ok = $false
        switch ([string]$s.type) {
            # Only rules that allow: Claude Code also suggests deny/ask/defer rules, which are not "Always allow"
            'addRules' { $ok = ([string]$s.behavior -ceq 'allow') -and (@($s.rules).Count -gt 0) }
            'setMode' { $ok = [string]$s.mode -in @('default', 'plan', 'acceptEdits', 'auto', 'dontAsk') }
            'addDirectories' { $ok = @($s.directories).Count -gt 0 }
        }
        if ($ok) {
            [pscustomobject]@{ index = $i; type = [string]$s.type; rules = @($s.rules); destination = [string]$s.destination
                mode = [string]$s.mode; directories = @($s.directories) }
        }
    }
}

# The suggestion as Claude Code sent it (type, rules, behavior, destination, mode, directories), without
# the empty fields, in the form updatedPermissions takes
function ConvertTo-UpdatedPermission($Suggestion) {
    $o = [ordered]@{}
    foreach ($name in 'type', 'rules', 'behavior', 'destination', 'mode', 'directories') {
        $p = $Suggestion.PSObject.Properties[$name]
        if (-not $p -or $null -eq $p.Value) { continue }
        $v = $p.Value
        # (an array of rule objects must not be tested through [string]: it converts to '')
        if ($v -is [string]) { if ($v -eq '') { continue } }
        elseif ($v -is [array] -and $v.Count -eq 0) { continue }
        $o[$name] = $v
    }
    return $o
}

function New-PermissionOutput([string]$Behavior, [string]$Message, $UpdatedPermissions = $null) {
    $decision = [ordered]@{ behavior = $Behavior }
    if ($Behavior -eq 'deny') { $decision.message = $Message }
    if ($Behavior -eq 'allow' -and $null -ne $UpdatedPermissions -and @($UpdatedPermissions).Count -gt 0) { $decision.updatedPermissions = @($UpdatedPermissions) }
    return [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PermissionRequest'; decision = $decision } }
}

# AskUserQuestion answered: allow the tool with updatedInput = the original input + answers
# (question text -> chosen label, or free text)
function New-AnswerOutput($ToolInput, $Answers, [string]$Reason) {
    $ToolInput | Add-Member -NotePropertyName answers -NotePropertyValue $Answers -Force
    return [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'allow'
            permissionDecisionReason = $Reason
            updatedInput             = $ToolInput
        }
    }
}

# Routes one hook event. Returns the JSON to print, or $null = no output (Claude Code's normal flow).
# Nothing in here may write to the pipeline except the return value: Claude Code reads stdout.
function Invoke-Hook($evt) {
    $hookEvent = [string]$evt.hook_event_name
    # The same cleaning as the queue writers of common.ps1, so marker names always match
    $sid = Get-SafeSessionId ([string]$evt.session_id)
    $logTag = '{0} {1}' -f $hookEvent, $sid.Substring(0, [math]::Min(8, $sid.Length))
    $tool = [string]$evt.tool_name
    $in = $evt.tool_input
    $cwd = [string]$evt.cwd
    $transcript = [string]$evt.transcript_path
    $prefs = Read-Prefs $Data
    $tg = Test-TelegramReady $Data $prefs

    # Any event of a session means it moved on: its "waiting in VS Code" marker goes and a sent alert can be
    # marked resolved. Not Notification: it says the session still waits.
    if ($tg -and $sid -and $hookEvent -ne 'Notification') { Invoke-AlertWrite { Set-SessionSeen $Queue $sid } $logTag }

    if ($hookEvent -eq 'SessionStart') { Write-HookLog $logTag; [void](Start-Widget); return $null }

    if ($hookEvent -eq 'Notification') {
        $kind = Get-NotificationWaitKind ([string]$evt.notification_type)
        if (-not $tg -or -not $sid -or -not $kind) { return $null }
        # The widget holds the request: it alerts by itself if needed
        if (Test-RequestPending $Queue $sid) { Write-HookLog "$logTag $($evt.notification_type): request in the widget"; return $null }
        $seenAt = Get-StampAt $Queue 'seen' $sid
        # This hook runs async: if the session moved on after this process started (you answered right
        # after the prompt), a marker written now would be left behind for a prompt already answered
        $startMs = try { [DateTimeOffset]::new((Get-Process -Id $PID).StartTime).ToUnixTimeMilliseconds() } catch { Get-NowMs }
        if ($seenAt -gt $startMs) { Write-HookLog "$logTag $($evt.notification_type): session moved on"; return $null }
        # Nothing happened in the session since the hook alerted on a request (away, timeout, idle): this is
        # the prompt of that same request, already alerted
        $alertedAt = Get-StampAt $Queue 'alerted' $sid
        if ($alertedAt -gt 0 -and $alertedAt -ge $seenAt) { Write-HookLog "$logTag $($evt.notification_type): already alerted"; return $null }
        # A marker written by the request itself (plan, handed to VS Code) is the same wait: keep its kind and age
        if (Test-Path -LiteralPath (Join-Path $Queue "wait-$sid.json")) { return $null }
        Invoke-AlertWrite { Set-WaitMarker $Queue @{ kind = $kind; session = $sid; cwd = $cwd; title = Get-SessionTitle $transcript $sid; detail = [string]$evt.message } } $logTag
        Write-HookLog "$logTag $($evt.notification_type): waiting in VS Code"
        return $null
    }

    if ($hookEvent -eq 'UserPromptSubmit') {
        Write-HookLog $logTag
        Remove-Done $sid
        Set-SessionBusy $sid $transcript $cwd
        Save-SessionWindow $sid $logTag
        return $null
    }

    if ($hookEvent -eq 'Stop') {
        if (-not $sid) { return $null }
        Remove-Done $sid
        # Before deciding on the notice: the session stops counting as working even without one
        $allDone = Complete-SessionBusy $sid
        $sessionWindow = Get-SessionWindow $sid
        # The Claude desktop app hosts every session in one window: it being in front says nothing
        $inDesktopApp = $sessionWindow -and [string]$sessionWindow.process -eq 'claude.exe'
        if (-not $inDesktopApp -and (Test-UserWatching $cwd $sessionWindow)) { Write-HookLog "$logTag no notice (session window in front)"; return $null }
        $pending = Get-PendingAsk $transcript
        $ask = Format-Snippet $pending.Ask
        $msg = if ($ask) { $ask } else { Format-Snippet (Get-LastAssistantText $evt) }
        if (-not $msg) { $msg = $S.readyNext }
        New-Item -ItemType Directory -Force -Path $Queue | Out-Null
        $now = Get-NowMs
        Write-JsonAtomic (Join-Path $Queue "done-$sid-$now.json") ([ordered]@{
            session = $sid
            created = $now
            cwd     = $cwd
            message = $msg
            # $msg is the question waiting in the Claude desktop app, not the end of the reply
            question = [bool]$ask
            # The question's answer buttons in the app, shown as buttons on the notice
            choices = @(if ($ask) { $pending.Choices })
            title   = Get-SessionTitle $transcript $sid
            allDone = [bool]$allDone
            # Lets the widget's button go back to that exact window (VS Code or terminal)
            hwnd    = $(if ($sessionWindow) { [int64]$sessionWindow.hwnd } else { 0 })
            kind    = $(if ($sessionWindow) { [string]$sessionWindow.kind } else { '' })
            # The widget alerts on these only when you are away (being in front says nothing there)
            desktopApp = [bool]$inDesktopApp
        })
        Write-HookLog "$logTag notice created"
        [void](Start-Widget)
        return $null
    }

    # ---------------- PreToolUse: multiple-choice questions ----------------
    if ($hookEvent -eq 'PreToolUse') {
        if ($tool -ne 'AskUserQuestion') { return $null }
        $questions = @($in.questions)
        if ($questions.Count -eq 0) { return $null }
        # Telegram's view of this question; $null without Telegram or a session (nothing extra is done then)
        $alert = if ($tg -and $sid) { @{ kind = 'question'; session = $sid; cwd = $cwd; detail = [string]$questions[0].question } } else { $null }
        if (Test-Dnd $Data) {
            Write-HookLog "$logTag do not disturb: question goes to VS Code"
            if ($alert) { Send-RequestAlert $alert $(if (Test-Away) { 'away' } else { 'wait' }) $logTag $transcript }
            return $null
        }
        if (Test-Away) { Write-HookLog "$logTag idle: question goes to VS Code"; if ($alert) { Send-RequestAlert $alert 'away' $logTag $transcript }; return $null }
        if (-not (Start-Widget)) { Write-HookLog "$logTag widget did not start"; if ($alert) { Send-RequestAlert $alert 'wait' $logTag $transcript }; return $null }
        Remove-Done $sid

        $title = Get-SessionTitle $transcript $sid
        if ($alert) { $alert.title = $title }
        $timeout = Get-RequestTimeout $prefs
        $id = New-Request 'question' $cwd $sid $timeout @{
            tool        = $tool
            description = [string]$questions[0].question
            questions   = $questions
            title       = $title
            noCountdown = ([int]$prefs.closeAfter -eq 0)
        }
        try { $res = Wait-Response $id $timeout (Get-AlertSecs $prefs) $alert $logTag } finally { Remove-Request $id }

        if ($res -and $res.decision -eq 'answer' -and $res.answers) {
            Write-HookLog "$logTag answered in the widget"
            return ConvertTo-AsciiJson (New-AnswerOutput $in $res.answers $S.answeredReason)
        }
        $why = if ($res) { [string]$res.decision } else { $script:waitEnd }
        Write-HookLog "$logTag goes to VS Code ($why)"
        $action = Get-AlertAction $res $script:waitEnd
        # Already alerted while on the card: no second alert nor a wait marker for the same request
        if ($alert -and $action -and -not $script:alertQueued) { Send-RequestAlert $alert $action $logTag $transcript }
        return $null
    }

    # ---------------- PermissionRequest ----------------
    if ($hookEvent -eq 'PermissionRequest') {
        # Plan approval waits in VS Code (never in the widget): only the marker for Telegram -> normal flow
        if ($tool -eq 'ExitPlanMode') {
            if ($tg -and $sid) { Send-RequestAlert @{ kind = 'plan'; session = $sid; cwd = $cwd; detail = Format-Snippet ([string]$in.plan) } 'wait' $logTag $transcript }
            return $null
        }
        # Questions are handled on PreToolUse -> normal flow
        if ($tool -eq 'AskUserQuestion') { return $null }

        # Telegram's view of this request; $null without Telegram or a session (nothing extra is done then)
        $alert = if ($tg -and $sid) { @{ kind = 'permission'; session = $sid; cwd = $cwd; detail = "${tool}: $(Get-PermissionDetail $in)" } } else { $null }
        if (Test-Dnd $Data) {
            Write-HookLog "$logTag $tool do not disturb: goes to VS Code"
            if ($alert) { Send-RequestAlert $alert $(if (Test-Away) { 'away' } else { 'wait' }) $logTag $transcript }
            return $null
        }
        if (Test-Away) { Write-HookLog "$logTag $tool idle: goes to VS Code"; if ($alert) { Send-RequestAlert $alert 'away' $logTag $transcript }; return $null }

        $detail = Get-PermissionDetail $in
        $desc = [string]$in.description
        if (-not $desc) { $desc = $S.wantsTool -f $tool }

        # Widget did not come up -> don't keep Claude Code waiting for nobody
        if (-not (Start-Widget)) { Write-HookLog "$logTag widget did not start"; if ($alert) { Send-RequestAlert $alert 'wait' $logTag $transcript }; return $null }
        # The session is working again: its previous "finished" notice is stale
        Remove-Done $sid

        $offered = @(Get-OfferedSuggestions $evt.permission_suggestions)
        $title = Get-SessionTitle $transcript $sid
        if ($alert) { $alert.title = $title }
        $timeout = Get-RequestTimeout $prefs
        $id = New-Request 'permission' $cwd $sid $timeout @{
            tool        = $tool
            description = $desc
            detail      = $detail
            title       = $title
            change      = New-ChangeInfo $tool $in
            suggestions = $offered
            noCountdown = ([int]$prefs.closeAfter -eq 0)
        }
        try { $res = Wait-Response $id $timeout (Get-AlertSecs $prefs) $alert $logTag } finally { Remove-Request $id }

        $decision = if ($res) { [string]$res.decision } else { $null }
        Write-HookLog ("$logTag $tool -> " + $(if ($decision) { $decision } else { $script:waitEnd }))
        $action = Get-AlertAction $res $script:waitEnd
        # Already alerted while on the card: no second alert nor a wait marker for the same request
        if ($alert -and $action -and -not $script:alertQueued) { Send-RequestAlert $alert $action $logTag $transcript }
        if ($decision -eq 'allowAlways') {
            # Only the index counts: the content comes from Claude Code's own suggestions of this request
            $index = -1
            if ([int]::TryParse([string]$res.index, [ref]$index) -and (@($offered | Where-Object { $_.index -eq $index }).Count -gt 0)) {
                $chosen = @($evt.permission_suggestions)[$index]
                return ConvertTo-AsciiJson (New-PermissionOutput 'allow' '' @(ConvertTo-UpdatedPermission $chosen))
            }
            return ConvertTo-AsciiJson (New-PermissionOutput 'allow' '')
        }
        if ($decision -in @('allow', 'deny')) { return ConvertTo-AsciiJson (New-PermissionOutput $decision $S.deniedMessage) }
        return $null
    }

    return $null
}

# Loaded with dot-source (tests): stop here, only the functions above are wanted
if ($MyInvocation.InvocationName -eq '.') { return }

if ($EnsureWidget) { [void](Start-Widget); exit 0 }

[Console]::InputEncoding = [Text.Encoding]::UTF8
# Not "$data": PowerShell variable names are case-insensitive and $Data is the data folder
try { $evt = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
$out = Invoke-Hook $evt
if ($out) { $out }
exit 0
