# widget.ps1 tests. They run the real widget code, so they carry the Desktop tag:
#   rendering draws every card to PNG (no window is shown);
#   the queue test starts a real widget for a few seconds (an idle pill appears in a corner).
BeforeAll {
    # No tray icon for the widgets these tests start (and kill): they would leave ghost icons behind
    $savedNoTray = $env:CLAUDE_WIDGET_NO_TRAY
    $env:CLAUDE_WIDGET_NO_TRAY = '1'
    $repo = Split-Path -Parent $PSScriptRoot
    $widget = Join-Path $repo 'plugins\opaiva-code-widget\scripts\widget.ps1'
    $samples = Join-Path $repo 'tools\samples.json'
    . (Join-Path $repo 'plugins\opaiva-code-widget\scripts\common.ps1')
    [void](Get-ScreenAreas)   # compiles ClaudeWidget.Monitors (pixels, same DPI mode as GetWindowRect here)
    if (-not ('CcwTest.Windows' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace CcwTest {
    public static class Windows {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        // Rects (pixels: left, top, right, bottom) of the visible top-level windows of one process
        public static List<int[]> Rects(int pid) {
            var list = new List<int[]>();
            EnumWindows((h, l) => {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                RECT r;
                if (owner == pid && IsWindowVisible(h) && GetWindowRect(h, out r)) list.Add(new int[] { r.Left, r.Top, r.Right, r.Bottom });
                return true;
            }, IntPtr.Zero);
            return list;
        }
    }
}
'@
    }
    if (-not ('CcwTest.Keys' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CcwTest {
    public static class Keys {
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        // Presses the keys together (down in order, up in reverse)
        public static void Chord(byte[] vks) {
            foreach (var k in vks) keybd_event(k, 0, 0, UIntPtr.Zero);
            for (int i = vks.Length - 1; i >= 0; i--) keybd_event(vks[i], 0, 2, UIntPtr.Zero);
        }
    }
}
'@
    }
    if (-not ('CcwTest.HotKeyProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CcwTest {
    public static class HotKeyProbe {
        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
        // True when another process already owns Ctrl+Alt+<vk> (a hotkey can be registered only once)
        public static bool IsTaken(uint vk) {
            if (RegisterHotKey(IntPtr.Zero, 0x7777, 0x4003, vk)) { UnregisterHotKey(IntPtr.Zero, 0x7777); return false; }
            return true;
        }
    }
}
'@
    }
    if (-not ('CcwTest.Front' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CcwTest {
    public static class Front {
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        public static IntPtr Current() { return GetForegroundWindow(); }
        // Windows lets a process take the foreground only from the window that has it: join that window's input queue first
        public static bool Take(IntPtr h) {
            uint pid;
            uint owner = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            uint me = GetCurrentThreadId();
            AttachThreadInput(me, owner, true);
            BringWindowToTop(h);
            SetForegroundWindow(h);
            AttachThreadInput(me, owner, false);
            return GetForegroundWindow() == h;
        }
    }
}
'@
    }
    if (-not ('CcwTest.Mouse' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CcwTest {
    public static class Mouse {
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
        [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        public static int[] Position() { POINT p; GetCursorPos(out p); return new int[] { p.X, p.Y }; }
        public static void MoveTo(int x, int y) { SetCursorPos(x, y); }
        // A real click (the left or the right button) at x, y
        public static void Click(int x, int y, bool right) {
            SetCursorPos(x, y);
            mouse_event(right ? 0x0008u : 0x0002u, 0, 0, 0, UIntPtr.Zero);
            mouse_event(right ? 0x0010u : 0x0004u, 0, 0, 0, UIntPtr.Zero);
        }
        public static int ForegroundPid() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return (int)pid; }
    }
}
'@
    }
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    # The widget's window (the largest visible one: an open menu is a window of its own), or $null
    function Get-WidgetRect($Proc) {
        $best = $null
        foreach ($r in [CcwTest.Windows]::Rects($Proc.Id)) {
            if (-not $best -or ($r[2] - $r[0]) * ($r[3] - $r[1]) -gt ($best[2] - $best[0]) * ($best[3] - $best[1])) { $best = $r }
        }
        return $best
    }
    # Waits for the widget window: widget.json first (written before the window), since powershell.exe can flash its
    # hidden console window at start, then 2 s for the layout to settle
    function Wait-WidgetShown($Proc, [string]$Data) {
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath (Join-Path $Data 'widget.json'))) { Start-Sleep -Milliseconds 250 }
        while ((Get-Date) -lt $deadline -and -not (Get-WidgetRect $Proc)) { Start-Sleep -Milliseconds 250 }
        Start-Sleep -Seconds 2
        return [bool](Get-WidgetRect $Proc)
    }
    # Right-clicks the middle of the widget and waits for its menu (a second visible window) to open
    function Open-WidgetMenu($Proc) {
        $r = Get-WidgetRect $Proc
        if (-not $r) { return $false }
        [CcwTest.Mouse]::Click([int](($r[0] + $r[2]) / 2), [int](($r[1] + $r[3]) / 2), $true)
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            if (@([CcwTest.Windows]::Rects($Proc.Id)).Count -ge 2) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }
    # UI Automation: the first element of the widget process (its window or its open menu) with that name or
    # automation id (the x:Name of a XAML element), shown on screen; $null when there is none
    function Find-WidgetElement($Proc, [string]$Name = '', [string]$Id = '') {
        $ae = [System.Windows.Automation.AutomationElement]
        $mine = New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, [int]$Proc.Id)
        $what = if ($Id) { New-Object System.Windows.Automation.PropertyCondition($ae::AutomationIdProperty, $Id) }
        else { New-Object System.Windows.Automation.PropertyCondition($ae::NameProperty, $Name) }
        foreach ($top in $ae::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $mine)) {
            foreach ($el in $top.FindAll([System.Windows.Automation.TreeScope]::Subtree, $what)) {
                if (-not $el.Current.IsOffscreen) { return $el }
            }
        }
        return $null
    }
    function Wait-WidgetElement($Proc, [string]$Name = '', [string]$Id = '', [int]$Seconds = 10) {
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) {
            $el = Find-WidgetElement $Proc -Name $Name -Id $Id
            if ($el) { return $el }
            Start-Sleep -Milliseconds 200
        }
        return $null
    }
    function Invoke-WidgetElement($El) { $El.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    function Expand-WidgetElement($El) { $El.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() }
    Add-Type -AssemblyName System.Windows.Forms
    # A real top-level window of this process, brought to the front (null when Windows does not allow it here).
    # The caller closes it.
    function New-FrontWindow {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'ccw-test-session-window'
        $f.StartPosition = 'Manual'
        $f.Location = New-Object System.Drawing.Point 0, 400
        $f.Size = New-Object System.Drawing.Size 200, 80
        $f.TopMost = $true
        $f.Show()
        [System.Windows.Forms.Application]::DoEvents()
        if ([CcwTest.Front]::Take($f.Handle)) { return $f }
        $f.Close()
        return $null
    }
}
AfterAll { $env:CLAUDE_WIDGET_NO_TRAY = $savedNoTray }

