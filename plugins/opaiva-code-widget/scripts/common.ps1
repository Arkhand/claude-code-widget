# opaiva-code-widget: helpers shared by hook.ps1 and widget.ps1 (Windows PowerShell 5.1).
# Both load it with:  . (Join-Path $PSScriptRoot 'common.ps1')
# Loading it only defines functions: no files, folders or preferences are touched.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

function Get-Utf8NoBom { New-Object System.Text.UTF8Encoding $false }

# One widget per data dir. hook.ps1 checks this name to know whether the widget is running, also
# one started by an older version: never change how it is computed.
function Get-MutexName([string]$Dir) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Dir.ToLowerInvariant())) } finally { $sha.Dispose() }
    return 'Local\ClaudeCodeWidget-' + (($hash[0..5] | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Write to .tmp, then rename: readers never see a half-written file. Create-only by default (the rename
# fails if $Path exists). -Replace swaps in over an existing file atomically, and the old file is only
# touched after the new one was written in full, so a failed write keeps it.
function Write-JsonAtomic([string]$Path, $Object, [switch]$Replace) {
    [IO.File]::WriteAllText("$Path.tmp", ($Object | ConvertTo-Json -Depth 10 -Compress), (Get-Utf8NoBom))
    if ($Replace -and (Test-Path -LiteralPath $Path)) { [IO.File]::Replace("$Path.tmp", $Path, [NullString]::Value) }
    else { [IO.File]::Move("$Path.tmp", $Path) }
}

# 'pt' or 'en'. Empty = the Windows display language; anything that is not Portuguese is English.
function Resolve-Lang([string]$Requested) {
    $lang = if ($Requested) { $Requested } else { [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
    if ($lang -in @('pt', 'es')) { return $lang.ToLowerInvariant() }
    return 'en'
}

# UI text for one language, from strings.json next to this file (read explicitly as UTF-8)
function Get-Strings([string]$Lang) {
    $json = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'strings.json'), (Get-Utf8NoBom))
    return ($json | ConvertFrom-Json).$Lang
}

# The "env" block of a Claude Code settings.json, as name -> string value. Never throws: a missing file, bad
# JSON or no env block gives an empty table. The widget needs this because hook.ps1 starts it through WMI,
# which does not pass the hook's environment on, so CLAUDE_WIDGET_* set in settings.json never reach it.
function Get-ClaudeSettingsEnv([string]$Path) {
    $result = @{}
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
        $json = [IO.File]::ReadAllText($Path, (Get-Utf8NoBom)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $envBlock = $json.env
        if ($envBlock -isnot [System.Management.Automation.PSCustomObject]) { return $result }
        foreach ($p in $envBlock.PSObject.Properties) { $result[$p.Name] = [string]$p.Value }
    } catch { $result = @{} }
    return $result
}

function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# Requests waiting for an answer, oldest first. Deletes orphans: expired, or the hook that wrote
# them is gone (session interrupted). Skips requests already answered (res-<id>.json), waiting for
# the hook to pick the answer up. $Cache (file name -> request) avoids re-reading files.
function Get-PendingRequests([string]$Queue, [hashtable]$Cache) {
    $now = Get-NowMs
    $list = New-Object System.Collections.ArrayList
    $names = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Queue -Filter 'req-*.json' -File -ErrorAction SilentlyContinue)) {
        $names[$f.Name] = $true
        $r = $Cache[$f.Name]
        if (-not $r) {
            try { $r = [IO.File]::ReadAllText($f.FullName, (Get-Utf8NoBom)) | ConvertFrom-Json } catch { continue }
            $Cache[$f.Name] = $r
        }
        $expired = ($now - [int64]$r.created) -gt (([int64]$r.timeout + 5) * 1000)
        $alive = $null -ne (Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue)
        if ($expired -or -not $alive) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $Queue "res-$($r.id).json")) { continue }
        [void]$list.Add($r)
    }
    foreach ($k in @($Cache.Keys)) { if (-not $names.ContainsKey($k)) { $Cache.Remove($k) } }
    return $list | Sort-Object { [int64]$_.created }
}

# "Claude finished" notices, newest first, each with key (file name) and file (full path).
# Deletes notices older than $MaxAgeMs. $Cache (file name -> notice) avoids re-reading files.
function Get-DoneNotices([string]$Queue, [hashtable]$Cache, [int64]$MaxAgeMs) {
    $now = Get-NowMs
    $list = New-Object System.Collections.ArrayList
    $names = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Queue -Filter 'done-*.json' -File -ErrorAction SilentlyContinue)) {
        $names[$f.Name] = $true
        $d = $Cache[$f.Name]
        if (-not $d) {
            try { $d = [IO.File]::ReadAllText($f.FullName, (Get-Utf8NoBom)) | ConvertFrom-Json } catch { continue }
            $d | Add-Member -NotePropertyName key -NotePropertyValue $f.Name -Force
            $d | Add-Member -NotePropertyName file -NotePropertyValue $f.FullName -Force
            $Cache[$f.Name] = $d
        }
        if (($now - [int64]$d.created) -gt $MaxAgeMs) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        [void]$list.Add($d)
    }
    foreach ($k in @($Cache.Keys)) { if (-not $names.ContainsKey($k)) { $Cache.Remove($k) } }
    return $list | Sort-Object -Property { [int64]$_.created } -Descending
}

# Keys of the finished notices whose session window is the one in front: you are looking at that reply, so it
# should close. Pure (callers wrap the call in @()). A window unknown at the time (hwnd 0) never matches, and
# neither does a Claude desktop app notice: one window serves every session, so being in front says nothing
# about which session you are reading. Notices written before desktopApp existed have none: not a desktop app.
function Get-NoticesInFront($Notices, [int64]$ForegroundHwnd) {
    if ($ForegroundHwnd -eq 0) { return @() }
    $keys = New-Object System.Collections.ArrayList
    foreach ($n in @($Notices)) {
        if (-not $n -or [bool]$n.desktopApp) { continue }
        if ([int64]$n.hwnd -eq $ForegroundHwnd) { [void]$keys.Add([string]$n.key) }
    }
    return [string[]]$keys.ToArray()
}

