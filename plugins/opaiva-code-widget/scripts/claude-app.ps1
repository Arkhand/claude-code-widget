# opaiva-code-widget: pick a session inside the Claude desktop app (dot-sourced by widget.ps1).
#
# !!! FRAGILE - DELETE IF IT STARTS FAILING !!!
# The Claude desktop app keeps every Claude Code session in one window and has no link that opens an
# existing session (its claude:// links only open a NEW one). This file reads the app's sidebar through
# Windows UI Automation (the accessibility tree Electron builds for screen readers) and presses the row of
# the session. It depends on how the app labels them today: each row has a "More options for <title>" button
# next to it (in Spanish, English or Portuguese), which gives the row's exact title; the row's own name is
# that title plus whatever the app adds (project, "Forked from ...", "Started by Claude from ...", "Waiting for
# input ..."). Any app update can change that. When it does, nothing breaks: the widget just brings the app forward, as before
# 2.8.0. To remove it: delete this file and the calls to Start-ClaudeAppSelect in widget.ps1
# (Close-DoneNotice and Open-SessionRow), plus tests/claude-app.Tests.ps1.
#
# Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI): accented UI words are
# written with [char] codes.

# Words the app uses today, per UI language
$ClaudeAppOptionPrefixes = @(
    ('M' + [char]0xE1 + 's opciones para ')           # es: "Mas opciones para <title>"
    'More options for '                               # en
    ('Mais op' + [char]0xE7 + [char]0xF5 + 'es para ') # pt
)
# What the app writes after a forked session's title ("<title> Forked from <parent> <project>")
$ClaudeAppForkMarkers = @('Bifurcado de ', 'Forked from ')

# The title of each sidebar row ($Names): the longest of the app's titles ($Titles, from its "More options for
# <title>" buttons) the row's name starts with; '' when none does
function Get-ClaudeAppRowTitles([string[]]$Names, [string[]]$Titles) {
    foreach ($n in @($Names)) {
        $best = ''
        foreach ($t in @($Titles)) {
            if ($t.Length -gt $best.Length -and ($n -eq $t -or $n.StartsWith("$t "))) { $best = $t }
        }
        $best
    }
}

# Which row is the session: the only row whose title is the session's title. A fork keeps its parent's title and
# the app shows no session id, so when several rows share the title the rows' names ($Names) and whether the
# session is a fork ($IsFork: $true, $false, or $null when unknown) decide: an original takes the one row that
# is not marked as a fork, a fork the one that is. Still none or several -> -1: the widget must not guess.
function Find-ClaudeAppSessionIndex([string[]]$RowTitles, [string]$Title, [string[]]$Names = $null, $IsFork = $null) {
    $t = ([string]$Title).Trim()
    if (-not $t -or -not $RowTitles) { return -1 }
    $found = @()
    for ($i = 0; $i -lt $RowTitles.Count; $i++) { if (([string]$RowTitles[$i]).Trim() -ieq $t) { $found += $i } }
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -lt 2 -or $null -eq $IsFork -or -not $Names) { return -1 }
    $same = @($found | Where-Object {
            $rest = ([string]$Names[$_]).Substring([math]::Min(([string]$RowTitles[$_]).Length, ([string]$Names[$_]).Length)).TrimStart()
            $rowIsFork = @($ClaudeAppForkMarkers | Where-Object { $rest.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            $rowIsFork -eq [bool]$IsFork
        })
    if ($same.Count -eq 1) { return $same[0] }
    return -1
}

# Is this Claude Code session a fork? A fork's transcript starts with the history it copied, which still carries
# the original session's id: the first sessionId in the file is another session's. $null when it cannot tell.
function Test-ClaudeSessionFork([string]$TranscriptPath, [string]$SessionId) {
    if (-not $TranscriptPath -or -not $SessionId -or -not (Test-Path -LiteralPath $TranscriptPath)) { return $null }
    try {
        $reader = New-Object IO.StreamReader($TranscriptPath)
        try {
            for ($n = 0; $n -lt 50; $n++) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                if ($line -match '"sessionId"\s*:\s*"([^"]+)"') { return ($Matches[1] -ne $SessionId) }
            }
        }
        finally { $reader.Dispose() }
    } catch {}
    return $null
}