Describe 'widget.ps1 rendering' -Tag 'Desktop' {
    It 'draws every card in <lang>' -ForEach @(@{ lang = 'en' }, @{ lang = 'pt' }) {
        $out = Join-Path $TestDrive $lang
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $out -Lang $lang
        $LASTEXITCODE | Should -Be 0
        foreach ($name in 'idle', 'sessions', 'permission', 'edit', 'question', 'done', 'telegram-token', 'telegram-start', 'telegram-done') {
            $png = Join-Path $out "$name.png"
            $png | Should -Exist
            (Get-Item -LiteralPath $png).Length | Should -BeGreaterThan 1024
        }
    }
    It 'draws the light theme with a light card and the dark theme with a dark card' {
        Add-Type -AssemblyName System.Drawing
        function Get-CardPixel([string]$theme) {
            $out = Join-Path $TestDrive "t-$theme"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $out -Lang en -Theme $theme
            $LASTEXITCODE | Should -Be 0
            $bmp = New-Object System.Drawing.Bitmap (Join-Path $out 'permission.png')
            try {
                # 2x render: x = 50 px is inside the card's left padding, at mid height there is no content
                $c = $bmp.GetPixel(50, [int]($bmp.Height / 2))
                return [int](($c.R + $c.G + $c.B) / 3)
            }
            finally { $bmp.Dispose() }
        }
        (Get-CardPixel 'light') | Should -BeGreaterThan 200
        (Get-CardPixel 'dark') | Should -BeLessThan 80
    }
}