# Appends "<date>T<time> <text>" to a log file (UTF-8). Past $MaxBytes the file first becomes
# <file>.old (replacing the previous one), so a log never grows past about twice $MaxBytes.
# Never throws: a log that cannot be written must not stop the hook or the widget.
function Write-LogLine([string]$Path, [string]$Text, [int64]$MaxBytes = 256KB) {
    try {
        $dir = [IO.Path]::GetDirectoryName($Path)
        if ($dir) { [void][IO.Directory]::CreateDirectory($dir) }
        $file = [IO.FileInfo]::new($Path)
        if ($file.Exists -and $file.Length -gt $MaxBytes) {
            [IO.File]::Delete("$Path.old")
            [IO.File]::Move($Path, "$Path.old")
        }
        [IO.File]::AppendAllText($Path, ('{0:s} {1}' -f (Get-Date), $Text) + "`r`n", (Get-Utf8NoBom))
    } catch {}
}

# Does a window title name this project as a whole part of it? VS Code titles read
# "[<dot> ]file - folder[ (Workspace)][ [WSL: Ubuntu]] - Visual Studio Code", so "widget" matches the
# folder "widget" but not "claude-code-widget" nor a file "widget.ps1". Letter case is ignored.
# (The unsaved-file dot goes in as the character itself: its regex escape (backslash, u, 25CF) does not match in .NET here.)
function Test-TitleHasProject([string]$Title, [string]$Project) {
    if (-not $Title -or -not $Project) { return $false }
    $dot = [regex]::Escape([string][char]0x25CF)
    $pattern = '(?i)(^|\s-\s)(' + $dot + '\s*)?' + [regex]::Escape($Project) + '(\s[(\[][^)\]]*[)\]])*(\s-\s|$)'
    return [regex]::IsMatch($Title, $pattern)
}

# Work area (screen minus taskbar) of each monitor, in WPF units, read fresh on every call:
# @{ left; top; right; bottom; primary }. Used by widget.ps1. Pixels are converted with the main
# monitor's width in pixels against WPF's width for it, both read now, so the areas match WPF's
# coordinates whether or not this process is DPI aware. (System.Windows.Forms.Screen is not used:
# it keeps the main screen's bounds from its first use and can disagree with its own work areas.)
function Get-ScreenAreas {
    Add-Type -AssemblyName PresentationFramework
    $dips = [System.Windows.SystemParameters]::PrimaryScreenWidth
    if (-not ('ClaudeWidget.Monitors' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace ClaudeWidget {
    public static class Monitors {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
        delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
        // One entry per monitor, in pixels: work area left, top, right, bottom; monitor width; 1 = main screen
        public static List<int[]> List() {
            var list = new List<int[]>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (m, hdc, r, d) => {
                var info = new MONITORINFO();
                info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                if (GetMonitorInfo(m, ref info)) {
                    list.Add(new int[] { info.rcWork.Left, info.rcWork.Top, info.rcWork.Right, info.rcWork.Bottom,
                        info.rcMonitor.Right - info.rcMonitor.Left, (info.dwFlags & 1) != 0 ? 1 : 0 });
                }
                return true;
            }, IntPtr.Zero);
            return list;
        }
    }
}
'@
    }
    $monitors = [ClaudeWidget.Monitors]::List()
    $mainWidth = 0
    foreach ($m in $monitors) { if ($m[5] -eq 1) { $mainWidth = $m[4] } }
    $scale = if ($mainWidth -gt 0 -and $dips -gt 0) { $mainWidth / $dips } else { 1.0 }
    foreach ($m in $monitors) {
        @{ left = $m[0] / $scale; top = $m[1] / $scale; right = $m[2] / $scale; bottom = $m[3] / $scale; primary = ($m[5] -eq 1) }
    }
}

# Text that changes whenever a monitor is added, removed, moved or resized, or the taskbar moves
function Get-ScreenKey($Areas) {
    return (@($Areas | Where-Object { $_ }) | ForEach-Object {
            '{0},{1},{2},{3},{4}' -f $_.left, $_.top, $_.right, $_.bottom, [bool]$_.primary }) -join ';'
}

# Where the widget's bottom-right corner goes: the saved spot (@{ right; bottom }, e.g. from
# state.json) while it is on one of the screens, else the main screen's bottom-right corner.
# Returns @{ right; bottom; saved }, or $null without any screen.
function Resolve-Anchor($Saved, $Areas) {
    $list = @($Areas | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }
    if ($Saved -and $null -ne $Saved.right -and $null -ne $Saved.bottom) {
        $r = [double]$Saved.right
        $b = [double]$Saved.bottom
        foreach ($a in $list) {
            # At least a 120 x 60 corner of the widget on that screen
            if ($r -gt $a.left + 120 -and $r -le $a.right + 1 -and $b -gt $a.top + 60 -and $b -le $a.bottom + 1) {
                return @{ right = $r; bottom = $b; saved = $true }
            }
        }
    }
    $main = $list[0]
    foreach ($a in $list) { if ($a.primary) { $main = $a; break } }
    return @{ right = [double]$main.right; bottom = [double]$main.bottom; saved = $false }
}