# A session's transcript under ~/.claude/projects, found by its id; '' when there is none
function Find-ClaudeSessionTranscript([string]$SessionId, [string]$ProjectsDir = (Join-Path $env:USERPROFILE '.claude\projects')) {
    if (-not $SessionId) { return '' }
    # (one folder per project: <projects>\<project>\<session id>.jsonl)
    $f = Get-ChildItem -Path (Join-Path $ProjectsDir "*\$SessionId.jsonl") -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return ''
}

# Presses the sidebar row of the session in the Claude app window $AppWindow. Slow (up to a few seconds the
# first time, while Electron builds its tree, or right after the app was restored from minimized): call it off
# the UI thread. Returns 'opened', 'ambiguous' (none or several rows fit), 'nowindow' (no content window),
# 'notree' (no sidebar in the accessibility tree), 'noinvoke' (the row cannot be pressed) or 'error: <why>'.
# Never throws.
function Select-ClaudeAppSession([IntPtr]$AppWindow, [string]$Title, $IsFork = $null) {
    try {
        if (-not ('ClaudeWidget.ClaudeApp' -as [type])) {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
namespace ClaudeWidget {
    public static class ClaudeApp {
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr h, uint id, ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
        // The Chromium content window: where Electron's accessibility tree lives
        public static IntPtr Content(IntPtr top) {
            IntPtr found = IntPtr.Zero;
            EnumChildWindows(top, (h, x) => { var sb = new StringBuilder(256); GetClassName(h, sb, 256); if (sb.ToString() == "Chrome_RenderWidgetHostHWND") { found = h; return false; } return true; }, IntPtr.Zero);
            return found;
        }
        // What a screen reader does first: asking for the accessible object makes Chromium build its tree
        public static void Wake(IntPtr h) { Guid g = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71"); object o; AccessibleObjectFromWindow(h, 0xFFFFFFFC, ref g, out o); }
    }
}
'@
        }
        $ae = [System.Windows.Automation.AutomationElement]
        $isButton = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        # Retried for about 6 s: right after the app is restored (from minimized or another desktop) its content
        # window or its sidebar may not be there yet, and Electron builds the tree only once asked
        $content = [IntPtr]::Zero
        $buttons = @()
        $titles = @()
        for ($try = 0; $try -lt 8; $try++) {
            if ($try) { Start-Sleep -Milliseconds 750 }
            $content = [ClaudeWidget.ClaudeApp]::Content($AppWindow)
            if ($content -eq [IntPtr]::Zero) { continue }
            [ClaudeWidget.ClaudeApp]::Wake($content)
            $buttons = @($ae::FromHandle($content).FindAll([System.Windows.Automation.TreeScope]::Descendants, $isButton))
            # Session rows: a button whose name starts with a title that has a "More options for <title>" button
            $titles = @()
            foreach ($b in $buttons) {
                $n = $b.Current.Name
                if (-not $n) { continue }
                foreach ($pre in $ClaudeAppOptionPrefixes) { if ($n.StartsWith($pre)) { $titles += $n.Substring($pre.Length) } }
            }
            if ($titles.Count) { break }
        }
        if ($content -eq [IntPtr]::Zero) { return 'nowindow' }
        if ($titles.Count -eq 0) { return 'notree' }
        $rows = @()
        $names = @()
        foreach ($b in $buttons) {
            $n = $b.Current.Name
            if (-not $n -or $names -contains $n) { continue }
            if (@($ClaudeAppOptionPrefixes | Where-Object { $n.StartsWith($_) }).Count) { continue }
            # (the rename button: "<title>, rename session")
            if ($n.Contains(', ')) { continue }
            if (@($titles | Where-Object { $n.StartsWith($_) }).Count -eq 0) { continue }
            $rows += $b
            $names += $n
        }
        $i = Find-ClaudeAppSessionIndex @(Get-ClaudeAppRowTitles $names $titles) $Title $names $IsFork
        if ($i -lt 0) { return 'ambiguous' }
        $pattern = $null
        if (-not $rows[$i].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { return 'noinvoke' }
        $pattern.Invoke()
        return 'opened'
    }
    catch { return ('error: ' + $_.Exception.Message) }
}