Describe 'widget.ps1 queue loop' -Tag 'Desktop' {
    It 'removes orphaned requests and stale notices from its queue' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $orphan = [ordered]@{ id = 'orphan'; pid = 2147483640; kind = 'permission'; created = $now; timeout = 300; cwd = '' }
        [IO.File]::WriteAllText((Join-Path $queue 'req-orphan.json'), ($orphan | ConvertTo-Json -Compress))
        $stale = $now - 13 * 3600 * 1000
        $notice = [ordered]@{ session = 's1'; created = $stale; cwd = ''; message = 'x'; hwnd = 0; kind = '' }
        [IO.File]::WriteAllText((Join-Path $queue "done-s1-$stale.json"), ($notice | ConvertTo-Json -Compress))

        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and @(Get-ChildItem -LiteralPath $queue -File).Count -gt 0) { Start-Sleep -Milliseconds 250 }
            @(Get-ChildItem -LiteralPath $queue -File).Count | Should -Be 0
            Join-Path $data 'widget.json' | Should -Exist
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 finished notice lifetime' -Tag 'Desktop' {
    It 'keeps finished notices <keep> min old and removes them <drop> min old with closeAfter <close>' -ForEach @(
        @{ close = 0; keep = 6; drop = 13 * 60 }, @{ close = 1; keep = 0.5; drop = 2 }) {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        [IO.File]::WriteAllText((Join-Path $data 'state.json'), '{"right":520,"bottom":330}')
        [IO.File]::WriteAllText((Join-Path $data 'prefs.json'), ('{"closeAfter":' + $close + ',"volume":0}'))
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $kept = $now - [int64]($keep * 60000)
        $dropped = $now - [int64]($drop * 60000)
        foreach ($created in $kept, $dropped) {
            $notice = [ordered]@{ session = "s$created"; created = $created; cwd = ''; message = 'x'; hwnd = 0; kind = '' }
            [IO.File]::WriteAllText((Join-Path $queue "done-s$created-$created.json"), ($notice | ConvertTo-Json -Compress))
        }
        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en', '-SettingsPath', ('"{0}"' -f (Join-Path $data 'settings.json'))
        try {
            $old = Join-Path $queue "done-s$dropped-$dropped.json"
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and (Test-Path -LiteralPath $old)) { Start-Sleep -Milliseconds 250 }
            $old | Should -Not -Exist
            # A few more rounds: the younger notice is still there
            Start-Sleep -Seconds 3
            Join-Path $queue "done-s$kept-$kept.json" | Should -Exist
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 position' -Tag 'Desktop' {
    # With one monitor the old check already sent such a spot to the corner: this guards the wiring
    # of the new per-monitor check (the gap between monitors is covered by Resolve-Anchor's tests)
    It 'opens in the main screen corner when the saved spot is on no screen, keeping state.json' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        $state = '{"right":-50000,"bottom":-50000}'
        $statePath = Join-Path $data 'state.json'
        [IO.File]::WriteAllText($statePath, $state)
        $work = $null
        foreach ($m in [ClaudeWidget.Monitors]::List()) { if ($m[5] -eq 1) { $work = $m } }

        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $inCorner = $false
            $deadline = (Get-Date).AddSeconds(30)
            while (-not $inCorner -and (Get-Date) -lt $deadline) {
                foreach ($r in [CcwTest.Windows]::Rects($proc.Id)) {
                    if ([math]::Abs($r[2] - $work[2]) -le 2 -and [math]::Abs($r[3] - $work[3]) -le 2) { $inCorner = $true }
                }
                if (-not $inCorner) { Start-Sleep -Milliseconds 250 }
            }
            $inCorner | Should -BeTrue
            [IO.File]::ReadAllText($statePath) | Should -BeExactly $state
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 do not disturb' -Tag 'Desktop' {
    It 'hides its window while dnd.flag exists and shows it again when removed' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        Set-Dnd $data $true
        function Get-VisibleCount($ProcessId) { @([CcwTest.Windows]::Rects($ProcessId)).Count }
        function Wait-Until([scriptblock]$Condition, [int]$Seconds = 15) {
            $deadline = (Get-Date).AddSeconds($Seconds)
            while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 250 }
            return $false
        }
        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            (Wait-Until { Test-Path -LiteralPath (Join-Path $data 'widget.json') }) | Should -BeTrue
            Start-Sleep -Seconds 3
            Get-VisibleCount $proc.Id | Should -Be 0
            Set-Dnd $data $false
            (Wait-Until { (Get-VisibleCount $proc.Id) -gt 0 }) | Should -BeTrue
            Set-Dnd $data $true
            (Wait-Until { (Get-VisibleCount $proc.Id) -eq 0 }) | Should -BeTrue
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 quit request' -Tag 'Desktop' {
    It 'closes by itself when quit.flag appears, and removes the flag' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath (Join-Path $data 'widget.json'))) { Start-Sleep -Milliseconds 250 }
            Join-Path $data 'widget.json' | Should -Exist
            [IO.File]::WriteAllText((Join-Path $data 'quit.flag'), '')
            $proc.WaitForExit(10000) | Should -BeTrue
            Join-Path $data 'quit.flag' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'ignores a quit.flag left over from before it started' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        [IO.File]::WriteAllText((Join-Path $data 'quit.flag'), '')
        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath (Join-Path $data 'widget.json'))) { Start-Sleep -Milliseconds 250 }
            Start-Sleep -Seconds 3
            $proc.HasExited | Should -BeFalse
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 global hotkeys' -Tag 'Desktop' {
    BeforeAll {
        function New-PermissionRequestFile([string]$Queue, [string]$Id) {
            $req = [ordered]@{ id = $Id; pid = $PID; kind = 'permission'; created = (Get-NowMs); timeout = 300; cwd = 'C:\dev\app'
                tool = 'Bash'; description = 'x'; detail = 'ls'; title = ''; change = $null; suggestions = @() }
            Write-JsonAtomic (Join-Path $Queue "req-$Id.json") $req
        }
        function Start-HotkeyWidget([string]$Data, [bool]$Enabled) {
            # In the top-left corner, away from where the real widget shows its cards: a person who sees a
            # test card there must not mistake it for a real request
            [IO.File]::WriteAllText((Join-Path $Data 'state.json'), '{"right":520,"bottom":330}')
            $saved = @{}
            foreach ($n in 'CLAUDE_WIDGET_HOTKEYS', 'CLAUDE_WIDGET_KEY_APPROVE', 'CLAUDE_WIDGET_KEY_DENY', 'CLAUDE_WIDGET_KEY_DND') { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_HOTKEYS', $(if ($Enabled) { '1' } else { $null }))
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_KEY_APPROVE', 'Ctrl+Alt+F13')
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_KEY_DENY', 'Ctrl+Alt+F14')
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_KEY_DND', 'Ctrl+Alt+F15')
            try {
                return Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                    '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $Data), '-Lang', 'en',
                    '-SettingsPath', ('"{0}"' -f (Join-Path $Data 'no-settings.json'))
            }
            finally { foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
        }
        function Wait-ForFile([string]$Path, [int]$Seconds = 10) {
            $deadline = (Get-Date).AddSeconds($Seconds)
            while ((Get-Date) -lt $deadline) { if (Test-Path -LiteralPath $Path) { return $true }; Start-Sleep -Milliseconds 250 }
            return $false
        }
        # Starts the widget the way Start-Widget in hook.ps1 does (WMI: the caller's environment is not inherited).
        # CLAUDE_WIDGET_NO_TRAY is set inside the command, because the test's own value does not reach it either.
        function Start-WmiWidget([string]$Data, [string]$Settings) {
            [IO.File]::WriteAllText((Join-Path $Data 'state.json'), '{"right":520,"bottom":330}')
            $inner = "`$env:CLAUDE_WIDGET_NO_TRAY='1'; & '$widget' -DataDir '$Data' -Lang en -SettingsPath '$Settings'"
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "{0}"' -f $inner
            $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
            $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; ProcessStartupInformation = $si }
            return [int]$r.ProcessId
        }
        # Kills the WMI-started shell and the widget pid it recorded, then removes the data dir
        function Stop-TestWidget([int]$ShellPid, [string]$Data) {
            $widgetPid = 0
            $json = Join-Path $Data 'widget.json'
            if (Test-Path -LiteralPath $json) { try { $widgetPid = [int](([IO.File]::ReadAllText($json) | ConvertFrom-Json).pid) } catch {} }
            foreach ($id in @($ShellPid, $widgetPid)) { if ($id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } }
            Start-Sleep -Milliseconds 500
            Remove-Item -LiteralPath $Data -Recurse -Force -ErrorAction SilentlyContinue
        }
        $CTRL = [byte]0x11
        $ALT = [byte]0x12
    }
    It 'approves, denies and toggles do not disturb with the configured keys' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $proc = Start-HotkeyWidget $data $true
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            New-PermissionRequestFile $queue 'r1'
            Start-Sleep -Milliseconds 1800
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7C))
            (Wait-ForFile (Join-Path $queue 'res-r1.json')) | Should -BeTrue
            ([IO.File]::ReadAllText((Join-Path $queue 'res-r1.json')) | ConvertFrom-Json).decision | Should -BeExactly 'allow'

            New-PermissionRequestFile $queue 'r2'
            Start-Sleep -Milliseconds 1800
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7D))
            (Wait-ForFile (Join-Path $queue 'res-r2.json')) | Should -BeTrue
            ([IO.File]::ReadAllText((Join-Path $queue 'res-r2.json')) | ConvertFrom-Json).decision | Should -BeExactly 'deny'

            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7E))
            (Wait-ForFile (Join-Path $data 'dnd.flag')) | Should -BeTrue
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'a widget started through WMI sees the hotkey setting' {
        # Start-Widget in hook.ps1 starts the widget through WMI, which drops the hook's environment:
        # the settings.json env block is the only way the setting reaches the widget
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        $settings = Join-Path $data 'settings.json'
        [IO.File]::WriteAllText($settings, '{"env":{"CLAUDE_WIDGET_HOTKEYS":"1","CLAUDE_WIDGET_KEY_APPROVE":"Ctrl+Alt+F13","CLAUDE_WIDGET_KEY_DENY":"Ctrl+Alt+F14","CLAUDE_WIDGET_KEY_DND":"Ctrl+Alt+F15"}}')
        [CcwTest.HotKeyProbe]::IsTaken(0x7E) | Should -BeFalse
        $ids = Start-WmiWidget $data $settings
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            [CcwTest.HotKeyProbe]::IsTaken(0x7E) | Should -BeTrue
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally { Stop-TestWidget $ids $data }
    }
    It 'a widget started through WMI does not see the caller environment' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        $settings = Join-Path $data 'settings.json'
        [IO.File]::WriteAllText($settings, '{}')
        $saved = @{}
        $vars = @{ CLAUDE_WIDGET_HOTKEYS = '1'; CLAUDE_WIDGET_KEY_APPROVE = 'Ctrl+Alt+F13'; CLAUDE_WIDGET_KEY_DENY = 'Ctrl+Alt+F14'; CLAUDE_WIDGET_KEY_DND = 'Ctrl+Alt+F15' }
        foreach ($n in $vars.Keys) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $vars[$n]) }
        try { $ids = Start-WmiWidget $data $settings }
        finally { foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            [CcwTest.HotKeyProbe]::IsTaken(0x7E) | Should -BeFalse
        }
        finally { Stop-TestWidget $ids $data }
    }
    It 'does nothing when the hotkeys are not turned on' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $proc = Start-HotkeyWidget $data $false
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            New-PermissionRequestFile $queue 'r1'
            Start-Sleep -Milliseconds 1800
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7C))
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7E))
            Start-Sleep -Seconds 3
            Join-Path $queue 'res-r1.json' | Should -Not -Exist
            Join-Path $data 'dnd.flag' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'does not approve when there is no permission card on screen' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $proc = Start-HotkeyWidget $data $true
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7C))
            Start-Sleep -Seconds 2
            $proc.HasExited | Should -BeFalse
            @(Get-ChildItem -LiteralPath $queue -Filter 'res-*.json').Count | Should -Be 0
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 preferences' -Tag 'Desktop' {
    BeforeAll {
        function Get-PillSize([string]$prefsJson) {
            $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
            # Top-left corner, so that nobody clicks the test widget by accident
            [IO.File]::WriteAllText((Join-Path $data 'state.json'), '{"right":420,"bottom":220}')
            if ($prefsJson) { [IO.File]::WriteAllText((Join-Path $data 'prefs.json'), $prefsJson) }
            $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
            try {
                # The window size is settled when two readings 400 ms apart agree
                $size = $null
                $prev = ''
                $deadline = (Get-Date).AddSeconds(30)
                while (-not $size -and (Get-Date) -lt $deadline) {
                    $cur = ''
                    foreach ($r in [CcwTest.Windows]::Rects($proc.Id)) { if (-not $cur) { $cur = '{0}x{1}' -f ($r[2] - $r[0]), ($r[3] - $r[1]) } }
                    if ($cur -and $cur -eq $prev) { $w, $h = $cur -split 'x'; $size = @{ w = [int]$w; h = [int]$h } }
                    $prev = $cur
                    Start-Sleep -Milliseconds 400
                }
                Join-Path $data 'widget.log' | Should -Not -Exist
                return $size
            }
            finally {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                [void]$proc.WaitForExit(5000)
                Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    It 'scale 1.5 makes the pill bigger, and the minimal pill smaller' {
        $normal = Get-PillSize ''
        $big = Get-PillSize '{"scale":1.5}'
        $min = Get-PillSize '{"minimal":true}'
        $big.w | Should -BeGreaterThan ($normal.w * 1.2)
        $big.h | Should -BeGreaterThan ($normal.h * 1.2)
        $min.w | Should -BeLessThan ($normal.w * 0.7)
    }
    It 'starts with garbage in prefs.json without errors' {
        $size = Get-PillSize '{"theme":7,"opacity":"x","scale":[1]}'
        $size | Should -Not -BeNullOrEmpty
    }
}

Describe 'widget.ps1 right-click menu' -Tag 'Desktop' {
    It 'closes when you click another window, and leaves the focus off the widget' {
        $form = New-FrontWindow
        if (-not $form) { Set-ItResult -Skipped -Because 'Windows did not let this process take the foreground'; return }
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        [IO.File]::WriteAllText((Join-Path $data 'state.json'), '{"right":520,"bottom":330}')
        [IO.File]::WriteAllText((Join-Path $data 'prefs.json'), '{"volume":0}')
        $cursor = [CcwTest.Mouse]::Position()
        $proc = $null
        try {
            $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en',
                '-SettingsPath', ('"{0}"' -f (Join-Path $data 'settings.json'))
            Wait-WidgetShown $proc $data | Should -BeTrue
            Open-WidgetMenu $proc | Should -BeTrue
            # A click on another window, as on the desktop
            [CcwTest.Mouse]::Click([int]($form.Left + $form.Width / 2), [int]($form.Top + $form.Height / 2), $false)
            $closed = $false
            $deadline = (Get-Date).AddSeconds(5)
            while (-not $closed -and (Get-Date) -lt $deadline) {
                [System.Windows.Forms.Application]::DoEvents()
                $closed = @([CcwTest.Windows]::Rects($proc.Id)).Count -eq 1
                if (-not $closed) { Start-Sleep -Milliseconds 100 }
            }
            $closed | Should -BeTrue
            Start-Sleep -Milliseconds 500
            [CcwTest.Mouse]::ForegroundPid() | Should -Not -Be $proc.Id

            # Picking an item closes it too, and the focus goes back where it was
            [void][CcwTest.Front]::Take($form.Handle)
            [System.Windows.Forms.Application]::DoEvents()
            Open-WidgetMenu $proc | Should -BeTrue
            $S = Get-Strings 'en'
            Expand-WidgetElement (Wait-WidgetElement $proc -Name $S.menuTheme)
            Invoke-WidgetElement (Wait-WidgetElement $proc -Name $S.themeDark)
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-Date) -lt $deadline -and @([CcwTest.Windows]::Rects($proc.Id)).Count -gt 1) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            @([CcwTest.Windows]::Rects($proc.Id)).Count | Should -Be 1
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.Application]::DoEvents()
            [CcwTest.Front]::Current() | Should -Be $form.Handle
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            [CcwTest.Mouse]::MoveTo($cursor[0], $cursor[1])
            if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; [void]$proc.WaitForExit(5000) }
            $form.Close()
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 Telegram alerts' -Tag 'Desktop' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'helpers\FakeTelegram.ps1')
        $script:Token = '123456:TEST-token-never-real'
        # A sandbox data dir with Telegram connected and on, alerts after 1 minute (unless told otherwise), no sounds;
        # the widget sits in the top-left corner so nobody mistakes a test card for a real one
        # -NotConnected: no telegram.json and Telegram off
        function New-TgSandbox([string]$AwaySecs = '100000', [int]$NotifyAfter = 1, [switch]$NotConnected) {
            $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
            [IO.File]::WriteAllText((Join-Path $data 'state.json'), '{"right":520,"bottom":330}')
            [IO.File]::WriteAllText((Join-Path $data 'prefs.json'), ('{"telegram":' + $(if ($NotConnected) { 'false' } else { 'true' }) + ',"notifyAfter":' + $NotifyAfter + ',"volume":0}'))
            if (-not $NotConnected) { Save-TelegramConfig $data $script:Token '4242' 'testbot' 'Tester' | Should -BeTrue }
            Set-TgAwaySecs $data $AwaySecs
            return $data
        }
        # CLAUDE_WIDGET_AWAY_SECS through the sandbox settings file (read when the widget starts)
        function Set-TgAwaySecs([string]$Data, [string]$AwaySecs) {
            [IO.File]::WriteAllText((Join-Path $Data 'settings.json'), ('{"env":{"CLAUDE_WIDGET_AWAY_SECS":"' + $AwaySecs + '"}}'))
        }
        function Start-TgWidget([string]$Data, [string]$Url, [string[]]$Extra = @()) {
            Start-Process powershell.exe -PassThru -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $Data), '-Lang', 'en',
                '-SettingsPath', ('"{0}"' -f (Join-Path $Data 'settings.json')), '-TelegramUrl', $Url) + $Extra)
        }
        function Stop-TgWidget($Proc) {
            if ($Proc) { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue; [void]$Proc.WaitForExit(5000) }
        }
        # (the comma keeps a single call an array: a lone hashtable's Count is its number of keys)
        function Get-TgCalls($Fake, [string]$Method) { , @($Fake.Requests.ToArray() | Where-Object { $_.method -eq $Method }) }
        function Wait-Until([scriptblock]$Condition, [int]$Seconds = 30) {
            $deadline = (Get-Date).AddSeconds($Seconds)
            while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 250 }
            return $false
        }
        $script:SendOk = '{"ok":true,"result":{"message_id":77,"chat":{"id":4242},"text":"x"}}'
        $script:EditOk = '{"ok":true,"result":true}'
    }
    BeforeEach {
        $fake = Start-FakeTelegram
        $fake.Replies['sendMessage'] = $script:SendOk
        $fake.Replies['editMessageText'] = $script:EditOk
        $proc = $null
        $data = $null
    }
    AfterEach {
        Stop-TgWidget $proc
        Stop-FakeTelegram $fake
        if ($data) { Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'sends one batched message for two outbox entries' {
        $data = New-TgSandbox
        $queue = Join-Path $data 'queue'
        [void](Add-AlertOutbox $queue @{ kind = 'permission'; session = 's1'; cwd = 'C:\dev\alpha'; detail = 'Bash: npm test'; reason = 'timeout' })
        [void](Add-AlertOutbox $queue @{ kind = 'question'; session = 's2'; cwd = 'C:\dev\beta'; detail = 'Which database?'; reason = 'away' })
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 }) | Should -BeTrue
        Start-Sleep -Seconds 8
        $calls = Get-TgCalls $fake 'sendMessage'
        $calls.Count | Should -Be 1
        $text = ($calls[0].body | ConvertFrom-Json).text
        $text | Should -BeLike '*Bash: npm test*'
        $text | Should -BeLike '*Which database?*'
        @(Get-ChildItem -LiteralPath $queue -Filter 'tg-*.json').Count | Should -Be 0
        $sent = Read-SentAlerts $data
        $sent.Count | Should -Be 2
        foreach ($k in $sent.Keys) { $sent[$k].message | Should -Be 77 }
        Join-Path $data 'widget.log' | Should -Not -Exist
    }

    It 'does not send the same alert again after a restart' {
        # A finished notice stays in the queue (an outbox entry is deleted once sent): it is still due after the restart
        $data = New-TgSandbox
        $queue = Join-Path $data 'queue'
        # Just past X (1 min): a notice is due only for 60 s after X, and must still be due after the restart
        $created = (Get-NowMs) - 61000
        Write-JsonAtomic (Join-Path $queue "done-s1-$created.json") ([ordered]@{ session = 's1'; created = $created; cwd = 'C:\dev\alpha'
                message = 'All tests pass'; hwnd = 0; kind = 'vscode'; title = ''; desktopApp = $false })
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 }) | Should -BeTrue
        Stop-TgWidget $proc
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { Test-Path -LiteralPath (Join-Path $data 'widget.json') }) | Should -BeTrue
        Start-Sleep -Seconds 12
        ((Get-NowMs) - $created) | Should -BeLessThan 120000 -Because 'the notice must still be due for this to test the sent table'
        (Get-TgCalls $fake 'sendMessage').Count | Should -Be 1
        (Join-Path $queue "done-s1-$created.json") | Should -Exist
    }

    It 'sends nothing while present for a wait marker, and sends once when away' {
        $data = New-TgSandbox '100000'
        $queue = Join-Path $data 'queue'
        Set-WaitMarker $queue @{ session = 's1'; kind = 'plan'; cwd = 'C:\dev\alpha'; detail = 'Plan: refactor'; created = (Get-NowMs) - 2 * 60000 }
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { Test-Path -LiteralPath (Join-Path $data 'widget.json') }) | Should -BeTrue
        Start-Sleep -Seconds 12
        (Get-TgCalls $fake 'sendMessage').Count | Should -Be 0
        Stop-TgWidget $proc

        Set-TgAwaySecs $data '0'
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 }) | Should -BeTrue
        Start-Sleep -Seconds 8
        $calls = Get-TgCalls $fake 'sendMessage'
        $calls.Count | Should -Be 1
        ($calls[0].body | ConvertFrom-Json).text | Should -BeLike '*Plan: refactor*'
    }

    It 'ignores a wait marker of a session seen after the marker was written' {
        # The hook removes the marker on the next event; when that delete failed, the seen stamp still tells
        $data = New-TgSandbox '0'
        $queue = Join-Path $data 'queue'
        Set-WaitMarker $queue @{ session = 's1'; kind = 'plan'; cwd = 'C:\dev\alpha'; detail = 'Plan'; created = (Get-NowMs) - 2 * 60000 }
        Write-JsonAtomic (Join-Path $queue 'seen-s1.json') ([ordered]@{ session = 's1'; at = (Get-NowMs) - 60000 })
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { Test-Path -LiteralPath (Join-Path $data 'widget.json') }) | Should -BeTrue
        Start-Sleep -Seconds 12
        (Get-TgCalls $fake 'sendMessage').Count | Should -Be 0
    }

    It 'edits the message to resolved when the session is seen again' {
        $data = New-TgSandbox
        $queue = Join-Path $data 'queue'
        [void](Add-AlertOutbox $queue @{ kind = 'permission'; session = 's1'; cwd = 'C:\dev\alpha'; detail = 'Bash: npm test'; reason = 'timeout' })
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 }) | Should -BeTrue
        (Wait-Until { (Read-SentAlerts $data).Values | Where-Object { $_.message -eq 77 } }) | Should -BeTrue
        Start-Sleep -Seconds 3
        (Get-TgCalls $fake 'editMessageText').Count | Should -Be 0
        Set-SessionSeen $queue 's1'
        (Wait-Until { (Get-TgCalls $fake 'editMessageText').Count -ge 1 }) | Should -BeTrue
        Start-Sleep -Seconds 6
        $edits = Get-TgCalls $fake 'editMessageText'
        $edits.Count | Should -Be 1
        $body = $edits[0].body | ConvertFrom-Json
        $body.message_id | Should -Be 77
        $body.text | Should -BeLike '*Bash: npm test*'
        $body.text | Should -BeLike ('*' + [char]0x2705 + ' resolved')
        (Get-TgCalls $fake 'sendMessage').Count | Should -Be 1
    }

    It 'keeps the UI responsive while Telegram does not answer' {
        $fake.Replies['sendMessage'] = @{ status = 200; body = $script:SendOk; delayMs = 15000 }
        $data = New-TgSandbox
        $queue = Join-Path $data 'queue'
        [void](Add-AlertOutbox $queue @{ kind = 'permission'; session = 's1'; cwd = 'C:\dev\alpha'; detail = 'Bash: npm test'; reason = 'timeout' })
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 }) | Should -BeTrue
        $pill = @([CcwTest.Windows]::Rects($proc.Id))
        $pill.Count | Should -BeGreaterThan 0
        $pillHeight = $pill[0][3] - $pill[0][1]
        # A request card while the send hangs: the window must grow into the card within 2 s
        $req = [ordered]@{ id = 'r1'; pid = $PID; kind = 'permission'; created = (Get-NowMs); timeout = 300; cwd = 'C:\dev\app'
            tool = 'Bash'; description = 'x'; detail = 'ls'; title = ''; change = $null; suggestions = @() }
        Write-JsonAtomic (Join-Path $queue 'req-r1.json') $req
        $grew = Wait-Until {
            $r = @([CcwTest.Windows]::Rects($proc.Id))
            $r.Count -gt 0 -and ($r[0][3] - $r[0][1]) -gt ($pillHeight + 40)
        } 2
        $grew | Should -BeTrue
    }

    It 'gives up on a call that never ends, frees the slot and logs a timeout without the token' {
        # A runspace stuck past the watchdog (a DNS lookup that never returns, 60 s for real, 3 s here): the fake holds
        # the reply for 15 s, longer than the watchdog and than the call's own 10 s timeout
        $fake.Replies['sendMessage'] = @{ status = 200; body = $script:SendOk; delayMs = 15000 }
        $data = New-TgSandbox
        $queue = Join-Path $data 'queue'
        [void](Add-AlertOutbox $queue @{ kind = 'permission'; session = 's1'; cwd = 'C:\dev\alpha'; detail = 'Bash: npm test'; reason = 'timeout' })
        $proc = Start-TgWidget $data $fake.Url @('-TelegramCallMaxSecs', '3')
        $log = Join-Path $data 'widget.log'
        # Given up once, tried again (status 0 may pass), given up again: logged as a plain timeout
        (Wait-Until { (Test-Path -LiteralPath $log) -and ([IO.File]::ReadAllText($log) -cmatch 'telegram: 0 timeout(\r?\n|$)') } 25) | Should -BeTrue
        [IO.File]::ReadAllText($log).Contains($script:Token) | Should -BeFalse
        $proc.HasExited | Should -BeFalse
    }

    It 'logs a failed send without the token, and does not retry a refusal' {
        $fake.Replies['sendMessage'] = @{ status = 403; body = '{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}' }
        $data = New-TgSandbox
        $queue = Join-Path $data 'queue'
        [void](Add-AlertOutbox $queue @{ kind = 'permission'; session = 's1'; cwd = 'C:\dev\alpha'; detail = 'Bash: npm test'; reason = 'timeout' })
        $proc = Start-TgWidget $data $fake.Url
        $log = Join-Path $data 'widget.log'
        (Wait-Until { (Test-Path -LiteralPath $log) -and ([IO.File]::ReadAllText($log) -like '*telegram: 403*') }) | Should -BeTrue
        Start-Sleep -Seconds 8
        (Get-TgCalls $fake 'sendMessage').Count | Should -Be 1
        $text = [IO.File]::ReadAllText($log)
        $text | Should -BeLike '*telegram: 403 Forbidden: bot was blocked by the user*'
        $text.Contains($script:Token) | Should -BeFalse
        @(Get-ChildItem -LiteralPath $queue -Filter 'tg-*.json').Count | Should -Be 0
    }

    It 'retries a server error once, then logs it' {
        $fake.Replies['sendMessage'] = @{ status = 500; body = '{"ok":false,"error_code":500,"description":"Internal Server Error"}' }
        $data = New-TgSandbox
        $queue = Join-Path $data 'queue'
        [void](Add-AlertOutbox $queue @{ kind = 'permission'; session = 's1'; cwd = 'C:\dev\alpha'; detail = 'Bash: npm test'; reason = 'timeout' })
        $proc = Start-TgWidget $data $fake.Url
        $log = Join-Path $data 'widget.log'
        (Wait-Until { (Test-Path -LiteralPath $log) -and ([IO.File]::ReadAllText($log) -like '*telegram: 500*') }) | Should -BeTrue
        Start-Sleep -Seconds 8
        (Get-TgCalls $fake 'sendMessage').Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $queue -Filter 'tg-*.json').Count | Should -Be 0
    }

    It 'sends a finished alert at the default 5 minutes, before the notice expires' {
        $data = New-TgSandbox -NotifyAfter 5
        $queue = Join-Path $data 'queue'
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { Test-Path -LiteralPath (Join-Path $data 'widget.json') }) | Should -BeTrue
        Start-Sleep -Seconds 2
        # 4 min 40 s old: it expires (5 min) in 20 s, so the alert has to go out before that
        $created = (Get-NowMs) - 280000
        $file = Join-Path $queue "done-s1-$created.json"
        Write-JsonAtomic $file ([ordered]@{ session = 's1'; created = $created; cwd = 'C:\dev\alpha'
                message = 'All tests pass'; hwnd = 0; kind = 'vscode'; title = ''; desktopApp = $false })
        (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 } 25) | Should -BeTrue
        ((Get-TgCalls $fake 'sendMessage')[0].body | ConvertFrom-Json).text | Should -BeLike '*All tests pass*'
        ((Get-NowMs) - $created) | Should -BeLessThan 300000
    }

    It 'sends a finished alert before the notice closes at closeAfter, when that comes before notifyAfter' {
        $data = New-TgSandbox -NotifyAfter 3
        [IO.File]::WriteAllText((Join-Path $data 'prefs.json'), '{"telegram":true,"notifyAfter":3,"closeAfter":1,"volume":0}')
        $queue = Join-Path $data 'queue'
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { Test-Path -LiteralPath (Join-Path $data 'widget.json') }) | Should -BeTrue
        # 48 s old: it closes at 1 min, so the alert is due at 45 s, not at 3 min
        $created = (Get-NowMs) - 48000
        Write-JsonAtomic (Join-Path $queue "done-s1-$created.json") ([ordered]@{ session = 's1'; created = $created; cwd = 'C:\dev\alpha'
                message = 'Build is green'; hwnd = 0; kind = 'vscode'; title = ''; desktopApp = $false })
        (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 } 12) | Should -BeTrue
        ((Get-TgCalls $fake 'sendMessage')[0].body | ConvertFrom-Json).text | Should -BeLike '*Build is green*'
        ((Get-NowMs) - $created) | Should -BeLessThan 60000
    }

    It 'closes a finished notice when its window comes to the front, and does not alert for it' {
        $win = New-FrontWindow
        if (-not $win) { Set-ItResult -Skipped -Because 'Windows did not let this process take the foreground'; return }
        try {
            $data = New-TgSandbox '0'
            $queue = Join-Path $data 'queue'
            # Just past X (1 min): a notice is due only for 60 s after X
            $created = (Get-NowMs) - 62000
            $seenFile = Join-Path $queue "done-s1-$created.json"
            $otherFile = Join-Path $queue "done-s2-$created.json"
            Write-JsonAtomic $seenFile ([ordered]@{ session = 's1'; created = $created; cwd = 'C:\dev\alpha'
                    message = 'Alpha is done'; hwnd = $win.Handle.ToInt64(); kind = ''; title = ''; desktopApp = $false })
            Write-JsonAtomic $otherFile ([ordered]@{ session = 's2'; created = $created; cwd = 'C:\dev\beta'
                    message = 'Beta is done'; hwnd = 1; kind = ''; title = ''; desktopApp = $false })
            $proc = Start-TgWidget $data $fake.Url
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and (Get-TgCalls $fake 'sendMessage').Count -lt 1) {
                # (starting the widget process can pull the foreground away: bring the window back, as you would)
                [void][CcwTest.Front]::Take($win.Handle)
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 250
            }
            (Get-TgCalls $fake 'sendMessage').Count | Should -Be 1
            $text = ((Get-TgCalls $fake 'sendMessage')[0].body | ConvertFrom-Json).text
            $text | Should -BeLike '*Beta is done*'
            $text | Should -Not -BeLike '*Alpha is done*'
            $seenFile | Should -Not -Exist
            $otherFile | Should -Exist
        }
        finally { $win.Close() }
    }

    It 'sends while do not disturb hides the widget' {
        $data = New-TgSandbox '0'
        $queue = Join-Path $data 'queue'
        Set-Dnd $data $true
        # With do not disturb a finished notice alerts only when you are away (AWAY_SECS 0: always), within 60 s of X
        $created = (Get-NowMs) - 62000
        Write-JsonAtomic (Join-Path $queue "done-s1-$created.json") ([ordered]@{ session = 's1'; created = $created; cwd = 'C:\dev\alpha'
                message = 'Done while hidden'; hwnd = 0; kind = 'vscode'; title = ''; desktopApp = $false })
        $proc = Start-TgWidget $data $fake.Url
        (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 }) | Should -BeTrue
        @([CcwTest.Windows]::Rects($proc.Id)).Count | Should -Be 0
        ((Get-TgCalls $fake 'sendMessage')[0].body | ConvertFrom-Json).text | Should -BeLike '*Done while hidden*'
    }

    # The menu and the setup card, driven like a person would: a real right-click opens the menu, UI Automation
    # picks its items and fills the token box. The fake Bot API stands in for Telegram.
    Context 'menu and setup wizard' {
        BeforeAll {
            $script:S = Get-Strings 'en'
            $script:GetMeOk = '{"ok":true,"result":{"id":555,"is_bot":true,"first_name":"Test bot","username":"testbot"}}'
            $script:NoUpdates = '{"ok":true,"result":[]}'
            # A getUpdates reply with one "/start <code>" message per code (update ids 1, 2, ...) from Alex, chat 999
            function New-StartUpdates([string[]]$Codes) {
                $i = 0
                $result = @(foreach ($c in $Codes) {
                        $i++
                        [ordered]@{ update_id = $i; message = [ordered]@{ message_id = $i; from = @{ id = 999; first_name = 'Alex' }
                                chat = [ordered]@{ id = 999; first_name = 'Alex'; type = 'private' }; text = "/start $c" } }
                    })
                return (@{ ok = $true; result = $result } | ConvertTo-Json -Depth 6 -Compress)
            }
            function Start-ShownTgWidget([string]$Data) {
                $p = Start-TgWidget $Data $fake.Url
                Wait-WidgetShown $p $Data | Should -BeTrue
                return $p
            }
            # Right-click > Telegram: the submenu, rebuilt as it opens
            function Open-TgMenu($Proc) {
                Open-WidgetMenu $Proc | Should -BeTrue
                $tg = Wait-WidgetElement $Proc -Name $S.menuTelegram
                $tg | Should -Not -BeNullOrEmpty
                Expand-WidgetElement $tg
                Start-Sleep -Milliseconds 500
            }
            # Right-click > Telegram > Connect Telegram...: step 1 of the setup card
            function Start-TgSetup($Proc) {
                Open-TgMenu $Proc
                Invoke-WidgetElement (Wait-WidgetElement $Proc -Name $S.tgConnect)
                (Wait-WidgetElement $Proc -Id 'TgToken') | Should -Not -BeNullOrEmpty
            }
            function Submit-TgToken($Proc, [string]$Text) {
                $box = Wait-WidgetElement $Proc -Id 'TgToken'
                $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Text)
                Invoke-WidgetElement (Wait-WidgetElement $Proc -Id 'TgNext')
            }
            # Steps 1 and 2 with a good token; returns the one-time code of the "Open my bot" link
            function Get-TgStartCode($Proc) {
                Start-TgSetup $Proc
                Submit-TgToken $Proc $script:Token
                $btn = Wait-WidgetElement $Proc -Id 'TgOpenBot'
                $btn | Should -Not -BeNullOrEmpty
                $link = $btn.Current.HelpText
                $link | Should -Match '^https://t\.me/testbot\?start=[0-9a-f]{16}$'
                return ($link -split '=')[-1]
            }
        }
        BeforeEach {
            $fake.Replies['getMe'] = $script:GetMeOk
            $fake.Replies['getUpdates'] = $script:NoUpdates
            $cursor = [CcwTest.Mouse]::Position()
        }
        AfterEach { [CcwTest.Mouse]::MoveTo($cursor[0], $cursor[1]) }

        It 'menu shows Connect when not connected' {
            $data = New-TgSandbox -NotConnected
            $proc = Start-ShownTgWidget $data
            Open-TgMenu $proc
            (Wait-WidgetElement $proc -Name $S.tgConnect) | Should -Not -BeNullOrEmpty
            (Find-WidgetElement $proc -Name $S.menuClose) | Should -Not -BeNullOrEmpty
            (Find-WidgetElement $proc -Name $S.tgConnectCaption) | Should -Not -BeNullOrEmpty
            (Find-WidgetElement $proc -Name $S.tgDisconnect) | Should -BeNullOrEmpty
            Join-Path $data 'widget.log' | Should -Not -Exist
        }

        It 'menu shows the connected items with the bot name' {
            $data = New-TgSandbox
            $proc = Start-ShownTgWidget $data
            Open-TgMenu $proc
            (Wait-WidgetElement $proc -Name $S.tgDisconnect) | Should -Not -BeNullOrEmpty
            foreach ($name in $S.tgAlertsOn, $S.menuAlertAfter, $S.tgSendTest, ($S.tgConnectedTo -f 'testbot')) {
                (Find-WidgetElement $proc -Name $name) | Should -Not -BeNullOrEmpty -Because $name
            }
            (Find-WidgetElement $proc -Name $S.tgConnect) | Should -BeNullOrEmpty
            Join-Path $data 'widget.log' | Should -Not -Exist
        }

        It 'a pasted token with spaces and a newline is trimmed and accepted' {
            $data = New-TgSandbox -NotConnected
            $proc = Start-ShownTgWidget $data
            Start-TgSetup $proc
            Submit-TgToken $proc ("  $script:Token `r`n")
            (Wait-Until { (Get-TgCalls $fake 'getMe').Count -ge 1 } 10) | Should -BeTrue
            (Get-TgCalls $fake 'getMe')[0].token | Should -BeExactly $script:Token
            (Wait-WidgetElement $proc -Name ($S.tgBotFound -f 'testbot')) | Should -Not -BeNullOrEmpty
            (Find-WidgetElement $proc -Id 'TgOpenBot') | Should -Not -BeNullOrEmpty
            Join-Path $data 'telegram.json' | Should -Not -Exist
        }

        It 'a bad token stays on step 1 with an error' {
            $fake.Replies['getMe'] = @{ status = 401; body = '{"ok":false,"error_code":401,"description":"Unauthorized"}' }
            $data = New-TgSandbox -NotConnected
            $proc = Start-ShownTgWidget $data
            Start-TgSetup $proc
            Submit-TgToken $proc '123:not-a-real-token'
            (Wait-WidgetElement $proc -Name $S.tgErrBadToken) | Should -Not -BeNullOrEmpty
            (Find-WidgetElement $proc -Id 'TgToken') | Should -Not -BeNullOrEmpty
            (Find-WidgetElement $proc -Id 'TgOpenBot') | Should -BeNullOrEmpty
            Join-Path $data 'telegram.json' | Should -Not -Exist
        }

        It '/start with the wrong code does not connect; the right one saves telegram.json and sends a test message' {
            $data = New-TgSandbox -NotConnected
            $proc = Start-ShownTgWidget $data
            $code = Get-TgStartCode $proc
            # Without Telegram on this PC: the code and the bot are written out, to type them on the phone
            (Find-WidgetElement $proc -Name ($S.tgPhoneHint -f $code, 'testbot')) | Should -Not -BeNullOrEmpty
            $fake.Replies['getUpdates'] = New-StartUpdates @('0123456789abcdef')
            $polls = (Get-TgCalls $fake 'getUpdates').Count
            (Wait-Until { (Get-TgCalls $fake 'getUpdates').Count -ge $polls + 2 } 15) | Should -BeTrue
            Join-Path $data 'telegram.json' | Should -Not -Exist
            (Get-TgCalls $fake 'sendMessage').Count | Should -Be 0

            $fake.Replies['getUpdates'] = New-StartUpdates @('0123456789abcdef', $code)
            (Wait-Until { Test-Path -LiteralPath (Join-Path $data 'telegram.json') } 15) | Should -BeTrue
            $cfg = Read-TelegramConfig $data
            $cfg.token | Should -BeExactly $script:Token
            $cfg.chat | Should -BeExactly '999'
            $cfg.bot | Should -BeExactly 'testbot'
            $cfg.name | Should -BeExactly 'Alex'
            (Read-Prefs $data).telegram | Should -BeTrue
            (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 } 10) | Should -BeTrue
            $body = (Get-TgCalls $fake 'sendMessage')[0].body | ConvertFrom-Json
            [string]$body.chat_id | Should -BeExactly '999'
            $body.text | Should -BeExactly $S.tgTest
            (Wait-WidgetElement $proc -Name ($S.tgStep3Title -f 'Alex')) | Should -Not -BeNullOrEmpty
            (Find-WidgetElement $proc -Name ($S.tgStep3Text -f 1)) | Should -Not -BeNullOrEmpty
            Invoke-WidgetElement (Wait-WidgetElement $proc -Id 'TgFinish')
            (Wait-Until { -not (Find-WidgetElement $proc -Id 'TgFinish') } 5) | Should -BeTrue
            (Get-TgCalls $fake 'sendMessage').Count | Should -Be 1
            Join-Path $data 'widget.log' | Should -Not -Exist
        }

        It 'cancel saves nothing' {
            $data = New-TgSandbox -NotConnected
            $proc = Start-ShownTgWidget $data
            $code = Get-TgStartCode $proc
            Invoke-WidgetElement (Wait-WidgetElement $proc -Id 'TgCancel')
            (Wait-Until { -not (Find-WidgetElement $proc -Id 'TgOpenBot') } 5) | Should -BeTrue
            # The code arrives after the cancel: nothing is bound, and the polling has stopped
            $fake.Replies['getUpdates'] = New-StartUpdates @($code)
            Start-Sleep -Seconds 2
            $polls = (Get-TgCalls $fake 'getUpdates').Count
            Start-Sleep -Seconds 4
            (Get-TgCalls $fake 'getUpdates').Count | Should -Be $polls
            Join-Path $data 'telegram.json' | Should -Not -Exist
            (Read-Prefs $data).telegram | Should -BeFalse
            (Get-TgCalls $fake 'sendMessage').Count | Should -Be 0
        }

        It 'disconnect removes telegram.json' {
            $data = New-TgSandbox
            $proc = Start-ShownTgWidget $data
            Open-TgMenu $proc
            Invoke-WidgetElement (Wait-WidgetElement $proc -Name $S.tgDisconnect)
            (Wait-Until { -not (Test-Path -LiteralPath (Join-Path $data 'telegram.json')) } 5) | Should -BeTrue
            (Read-Prefs $data).telegram | Should -BeFalse
            Join-Path $data 'widget.log' | Should -Not -Exist
        }

        It 'disconnect says so when telegram.json cannot be deleted' {
            $data = New-TgSandbox
            $proc = Start-ShownTgWidget $data
            # Held open, shared for reading only: the menu can read it, Windows refuses the delete
            $lock = [IO.File]::Open((Join-Path $data 'telegram.json'), 'Open', 'Read', 'Read')
            try {
                Open-TgMenu $proc
                Invoke-WidgetElement (Wait-WidgetElement $proc -Name $S.tgDisconnect)
                (Wait-WidgetElement $proc -Name $S.tgErrDisconnect) | Should -Not -BeNullOrEmpty
            }
            finally { $lock.Dispose() }
            Join-Path $data 'telegram.json' | Should -Exist
        }

        It 'send test sends the test message and says it went out' {
            $data = New-TgSandbox
            $proc = Start-ShownTgWidget $data
            Open-TgMenu $proc
            Invoke-WidgetElement (Wait-WidgetElement $proc -Name $S.tgSendTest)
            (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 } 10) | Should -BeTrue
            ((Get-TgCalls $fake 'sendMessage')[0].body | ConvertFrom-Json).text | Should -BeExactly $S.tgTest
            (Wait-WidgetElement $proc -Name $S.tgTestOk) | Should -Not -BeNullOrEmpty
        }

        It 'Alerts on drops what was queued while alerts were off, and sends what comes after' {
            $data = New-TgSandbox
            [IO.File]::WriteAllText((Join-Path $data 'prefs.json'), '{"telegram":false,"notifyAfter":1,"volume":0}')
            $queue = Join-Path $data 'queue'
            $old = Add-AlertOutbox $queue @{ kind = 'permission'; session = 's1'; cwd = 'C:\dev\alpha'; detail = 'Bash: old news'; reason = 'timeout'
                created = (Get-NowMs) - 60000 }
            $proc = Start-ShownTgWidget $data
            Open-TgMenu $proc
            Invoke-WidgetElement (Wait-WidgetElement $proc -Name $S.tgAlertsOn)
            (Wait-Until { (Read-Prefs $data).telegram } 5) | Should -BeTrue
            (Join-Path $queue "tg-$old.json") | Should -Not -Exist
            [void](Add-AlertOutbox $queue @{ kind = 'permission'; session = 's2'; cwd = 'C:\dev\beta'; detail = 'Bash: new one'; reason = 'timeout' })
            (Wait-Until { (Get-TgCalls $fake 'sendMessage').Count -ge 1 } 20) | Should -BeTrue
            Start-Sleep -Seconds 3
            $calls = Get-TgCalls $fake 'sendMessage'
            $calls.Count | Should -Be 1
            $text = ($calls[0].body | ConvertFrom-Json).text
            $text | Should -BeLike '*Bash: new one*'
            $text | Should -Not -BeLike '*old news*'
        }
    }
}