# The session's title as Claude Code shows it: the name given with /rename (custom-title), else the
# automatic one (ai-title). Both are repeated in the transcript every few turns, so the last 512 KB
# are enough. Empty when there is none or the transcript cannot be read.
function Get-SessionTitle([string]$TranscriptPath, [string]$SessionId) {
    if (-not $TranscriptPath) { return '' }
    try {
        $fs = [IO.File]::Open($TranscriptPath, 'Open', 'Read', 'ReadWrite')
        try {
            $start = [math]::Max([int64]0, $fs.Length - [int64]512KB)
            [void]$fs.Seek($start, 'Begin')
            $buf = New-Object byte[] ([int]($fs.Length - $start))
            $n = 0
            while ($n -lt $buf.Length) {
                $read = $fs.Read($buf, $n, $buf.Length - $n)
                if ($read -le 0) { break }
                $n += $read
            }
        }
        finally { $fs.Dispose() }
        $lines = [Text.Encoding]::UTF8.GetString($buf, 0, $n) -split "`n"
        # Reading from the middle of the file: the first line is cut
        if ($start -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
        $custom = ''
        $auto = ''
        foreach ($line in $lines) {
            if ($line.IndexOf('"custom-title"') -lt 0 -and $line.IndexOf('"ai-title"') -lt 0) { continue }
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if ($o.sessionId -and $SessionId -and [string]$o.sessionId -ne $SessionId) { continue }
            if ($o.type -eq 'custom-title' -and $o.customTitle) { $custom = [string]$o.customTitle }
            elseif ($o.type -eq 'ai-title' -and $o.aiTitle) { $auto = [string]$o.aiTitle }
        }
        if ($custom) { return $custom.Trim() }
        return $auto.Trim()
    } catch { return '' }
}

# Sessions working right now, read from the busy\<session>.json files the hook keeps: those whose
# Claude process runs (or is unknown, pid 0), that started less than $MaxAgeMs ago and whose
# transcript (when known) was written in the last $QuietMs. Files of the others are removed.
# Returns { id; pid; since; cwd; transcript } objects.
function Get-BusySessions([string]$BusyDir, [int64]$MaxAgeMs, [int64]$QuietMs) {
    $now = Get-NowMs
    foreach ($f in @(Get-ChildItem -LiteralPath $BusyDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $alive = $false
        $b = $null
        try {
            $b = [IO.File]::ReadAllText($f.FullName, (Get-Utf8NoBom)) | ConvertFrom-Json
            $alive = (($now - [int64]$b.since) -lt $MaxAgeMs) -and
                ([int]$b.pid -eq 0 -or $null -ne (Get-Process -Id ([int]$b.pid) -ErrorAction SilentlyContinue))
            $transcript = [string]$b.transcript
            if ($alive -and $transcript -and (Test-Path -LiteralPath $transcript)) {
                # (not $quietMs: variable names are case-insensitive, it would replace the parameter)
                $silentMs = ([DateTime]::UtcNow - (Get-Item -LiteralPath $transcript).LastWriteTimeUtc).TotalMilliseconds
                if ($silentMs -gt $QuietMs) { $alive = $false }
            }
        } catch {}
        if ($alive) {
            [pscustomobject]@{ id = $f.BaseName; pid = [int]$b.pid; since = [int64]$b.since; cwd = [string]$b.cwd; transcript = [string]$b.transcript }
        }
        else { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
}

# Seconds since the last mouse or keyboard input on this PC (0 when Windows cannot tell). hook.ps1 and the
# widget both ask it whether you are away.
function Get-IdleSeconds {
    try {
        if (-not ('ClaudeWidget.Idle' -as [type])) {
            Add-Type -Namespace ClaudeWidget -Name Idle -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
public static uint Seconds() {
    var info = new LASTINPUTINFO();
    info.cbSize = (uint)Marshal.SizeOf(info);
    if (!GetLastInputInfo(ref info)) return 0;
    return ((uint)Environment.TickCount - info.dwTime) / 1000;
}
'@
        }
        return [int][ClaudeWidget.Idle]::Seconds()
    } catch { return 0 }
}

# CLAUDE_WIDGET_AWAY_SECS as the seconds without input that count as away: a whole number from 0 (always away,
# which the tests use); anything else, or nothing, gives the default of 5 minutes
function ConvertTo-AwaySecs([string]$Text) {
    $n = 0
    if ([int]::TryParse($Text, [ref]$n) -and $n -ge 0) { return $n }
    return 300
}

# "Do not disturb" is the file dnd.flag in the data folder: hook.ps1 reads it to send requests to
# VS Code, and the widget reads it to hide itself
function Test-Dnd([string]$Dir) { Test-Path -LiteralPath (Join-Path $Dir 'dnd.flag') }

function Set-Dnd([string]$Dir, [bool]$On) {
    try {
        $path = Join-Path $Dir 'dnd.flag'
        if ($On) {
            [void][IO.Directory]::CreateDirectory($Dir)
            [IO.File]::WriteAllText($path, '')
        }
        else { [IO.File]::Delete($path) }
    } catch {}
}

# "project . session title" for chips and the sessions list: the title is cut at 40 characters
# (without splitting an emoji); either part may be missing
function Format-SessionLine([string]$Cwd, [string]$Title) {
    $text = if ($Cwd) { Split-Path -Leaf $Cwd } else { '' }
    $title = if ($Title) { $Title.Trim() } else { '' }
    if ($title.Length -gt 40) {
        $cut = 39
        if ([char]::IsHighSurrogate($title[$cut - 1])) { $cut = 38 }
        $title = $title.Substring(0, $cut) + '...'
    }
    if ($title) { $text = if ($text) { $text + ' ' + [char]0x00B7 + ' ' + $title } else { $title } }
    return $text
}

# Lines of text, with Windows or Unix line endings; an empty text has none
function Split-TextLines([string]$Text) {
    if (-not $Text) { return @() }
    $lines = @(($Text -replace "`r`n", "`n") -split "`n")
    # A text that ends with a newline has no extra empty last line
    if ($lines.Count -gt 1 -and $lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }
    return $lines
}

# What to show on a permission card for a file change: a list of { kind; text } with kind add, del
# or more (text = how many lines were left out). An edit shows what left and what came in, without
# the lines that are equal at the start and at the end; a written file shows all its lines as added.
# At most 14 lines in total.
function Get-DiffLines($Change) {
    $all = New-Object System.Collections.ArrayList
    if ($Change -and $Change.kind -eq 'write') {
        foreach ($l in @(Split-TextLines ([string]$Change.content))) { [void]$all.Add([pscustomobject]@{ kind = 'add'; text = $l }) }
    }
    elseif ($Change) {
        foreach ($edit in @($Change.edits)) {
            $old = @(Split-TextLines ([string]$edit.old))
            $new = @(Split-TextLines ([string]$edit.new))
            $head = 0
            while ($head -lt $old.Count -and $head -lt $new.Count -and $old[$head] -ceq $new[$head]) { $head++ }
            $tail = 0
            while ($tail -lt $old.Count - $head -and $tail -lt $new.Count - $head -and $old[$old.Count - 1 - $tail] -ceq $new[$new.Count - 1 - $tail]) { $tail++ }
            for ($i = $head; $i -lt $old.Count - $tail; $i++) { [void]$all.Add([pscustomobject]@{ kind = 'del'; text = $old[$i] }) }
            for ($i = $head; $i -lt $new.Count - $tail; $i++) { [void]$all.Add([pscustomobject]@{ kind = 'add'; text = $new[$i] }) }
        }
    }
    $shown = @($all | Select-Object -First 14)
    $shown
    if ($all.Count -gt 14) { [pscustomobject]@{ kind = 'more'; text = [string]($all.Count - 14) } }
    # Edits the hook left out (it keeps at most 5)
    if ($Change -and [int]$Change.droppedEdits -gt 0) { [pscustomobject]@{ kind = 'edits'; text = [string][int]$Change.droppedEdits } }
}

# "Ctrl+Alt+Y" -> @{ mod; vk } for RegisterHotKey (mod includes MOD_NOREPEAT, 0x4000); $null when the
# text is not a valid hotkey: modifiers Ctrl, Alt, Shift, Win (at least one) and one key A-Z, 0-9 or F1-F24
function ConvertTo-Hotkey([string]$Text) {
    if (-not $Text) { return $null }
    $mod = 0x4000
    $vk = 0
    foreach ($part in ($Text -split '\+')) {
        $p = $part.Trim().ToUpperInvariant()
        if ($p -eq 'CTRL') { $mod = $mod -bor 2 }
        elseif ($p -eq 'ALT') { $mod = $mod -bor 1 }
        elseif ($p -eq 'SHIFT') { $mod = $mod -bor 4 }
        elseif ($p -eq 'WIN') { $mod = $mod -bor 8 }
        elseif ($vk -ne 0) { return $null }
        elseif ($p -match '^[A-Z0-9]$') { $vk = [int][char]$p }
        elseif ($p -match '^F([1-9]|1[0-9]|2[0-4])$') { $vk = 0x6F + [int]$Matches[1] }
        else { return $null }
    }
    if ($vk -eq 0 -or ($mod -band 0xF) -eq 0) { return $null }
    return @{ mod = $mod; vk = $vk }
}

# A permission rule as Claude Code writes it: Tool(content), or just Tool. Rules arrive as objects
# { toolName; ruleContent } (a plain string is kept as it is). Never throws; unknown input gives ''.
function Format-RuleText($Rule) {
    try {
        if ($null -eq $Rule) { return '' }
        if ($Rule -is [string]) { return $Rule }
        $tool = [string]$Rule.toolName
        if (-not $tool) { return '' }
        $content = [string]$Rule.ruleContent
        if ($content) { return "$tool($content)" }
        return $tool
    } catch { return '' }
}


# ---------------- Preferences (prefs.json) and theme ----------------

function Get-DefaultPrefs { @{ theme = 'dark'; opacity = 1.0; volume = 100; scale = 1.0; minimal = $false; notifyAfter = 5; telegram = $false; closeAfter = 5 } }

# prefs.json in the data dir. Always returns a complete, valid set: a missing file gives the defaults,
# and each bad field falls back to its default on its own.
function Read-Prefs([string]$Dir) {
    $p = Get-DefaultPrefs
    $j = $null
    $path = Join-Path $Dir 'prefs.json'
    # Save-Prefs swaps the file in with one rename, but a reader can still find it locked for a moment then:
    # try again shortly instead of falling back to the defaults (Telegram off). A missing file is the defaults.
    $text = $null
    for ($try = 1; $try -le 5 -and $null -eq $text; $try++) {
        if (-not (Test-Path -LiteralPath $path)) { break }
        try { $text = [IO.File]::ReadAllText($path, (Get-Utf8NoBom)) } catch { if ($try -lt 5) { Start-Sleep -Milliseconds 20 } }
    }
    try { if ($null -ne $text) { $j = $text | ConvertFrom-Json } } catch { return $p }
    if ($null -eq $j) { return $p }
    $num = {
        param($v)
        $n = 0.0
        if ($null -ne $v -and $v -isnot [bool] -and [double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and
            -not [double]::IsNaN($n) -and -not [double]::IsInfinity($n)) { return $n }
        return $null
    }
    if ($j.theme -is [string] -and @('dark', 'light', 'auto') -contains $j.theme) { $p.theme = $j.theme }
    $n = & $num $j.opacity
    if ($null -ne $n) { $p.opacity = [math]::Min(1.0, [math]::Max(0.5, $n)) }
    $n = & $num $j.volume
    if ($null -ne $n) { $p.volume = [int][math]::Min(100, [math]::Max(0, [math]::Round($n))) }
    $n = & $num $j.scale
    if ($null -ne $n) {
        $best = 1.0
        foreach ($c in 1.0, 1.25, 1.5) { if ([math]::Abs($c - $n) -lt [math]::Abs($best - $n)) { $best = $c } }
        $p.scale = $best
    }
    if ($j.minimal -is [bool]) { $p.minimal = $j.minimal }
    # Minutes of absence before a Telegram alert: only 1, 3 or 5 (no snapping to the nearest, unlike scale)
    $n = & $num $j.notifyAfter
    if ($null -ne $n -and @(1, 3, 5) -contains $n) { $p.notifyAfter = [int]$n }
    if ($j.telegram -is [bool]) { $p.telegram = $j.telegram }
    # Minutes before a card or a finished notice closes by itself; 0 = never
    $n = & $num $j.closeAfter
    if ($null -ne $n -and @(0, 1, 3, 5, 15, 30) -contains $n) { $p.closeAfter = [int]$n }
    return $p
}

# Overwrites prefs.json. Returns $false (never throws) when it cannot write.
function Save-Prefs([string]$Dir, $Prefs) {
    try {
        $o = [ordered]@{ theme = [string]$Prefs.theme; opacity = [double]$Prefs.opacity; volume = [int]$Prefs.volume; scale = [double]$Prefs.scale; minimal = [bool]$Prefs.minimal; notifyAfter = [int]$Prefs.notifyAfter; telegram = [bool]$Prefs.telegram
            # A missing value is the default, not 0 (= never)
            closeAfter = $(if ($null -ne $Prefs.closeAfter) { [int]$Prefs.closeAfter } else { 5 }) }
        $path = Join-Path $Dir 'prefs.json'
        # Whole file at once: a crash in the middle never leaves half a prefs.json
        [IO.File]::WriteAllText("$path.tmp", ($o | ConvertTo-Json -Compress), (Get-Utf8NoBom))
        # Then one rename over the old file (MoveFileEx, replace existing): a hook reading meanwhile finds the old
        # file or the new one, never none (it would get the defaults, Telegram off). Delete-then-move and
        # [IO.File]::Replace both leave a moment without the name. A reader holding the file open blocks the
        # rename for a moment: try again shortly.
        Add-Type -AssemblyName Microsoft.VisualBasic
        for ($try = 1; ; $try++) {
            try { [Microsoft.VisualBasic.FileIO.FileSystem]::MoveFile("$path.tmp", $path, $true); break }
            catch { if ($try -ge 5) { throw }; Start-Sleep -Milliseconds 20 }
        }
        return $true
    } catch { return $false }
}

# How long a card or a finished notice stays before it closes by itself (closeAfter), in ms. Never (0) gives
# $NeverMs: by default the hook's own limit for a card (60 minutes; hooks.json allows 3630 s).
function Get-CloseAfterMs($Prefs, [int64]$NeverMs = 3600000) {
    $m = [int64]$Prefs.closeAfter
    if ($m -le 0) { return $NeverMs }
    return $m * 60000
}

# A finished notice closes by itself at closeAfter; with Never it stays up to 12 h (as before 2.6.0)
function Get-NoticeMaxAgeMs($Prefs) { return Get-CloseAfterMs $Prefs (12 * 3600 * 1000) }

# The age at which a finished notice still open alerts: notifyAfter, or 15 s before it closes by itself when that
# comes first (room for the batch window and the 2 s rounds), or it would be gone before it could ever alert
function Get-NoticeAlertMs($Prefs) {
    return [int64][math]::Min([int64]$Prefs.notifyAfter * 60000, (Get-NoticeMaxAgeMs $Prefs) - 15000)
}

# The card's "closes in m:ss" ($Format takes minutes and seconds), or '' for a request that never closes by itself
function Format-Countdown($Request, [int64]$NowMs, [string]$Format) {
    if ($Request.noCountdown) { return '' }
    $left = [int]$Request.timeout - [int](($NowMs - [int64]$Request.created) / 1000)
    if ($left -lt 0) { $left = 0 }
    return $Format -f [math]::Floor($left / 60), ($left % 60)
}

# True when Windows apps use the light theme (HKCU ...\Themes\Personalize\AppsUseLightTheme = 1)
function Get-WindowsLightTheme {
    try {
        $v = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        return ($v.AppsUseLightTheme -eq 1)
    } catch { return $false }
}

# 'dark' or 'light' from the saved choice ('auto' follows Windows)
function Resolve-Theme([string]$Theme, [bool]$WindowsIsLight = $false) {
    if ($Theme -eq 'light') { return 'light' }
    if ($Theme -eq 'auto' -and $WindowsIsLight) { return 'light' }
    return 'dark'
}

# The widget is written in the dark colors. A theme is a map "dark color -> this theme's color"; the
# dark theme is the empty map. Colors without an entry (white on the orange buttons, the orange accent,
# the green of the finished notice) are the same in every theme. Values must be unique and never also
# a key, so that going back (theme color -> dark color) is unambiguous: Get-ColorMap's tests enforce it.
function Get-ColorMap([string]$Theme) {
    if ($Theme -ne 'light') { return @{} }
    return @{
        '#1E1E22' = '#FAFAFB'; '#34343B' = '#D9D9DF'; '#4A4A54' = '#B8B8C2'; '#5FB98A' = '#2F9A66'
        '#E8E8EC' = '#1F1F24'; '#7E7E88' = '#6A6A74'; '#F4F4F6' = '#17171A'; '#8A8A93' = '#70707C'
        '#3A2A24' = '#FBE6DC'; '#F0A58A' = '#B4502A'; '#26262C' = '#ECECF0'; '#C8C8D0' = '#3A3A44'
        '#2E2A1E' = '#FBF1D2'; '#E8C770' = '#8A6A10'; '#DADAE0' = '#2A2A32'; '#141417' = '#F1F1F4'
        '#2C2C33' = '#DCDCE2'; '#6E6E78' = '#7C7C86'; '#6A3A3A' = '#E3A8A8'; '#F29090' = '#B03A3A'
        '#2A2A30' = '#E6E6EB'; '#3A3A42' = '#CFCFD6'; '#7AA2F7' = '#3E6BD6'; '#1F2E26' = '#DDF1E6'
        '#7FD1A4' = '#1F7A4C'; '#3A1E1E' = '#FBE3E3'; '#1E3A2A' = '#DDF3E5'; '#7FD3A0' = '#1B7545'
        '#24242A' = '#F3F3F6'; '#F0F0F4' = '#202028'; '#9A9AA4' = '#5E5E68'; '#22304A' = '#DCE6FB'
        '#9DB8F5' = '#2F57B8'
    }
}

# The color a map gives to $Hex (case-insensitive); unchanged when it has no entry
function Convert-ThemeColor([string]$Hex, [hashtable]$Map) {
    if ($Map -and $Map.ContainsKey($Hex)) { return $Map[$Hex] }
    return $Hex
}

# The scale to really use: the chosen one, lowered (never below 0.5) so that a card $UnscaledHeight tall
# (at 100%, margins included) still fits a work area $WorkHeight tall. Rounded down to 2 decimals.
function Get-FitScale([double]$Pref, [double]$UnscaledHeight, [double]$WorkHeight) {
    if ($UnscaledHeight -le 0 -or $WorkHeight -le 0) { return $Pref }
    $max = $WorkHeight / $UnscaledHeight
    if ($max -ge $Pref) { return $Pref }
    return [math]::Max(0.5, [math]::Floor($max * 100 + 1e-9) / 100)
}


# Version of a plugin script: the cache folder name (...\opaiva-code-widget\2.4.0\scripts\x.ps1), else
# the version in plugin.json next to the scripts folder, else $null
function Get-ScriptVersion([string]$ScriptPath) {
    if ($ScriptPath -match '\\(\d+\.\d+\.\d+)\\scripts\\[^\\]+$') { return [version]$Matches[1] }
    try {
        $json = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptPath)) '.claude-plugin\plugin.json'
        if (Test-Path -LiteralPath $json) {
            $v = ([IO.File]::ReadAllText($json, (Get-Utf8NoBom)) | ConvertFrom-Json).version
            if ($v) { return [version][string]$v }
        }
    } catch {}
    return $null
}

# Should a hook running $OwnScript replace the widget running $RunningScript? Only when the widget is
# older: a session still on an old plugin version must not downgrade a widget a newer one started.
# Unknown versions keep the old behavior (replace).
function Test-WidgetOlder([string]$RunningScript, [string]$OwnScript) {
    $running = Get-ScriptVersion $RunningScript
    $own = Get-ScriptVersion $OwnScript
    if ($running -and $own) { return ($running -lt $own) }
    return $true
}


# ---------------- Telegram connection (telegram.json) ----------------

# The token is encrypted with DPAPI (ConvertFrom-SecureString without a key): only this Windows user on this PC
# can read it back, so the file is useless if it is copied or committed. chat, bot and name are not secret.
# Returns $false (never throws) when it cannot write.
function Save-TelegramConfig([string]$Dir, [string]$Token, [string]$Chat, [string]$Bot, [string]$Name) {
    try {
        $secure = ConvertTo-SecureString -String $Token -AsPlainText -Force
        $o = [ordered]@{ token = (ConvertFrom-SecureString -SecureString $secure); chat = $Chat; bot = $Bot; name = $Name }
        $path = Join-Path $Dir 'telegram.json'
        # -Replace: if the write fails the previous connection stays, the user is not silently disconnected
        Write-JsonAtomic $path $o -Replace
        return $true
    } catch { return $false }
}

# The saved connection with the token decrypted, or $null for a missing, broken or undecryptable file
# (for example one copied from another user or PC). Only the sender and the setup wizard call this.
function Read-TelegramConfig([string]$Dir) {
    try {
        $path = Join-Path $Dir 'telegram.json'
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $j = [IO.File]::ReadAllText($path, (Get-Utf8NoBom)) | ConvertFrom-Json
        if (-not $j -or -not $j.token) { return $null }
        $secure = ConvertTo-SecureString -String ([string]$j.token)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        return @{ token = $token; chat = [string]$j.chat; bot = [string]$j.bot; name = [string]$j.name }
    } catch { return $null }
}

# Disconnects: deletes telegram.json. A missing file is fine.
function Remove-TelegramConfig([string]$Dir) {
    try { Remove-Item -LiteralPath (Join-Path $Dir 'telegram.json') -Force -ErrorAction SilentlyContinue } catch {}
}

# Is Telegram set up and switched on? Cheap on purpose (the hook asks on every event): it only checks that
# the file exists and the preference is on, it never decrypts.
function Test-TelegramReady([string]$Dir, $Prefs) {
    return [bool]($Prefs -and $Prefs.telegram -and (Test-Path -LiteralPath (Join-Path $Dir 'telegram.json')))
}

# ---------------- Telegram alerts (queue files and the decision) ----------------

# The hook writes four kinds of small files in the queue folder and never touches the network:
#   tg-<id>.json        send this now (the hook already decided: request still unanswered at X, timed out, went
#                       idle, or you are away)
#   wait-<session>.json the session waits in VS Code: send only if it is still waiting at X and you are away
#   seen-<session>.json the session moved on (any later hook event)
#   alerted-<session>.json { session; at }: the hook queued a tg- entry for this session at that time (Unix
#                       ms). A Notification with no seen- newer than it is the same prompt: no wait marker.
# The widget reads them and asks Get-DueAlerts what to send.

# The same cleaning hook.ps1 gives a session id before it goes into a file name
function Get-SafeSessionId([string]$Session) { return ($Session -replace '[^A-Za-z0-9-]', '') }

# Queues an alert to send now. Returns the entry id.
function Add-AlertOutbox([string]$Queue, [hashtable]$Item) {
    [void][IO.Directory]::CreateDirectory($Queue)
    $id = [guid]::NewGuid().ToString('N')
    $created = if ($Item.created) { [int64]$Item.created } else { Get-NowMs }
    Write-JsonAtomic (Join-Path $Queue "tg-$id.json") ([ordered]@{
        id      = $id
        kind    = [string]$Item.kind
        session = Get-SafeSessionId $Item.session
        cwd     = [string]$Item.cwd
        title   = [string]$Item.title
        detail  = [string]$Item.detail
        reason  = [string]$Item.reason
        created = $created
    })
    return $id
}

# Marks that a session waits in VS Code. One marker per session: the newest replaces the older one.
function Set-WaitMarker([string]$Queue, [hashtable]$Item) {
    [void][IO.Directory]::CreateDirectory($Queue)
    $sid = Get-SafeSessionId $Item.session
    $created = if ($Item.created) { [int64]$Item.created } else { Get-NowMs }
    Write-JsonAtomic (Join-Path $Queue "wait-$sid.json") ([ordered]@{
        session = $sid
        kind    = [string]$Item.kind
        cwd     = [string]$Item.cwd
        title   = [string]$Item.title
        detail  = [string]$Item.detail
        created = $created
    }) -Replace
}

# The session moved on: drops its wait marker and leaves a stamp the widget uses to mark a sent alert as resolved.
# The marker goes first so that a failed stamp can never leave a false alert pending.
function Set-SessionSeen([string]$Queue, [string]$Session) {
    [void][IO.Directory]::CreateDirectory($Queue)
    $sid = Get-SafeSessionId $Session
    Remove-Item -LiteralPath (Join-Path $Queue "wait-$sid.json") -Force -ErrorAction SilentlyContinue
    Write-JsonAtomic (Join-Path $Queue "seen-$sid.json") ([ordered]@{ session = $sid; at = Get-NowMs }) -Replace
}

# What to send now, oldest first (callers wrap the call in @(): zero or one result is not an array).
# Pure: the caller passes what it read from disk. $Outbox are tg-*.json entries, $Notices are Get-DoneNotices
# results, $Waits are wait-*.json markers, $Sent is the table of Read-SentAlerts. Each result is a hashtable:
# key (what goes into $Sent), source (req|done|wait), kind (permission|question|plan|done), session, cwd,
# title, detail, created, reason.
# $NoticeAfterMs (default $AfterMs) is the age at which a notice is due (for 60 s): the widget deletes notices at closeAfter,
# so it passes Get-NoticeAlertMs, or a notice would be gone before it could ever alert.
# This does not check that Telegram is connected: the caller only asks when it is.
function Get-DueAlerts($Outbox, $Notices, $Waits, $Sent, [int64]$NowMs, [int64]$AfterMs, [bool]$Away, [bool]$Dnd, [int64]$NoticeAfterMs = -1) {
    if (-not $PSBoundParameters.ContainsKey('NoticeAfterMs')) { $NoticeAfterMs = $AfterMs }
    $sentKeys = if ($Sent -is [hashtable]) { $Sent } else { @{} }
    $due = New-Object System.Collections.ArrayList

    # The hook decided already: due at once, but an entry that sat unsent for a long time is stale news
    foreach ($e in @($Outbox)) {
        if (-not $e) { continue }
        $created = [int64]$e.created
        if ($created -le 0 -or ($NowMs - $created) -gt (30 * 60 * 1000)) { continue }
        $key = "req:$($e.id)"
        if ($sentKeys.ContainsKey($key)) { continue }
        [void]$due.Add(@{ key = $key; source = 'req'; kind = [string]$e.kind; session = [string]$e.session; cwd = [string]$e.cwd
                          title = [string]$e.title; detail = [string]$e.detail; created = $created; reason = [string]$e.reason })
    }

    # A finished notice still open at X. In the Claude desktop app one window hosts every session, so being in
    # front says nothing there; with do not disturb the widget is hidden, so you did not see it either: both
    # only count when you are away. Due only around X (60 s covers the 2 s rounds and the batch window): a notice
    # whose moment passed (you were present, Telegram was off, the widget was not running) never alerts later.
    foreach ($n in @($Notices)) {
        if (-not $n) { continue }
        $created = [int64]$n.created
        $age = $NowMs - $created
        if ($created -le 0 -or $age -lt $NoticeAfterMs -or $age -ge $NoticeAfterMs + 60000) { continue }
        if (([bool]$n.desktopApp -or $Dnd) -and -not $Away) { continue }
        $key = "done:$($n.key)"
        if ($sentKeys.ContainsKey($key)) { continue }
        [void]$due.Add(@{ key = $key; source = 'done'; kind = 'done'; session = [string]$n.session; cwd = [string]$n.cwd
                          title = [string]$n.title; detail = [string]$n.message; created = $created; reason = '' })
    }

    # Waiting in VS Code: at X, and only if you are not at the computer
    foreach ($w in @($Waits)) {
        if (-not $w -or -not $Away) { continue }
        $created = [int64]$w.created
        if ($created -le 0 -or ($NowMs - $created) -lt $AfterMs) { continue }
        $key = "wait:$($w.session):$created"
        if ($sentKeys.ContainsKey($key)) { continue }
        [void]$due.Add(@{ key = $key; source = 'wait'; kind = [string]$w.kind; session = [string]$w.session; cwd = [string]$w.cwd
                          title = [string]$w.title; detail = [string]$w.detail; created = $created; reason = '' })
    }

    return $due | Sort-Object -Property { [int64]$_.created }
}

# Cuts to $Max characters with "..." at the end, without splitting an emoji
function Format-CutText([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    $cut = $Max - 3
    if ([char]::IsHighSurrogate($Text[$cut - 1])) { $cut-- }
    return $Text.Substring(0, $cut) + '...'
}

# The Telegram message for one or more alerts (Get-DueAlerts results): plain text, one block per alert (header,
# project and title, detail), blocks separated by a blank line. Telegram refuses more than 4096 characters, so
# what does not fit is left out and counted in a last line.
function Format-AlertText($Alerts, $S) {
    $max = 4096
    $headers = @{ permission = $S.tgPermission; question = $S.tgQuestion; done = $S.tgDone; plan = $S.tgPlan }
    $blocks = @(foreach ($a in @($Alerts)) {
        if (-not $a) { continue }
        $lines = @()
        $header = $headers[[string]$a.kind]
        if ($header) { $lines += $header }
        $session = Format-SessionLine ([string]$a.cwd) ([string]$a.title)
        if ($session) { $lines += $session }
        $detail = Format-CutText ([string]$a.detail).Trim() 200
        if ($detail) { $lines += $detail }
        $lines -join "`n"
    })
    $text = ''
    $shown = 0
    foreach ($block in $blocks) {
        # Room for the "+N more" line that follows if this block turns out to be the last one
        $left = $blocks.Count - $shown - 1
        $footer = if ($left -gt 0) { "`n`n" + ($S.tgMore -f $left) } else { '' }
        $next = if ($shown) { $text + "`n`n" + $block } else { $block }
        if (($next + $footer).Length -gt $max) {
            if ($shown) { break }
            # A single block that is too big alone (a huge project name): cut it
            $next = Format-CutText $block ($max - $footer.Length)
        }
        $text = $next
        $shown++
    }
    $left = $blocks.Count - $shown
    if ($left -gt 0) { $text += "`n`n" + ($S.tgMore -f $left) }
    return $text
}

# telegram-sent.json: what was already sent, key -> @{ message; session; at; resolved; text; edited }. message is
# the Telegram message id (alerts sent in one batch share it; $null while sending or when the send failed), text
# the message as sent and edited whether it was already edited to resolved. Entries older than a day are
# forgotten. Never throws.
function Read-SentAlerts([string]$Dir) {
    $result = @{}
    try {
        $path = Join-Path $Dir 'telegram-sent.json'
        if (-not (Test-Path -LiteralPath $path)) { return $result }
        $json = [IO.File]::ReadAllText($path, (Get-Utf8NoBom)) | ConvertFrom-Json
        $now = Get-NowMs
        foreach ($p in $json.PSObject.Properties) {
            $v = $p.Value
            if ($v -isnot [System.Management.Automation.PSCustomObject]) { continue }
            $at = [int64]0
            if (-not [int64]::TryParse([string]$v.at, [ref]$at)) { continue }
            if (($now - $at) -gt (24 * 60 * 60 * 1000)) { continue }
            $result[$p.Name] = @{ message = $v.message; session = [string]$v.session; at = $at; resolved = [bool]$v.resolved
                                  text = [string]$v.text; edited = [bool]$v.edited }
        }
    } catch { $result = @{} }
    return $result
}

# Saves the table. $false when it cannot write (the previous file stays): the caller must not send what it
# could not record, or a restart would send it again.
function Save-SentAlerts([string]$Dir, [hashtable]$Sent) {
    try {
        Write-JsonAtomic (Join-Path $Dir 'telegram-sent.json') $Sent -Replace
        return $true
    } catch { return $false }
}

# ---------------- Telegram sender helpers (used by the widget) ----------------

# The <Prefix>-*.json files of the queue folder (tg, wait, seen), each with its full path added as file. A file
# that cannot be read (broken, or being replaced right now) is skipped.
function Read-AlertFiles([string]$Queue, [string]$Prefix) {
    foreach ($f in @(Get-ChildItem -LiteralPath $Queue -Filter "$Prefix-*.json" -File -ErrorAction SilentlyContinue)) {
        try { $o = [IO.File]::ReadAllText($f.FullName, (Get-Utf8NoBom)) | ConvertFrom-Json } catch { continue }
        if (-not $o) { continue }
        $o | Add-Member -NotePropertyName file -NotePropertyValue $f.FullName -Force
        $o
    }
}

# Drops the outbox entries (tg-*.json) created before $BeforeMs. Telegram just became ready (connected, or
# Alerts on): what was queued before, while it was then turned off, is old news and must not go out now.
function Remove-AlertOutbox([string]$Queue, [int64]$BeforeMs) {
    foreach ($e in @(Read-AlertFiles $Queue 'tg')) {
        if ([int64]$e.created -lt $BeforeMs) { Remove-Item -LiteralPath $e.file -Force -ErrorAction SilentlyContinue }
    }
}

# The seen- stamps as session -> at (Unix ms)
function Get-SeenStamps([string]$Queue) {
    $t = @{}
    foreach ($s in @(Read-AlertFiles $Queue 'seen')) { if ($s.session) { $t[[string]$s.session] = [int64]$s.at } }
    return $t
}

# Leaves out alerts whose session moved on after they were created (its seen- stamp is newer): the hook deletes a
# wait marker on the next event, but a failed delete must not alert, and an outbox entry answered meanwhile is no
# news any more. Strictly newer: the hook event that writes an alert file stamps seen first, maybe in the same ms.
function Select-UnseenAlerts($Items, [hashtable]$Seen) {
    foreach ($i in @($Items)) {
        if (-not $i) { continue }
        $sid = [string]$i.session
        if ($sid -and $Seen.ContainsKey($sid) -and [int64]$Seen[$sid] -gt [int64]$i.created) { continue }
        $i
    }
}

# Deletes alert files nobody needs any more: outbox entries older than 30 minutes (stale news, never sent; this
# also catches unreadable ones) and seen-, alerted- and wait- files older than a day (the sent state forgets its
# entries after a day too, and nothing else cleans these up).
function Remove-OldAlertFiles([string]$Queue, [int64]$NowMs) {
    foreach ($f in @(Get-ChildItem -LiteralPath $Queue -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -like 'tg-*.json') { $maxMs = 30 * 60 * 1000 }
        elseif ($f.Name -match '^(seen|alerted|wait)-.+\.json$') { $maxMs = 24 * 60 * 60 * 1000 }
        else { continue }
        if ($NowMs - ([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds() -gt $maxMs) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

# Marks sent alerts resolved (in place): their session showed activity after the alert went out (a seen- stamp
# newer than at), or, for a finished notice (key done:<notice key>), it was closed in the widget ($Closed holds
# those notice keys). $true when anything changed.
function Update-ResolvedAlerts([hashtable]$Sent, [hashtable]$Seen, [hashtable]$Closed) {
    $changed = $false
    foreach ($k in @($Sent.Keys)) {
        $e = $Sent[$k]
        if ($e.resolved) { continue }
        $sid = [string]$e.session
        $seenAt = if ($sid -and $Seen.ContainsKey($sid)) { [int64]$Seen[$sid] } else { [int64]0 }
        # (not $closed: variable names are case-insensitive, it would replace the parameter)
        $noticeClosed = $k.StartsWith('done:') -and $Closed -and $Closed.ContainsKey($k.Substring(5))
        if ($seenAt -gt [int64]$e.at -or $noticeClosed) { $e.resolved = $true; $changed = $true }
    }
    return $changed
}

# The next Telegram message to edit to "resolved": one whose alerts (a batch shares one message) are all resolved
# and that was not edited yet. @{ message; text; alertKeys } or $null. Alerts never delivered (no message id) or saved
# without their text cannot be edited.
function Get-ResolvedEdit([hashtable]$Sent) {
    $byMessage = @{}
    foreach ($k in $Sent.Keys) {
        $e = $Sent[$k]
        if ($null -eq $e.message -or -not $e.text) { continue }
        $m = [string]$e.message
        if (-not $byMessage.ContainsKey($m)) { $byMessage[$m] = New-Object System.Collections.ArrayList }
        [void]$byMessage[$m].Add($k)
    }
    foreach ($m in @($byMessage.Keys | Sort-Object)) {
        $keys = @($byMessage[$m])
        $entries = @($keys | ForEach-Object { $Sent[$_] })
        if (@($entries | Where-Object { $_.edited -or -not $_.resolved }).Count -gt 0) { continue }
        return @{ message = [int64]$entries[0].message; text = [string]$entries[0].text; alertKeys = $keys }
    }
    return $null
}

# Is a failed Bot API call worth one more try? Only failures that may pass next time: no answer (0; the message
# may have arrived, so a retry can send it twice, accepted once), too many requests (429) and server errors (5xx).
# Any other 4xx (bad token, blocked bot, bad request) fails the same way again.
function Test-TelegramRetryable([int]$Status) {
    return ($Status -eq 0 -or $Status -eq 429 -or ($Status -ge 500 -and $Status -le 599))
}

# A sent message's text with the resolved mark after a blank line, cut to stay within Telegram's 4096 characters
function Format-ResolvedText([string]$Text, [string]$Mark) {
    $suffix = "`n`n" + $Mark
    if (($Text + $suffix).Length -gt 4096) { $Text = Format-CutText $Text (4096 - $suffix.Length) }
    return $Text + $suffix
}
