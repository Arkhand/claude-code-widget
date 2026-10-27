# opaiva-code-widget: pick a session inside the Claude desktop app (dot-sourced by widget.ps1).
#
# !!! FRAGILE - DELETE IF IT STARTS FAILING !!!
# The Claude desktop app keeps every Claude Code session in one window and has no link that opens an
# existing session (its claude:// links only open a NEW one). This file reads the app's sidebar through
# Windows UI Automation (the accessibility tree Electron builds for screen readers) and presses the row of
# the session. It depends on how the app names those rows today ("<title> <project>", a "More options for
# <title>" button next to each row, "Forked from" for forks), in Spanish, English and Portuguese. Any app
# update can change that. When it does, nothing breaks: the widget just brings the app forward, as before
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
$ClaudeAppForkMarkers = @('Bifurcado de ', 'Forked from ')

# Which of the sidebar rows ($Names) is the session: its title alone, "<title> <project>", or a fork that kept
# the title ("<title> Forked from ..."). Exactly one candidate -> its index; none or several -> -1 (the widget
# must not guess: a fork keeps its parent's title).
function Find-ClaudeAppSessionIndex([string[]]$Names, [string]$Title, [string]$Project) {
    $t = ([string]$Title).Trim()
    if (-not $t -or -not $Names) { return -1 }
    $p = ([string]$Project).Trim()
    $found = @()
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $n = ([string]$Names[$i]).Trim()
        $hit = $n -ieq $t -or ($p -and $n -ieq "$t $p")
        if (-not $hit -and $n.StartsWith("$t ", [StringComparison]::OrdinalIgnoreCase)) {
            $rest = $n.Substring($t.Length + 1)
            $hit = @($ClaudeAppForkMarkers | Where-Object { $rest.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        }
        if ($hit) { $found += $i }
    }
    if ($found.Count -eq 1) { return $found[0] }
    return -1
}

# Presses the sidebar row of the session in the Claude app window $AppWindow. Slow (up to a few seconds the
# first time, while Electron builds its tree): call it off the UI thread. Returns 'opened', 'ambiguous'
# (none or several rows fit) or 'noaccess' (the app exposed no sidebar). Never throws.
function Select-ClaudeAppSession([IntPtr]$AppWindow, [string]$Title, [string]$Project) {
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
        $content = [ClaudeWidget.ClaudeApp]::Content($AppWindow)
        if ($content -eq [IntPtr]::Zero) { return 'noaccess' }
        $ae = [System.Windows.Automation.AutomationElement]
        $isButton = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        $buttons = @()
        for ($try = 0; $try -lt 4; $try++) {
            [ClaudeWidget.ClaudeApp]::Wake($content)
            $buttons = @($ae::FromHandle($content).FindAll([System.Windows.Automation.TreeScope]::Descendants, $isButton))
            if ($buttons.Count -gt 5) { break }
            Start-Sleep -Milliseconds 1500
        }
        # Session rows: a button whose name starts with a title that has a "More options for <title>" button
        $titles = @()
        foreach ($b in $buttons) {
            $n = $b.Current.Name
            if (-not $n) { continue }
            foreach ($pre in $ClaudeAppOptionPrefixes) { if ($n.StartsWith($pre)) { $titles += $n.Substring($pre.Length) } }
        }
        if ($titles.Count -eq 0) { return 'noaccess' }
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
        $i = Find-ClaudeAppSessionIndex $names $Title $Project
        if ($i -lt 0) { return 'ambiguous' }
        $pattern = $null
        if (-not $rows[$i].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { return 'noaccess' }
        $pattern.Invoke()
        return 'opened'
    }
    catch { return 'noaccess' }
}