Describe 'widget.ps1 finished notices' -Tag 'Desktop' {
    It 'closes the notices of the window in front, not a desktop app one nor one of another window, with no Telegram' {
        $win = New-FrontWindow
        if (-not $win) { Set-ItResult -Skipped -Because 'Windows did not let this process take the foreground'; return }
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        [IO.File]::WriteAllText((Join-Path $data 'state.json'), '{"right":520,"bottom":330}')
        [IO.File]::WriteAllText((Join-Path $data 'prefs.json'), '{"volume":0}')
        $proc = $null
        try {
            $created = (Get-NowMs) - 1000
            $hwnd = $win.Handle.ToInt64()
            # Two tabs of one window, a desktop app session on that window, and a session of another window
            $files = @{}
            foreach ($n in @(@('tab1', $hwnd, $false), @('tab2', $hwnd, $false), @('desktop', $hwnd, $true), @('other', 1, $false))) {
                $files[$n[0]] = Join-Path $queue ('done-{0}-{1}.json' -f $n[0], $created)
                Write-JsonAtomic $files[$n[0]] ([ordered]@{ session = $n[0]; created = $created; cwd = 'C:\dev\alpha'
                        message = 'x'; hwnd = $n[1]; kind = ''; title = ''; desktopApp = $n[2] })
            }
            $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en',
                '-SettingsPath', ('"{0}"' -f (Join-Path $data 'settings.json'))
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and ((Test-Path $files.tab1) -or (Test-Path $files.tab2))) {
                [void][CcwTest.Front]::Take($win.Handle)
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 250
            }
            Start-Sleep -Seconds 2
            $files.tab1 | Should -Not -Exist
            $files.tab2 | Should -Not -Exist
            $files.desktop | Should -Exist
            $files.other | Should -Exist
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; [void]$proc.WaitForExit(5000) }
            $win.Close()
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
