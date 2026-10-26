# opaiva-code-widget: always-on-top desktop widget for Claude Code (Windows PowerShell 5.1 + WPF).
# Never takes focus: it sits in a corner of the screen and shows, in this order of priority:
#   1. requests written by hook.ps1 to queue\req-<id>.json, answered in queue\res-<id>.json
#        kind=permission -> Approve / Deny / Decide in VS Code
#        kind=question   -> multiple-choice questions (AskUserQuestion) -> answers
#   2. "Claude finished" notices (queue\done-<session>-<ms>.json); OK / Go to VS Code delete them
#   3. a small "no requests" pill
# It only accepts focus while you type an "Other answer", then gives focus back.
# Drag to move (position saved in state.json); right-click > Close widget.
# Started by hook.ps1 with the plugin data dir; usually you never run it by hand.
# -RenderSamples <samples.json> -OutDir <dir> [-Theme dark|light]: draws each state with sample data to transparent PNGs
# (README screenshots, see tools/render-screenshots.ps1) and exits, without touching the queue.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI. UI text lives in
# strings.json (read explicitly as UTF-8).
param(
    [string]$DataDir = (Join-Path $env:USERPROFILE '.claude\opaiva-code-widget'),
    [string]$Lang = '',
    [string]$RenderSamples = '',
    [string]$OutDir = '',
    [string]$Theme = '',
    # Claude Code settings: its "env" block holds the CLAUDE_WIDGET_* options (the widget is started through WMI)
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    # Tests only: the fake Bot API of tests\helpers\FakeTelegram.ps1. Never read from settings.
    [string]$TelegramUrl = 'https://api.telegram.org'
)
$RenderMode = [bool]$RenderSamples
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'common.ps1')
# The Bot API client: its calls only ever run in background runspaces (see "Telegram alerts")
. (Join-Path $PSScriptRoot 'telegram.ps1')
$Data = [IO.Path]::GetFullPath($DataDir).TrimEnd('\')
$Queue = Join-Path $Data 'queue'
$StatePath = Join-Path $Data 'state.json'
# hook.ps1 creates this file to ask a widget from an older version to close itself (so its tray icon is removed)
$QuitPath = Join-Path $Data 'quit.flag'
$LogPath = Join-Path $Data 'widget.log'

$Lang = Resolve-Lang $Lang
$S = Get-Strings $Lang

# CLAUDE_WIDGET_* options: the settings.json env block (read once) wins over the process environment.
# CLAUDE_WIDGET_NO_TRAY stays a plain environment variable: the tests set it for the widgets they start.
$SettingsEnv = Get-ClaudeSettingsEnv $SettingsPath
function Get-WidgetEnv([string]$Name) {
    if ($SettingsEnv.ContainsKey($Name) -and $SettingsEnv[$Name]) { return [string]$SettingsEnv[$Name] }
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($v) { return $v }
    return ''
}
# Same rules as hook.ps1: by default 5 minutes without input counts as away
$AwaySecs = ConvertTo-AwaySecs (Get-WidgetEnv 'CLAUDE_WIDGET_AWAY_SECS')

# Preferences (prefs.json): theme, opacity, volume, scale, minimal pill. The README screenshots
# (-RenderSamples) always start from the defaults, plus -Theme.
$script:prefs = if ($RenderMode) { Get-DefaultPrefs } else { Read-Prefs $Data }
if ($RenderMode -and $Theme) { $script:prefs.theme = $Theme }

# One widget per data dir; hook.ps1 computes the same name to know whether the widget is running
$MutexName = Get-MutexName $Data
$mutex = $null
if (-not $RenderMode) {
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
    if (-not $createdNew) { exit 0 }
}

$script:lastErr = $null
function Write-Log($msg) {
    $text = [string]$msg
    if ($text -eq $script:lastErr) { return }
    $script:lastErr = $text
    Write-LogLine $LogPath $text
}

try {
    if (-not $RenderMode) {
        New-Item -ItemType Directory -Force -Path $Queue | Out-Null
        # A quit request meant for the widget that was running before this one
        Remove-Item -LiteralPath $QuitPath -Force -ErrorAction SilentlyContinue
        # Lets hook.ps1 replace this widget after a plugin update (different script path)
        [IO.File]::WriteAllText((Join-Path $Data 'widget.json'), (@{ pid = $PID; script = $PSCommandPath } | ConvertTo-Json -Compress), $Utf8)
        # Responses and temp files from a previous run are useless now
        Get-ChildItem -LiteralPath $Queue -File | Where-Object { $_.Name -like 'res-*' -or $_.Name -like '*.tmp' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

    # Win32: bring VS Code to the front, keep the widget from ever becoming the active window
    # (NoActivate), and allow focus only while typing a free-text answer
    $script:canFocus = $false
    try {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'widget-native.cs'), $Utf8))
        $script:canFocus = $true
    } catch { Write-Log $_ }

    # Sounds go through Play-Sound so that the volume setting applies. The WPF MediaPlayer has a Volume;
    # the classic Windows sound APIs do not, so they are only the fallback (the volume is ignored there,
    # but 0 still means silence).
    function Get-SchemeSound([string]$soundEvent) {
        try {
            $key = Get-Item -LiteralPath "HKCU:\AppEvents\Schemes\Apps\.Default\$soundEvent\.Current" -ErrorAction Stop
            $path = [Environment]::ExpandEnvironmentVariables([string]$key.GetValue(''))
            # An entry that is only a file name lives in the Windows Media folder
            if ($path -and -not [IO.Path]::IsPathRooted($path)) { $path = Join-Path (Join-Path $env:WINDIR 'Media') $path }
            if ($path -and (Test-Path -LiteralPath $path)) { return $path }
        } catch {}
        return $null
    }
    $script:sounds = @{}
    function New-MediaSound([string]$file) {
        if (-not $file -or -not (Test-Path -LiteralPath $file)) { return $null }
        try {
            $p = New-Object System.Windows.Media.MediaPlayer
            # A file Windows cannot decode: forget it, so that the next play uses the system sound
            $p.Add_MediaFailed({ param($src, $e) foreach ($k in @($script:sounds.Keys)) { if ([object]::ReferenceEquals($script:sounds[$k], $src)) { $script:sounds[$k] = $null; Write-Log "sound $k cannot be played, using the system sound" } } })
            $p.Open([Uri]$file)
            return $p
        } catch { Write-Log $_; return $null }
    }
    # The sounds in use: the Windows ones
    if (-not $RenderMode) {
        $script:sounds.request = New-MediaSound (Get-SchemeSound 'SystemAsterisk')
        $script:sounds.done = New-MediaSound (Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav')
        $script:sounds.allDone = New-MediaSound (Join-Path $env:WINDIR 'Media\tada.wav')
    }
    function Play-Sound([string]$name, [scriptblock]$fallback) {
        $vol = [int]$script:prefs.volume
        if ($vol -le 0) { return }
        $p = $script:sounds[$name]
        if ($p) {
            try {
                $p.Volume = $vol / 100.0
                $p.Position = [TimeSpan]::Zero
                $p.Play()
                return
            } catch { Write-Log $_ }
        }
        & $fallback
    }

    # The window layout lives in widget.xaml next to this file
    [xml]$xaml = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'widget.xaml'), $Utf8)
    # The "finished" box is a template, copied once per notice (New-DoneItem): out of the window it goes.
    # Copies are parsed on their own, without the window's resources: New-DoneItem sets their styles.
    $xns = New-Object System.Xml.XmlNamespaceManager $xaml.NameTable
    $xns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $doneNode = $xaml.SelectSingleNode("//*[@x:Name='DoneItem']", $xns)
    $DoneItemXaml = $doneNode.OuterXml -replace ' Style="\{StaticResource \w+\}"', ''
    [void]$doneNode.ParentNode.RemoveChild($doneNode)

    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $ui = @{}
    foreach ($n in 'Card', 'IdlePanel', 'IdleDot', 'IdleTitle', 'IdleText', 'SessionsList', 'ChangeBox', 'ChangeLines', 'AlwaysList', 'ReqPanel', 'ReqTitle', 'QPanel', 'QTitle', 'DonePanel',
        'ReqDot', 'Countdown', 'Tool', 'ProjectChip', 'Project', 'QueueChip', 'QueueText', 'Desc', 'Detail', 'Cwd',
        'BtnApprove', 'BtnDeny', 'BtnVs', 'QCountdown', 'QDot', 'QProjectChip', 'QProject', 'QQueueChip', 'QQueueText',
        'QList', 'BtnAnswer', 'BtnQVs',
        'PanelTelegram', 'TgStepOf', 'TgSetupTitle', 'TgStepToken', 'TgStepStart', 'TgStepDone', 'TgStep1Title', 'TgHowTo1', 'TgHowTo2',
        'TgHowTo3', 'TgHowTo4', 'TgOpenBotFather', 'TgToken', 'TgStep2Title', 'TgBotFound', 'TgStep2Text', 'TgWaitDot', 'TgWaiting',
        'TgStep3Title', 'TgStep3Text', 'TgError', 'TgNext', 'TgOpenBot', 'TgFinish', 'TgCancel') {
        $ui[$n] = $win.FindName($n)
    }

    # --- Localized text ---
    $Sep = '  ' + [char]0x00B7 + '  '
    $win.Title = $S.windowTitle
    $ui.IdleText.Text = $Sep + $S.idle
    $ui.IdlePanel.ToolTip = $S.idleTip
    $ui.ReqTitle.Text = $Sep + $S.permissionTitle
    $ui.QTitle.Text = $Sep + $S.questionTitle
    $ui.BtnApprove.Content = $S.approve
    $ui.BtnDeny.Content = $S.deny
    $ui.BtnVs.Content = $S.decideInVsCode
    $ui.BtnAnswer.Content = $S.answer
    $ui.BtnQVs.Content = $S.answerInVsCode
    $ui.TgSetupTitle.Text = $S.tgSetupTitle
    $ui.TgStep1Title.Text = $S.tgStep1Title
    foreach ($i in 1..4) { $ui["TgHowTo$i"].Text = $S."tgHowTo$i" }
    $ui.TgOpenBotFather.Content = $S.tgOpenBotFather
    $ui.TgStep2Title.Text = $S.tgStep2Title
    $ui.TgStep2Text.Text = $S.tgStep2Text
    $ui.TgWaiting.Text = $S.tgWaiting
    $ui.TgOpenBot.Content = $S.tgOpenBot
    $ui.TgFinish.Content = $S.tgFinish
    $ui.TgCancel.Content = $S.tgCancel

    # --- Position: anchored by the bottom-right corner, so the card grows up/left ---
    # $script:savedAnchor is where you last dragged it (state.json). While that spot is on no screen
    # (its monitor was unplugged), the widget uses the main screen's corner, and it goes back to the
    # saved spot once that screen is back: only dragging writes state.json.
    $script:savedAnchor = $null
    try {
        if (Test-Path -LiteralPath $StatePath) { $script:savedAnchor = [IO.File]::ReadAllText($StatePath, $Utf8) | ConvertFrom-Json }
    } catch {}
    $wa = [System.Windows.SystemParameters]::WorkArea
    $script:anchorRight = $wa.Right
    $script:anchorBottom = $wa.Bottom
    # The widget keeps its top edge: everything grows downwards from there, and only moves up when it
    # would go past the bottom of its screen. $null = not known yet: the first layout takes it from
    # the bottom corner (no saved spot, or a state.json from before "top").
    $script:anchorTop = $null
    # The work area of the screen the widget is on: it never crosses into the next screen
    $script:area = @{ left = $wa.Left; top = $wa.Top; right = $wa.Right; bottom = $wa.Bottom }
    $script:screenKey = $null
    # Re-resolves the anchor if the screens changed since the last call. Returns the new anchor
    # (@{ right; bottom; saved }), or $null when nothing changed.
    function Sync-Anchor {
        $areas = @(Get-ScreenAreas)
        $key = Get-ScreenKey $areas
        if ($key -eq $script:screenKey) { return $null }
        $script:screenKey = $key
        $a = Resolve-Anchor $script:savedAnchor $areas
        if ($a) {
            $script:anchorRight = $a.right
            $script:anchorBottom = $a.bottom
            $script:anchorTop = if ($a.saved -and $null -ne $script:savedAnchor.top) { [double]$script:savedAnchor.top } else { $null }
            Set-Area $areas
        }
        return $a
    }
    # The screen the widget is on: the one under the point x, y (by default just inside its top-right
    # corner; a saved spot always lies within one screen, see the drag handler)
    function Set-Area($areas, [double]$x = ($script:anchorRight - 60), [double]$y = -1) {
        if ($y -lt 0) { $y = $(if ($null -ne $script:anchorTop) { $script:anchorTop } else { $script:anchorBottom - 60 }) + 20 }
        foreach ($s in @($areas | Where-Object { $_ })) {
            if ($x -ge $s.left -and $x -lt $s.right -and $y -ge $s.top -and $y -lt $s.bottom) { $script:area = $s }
        }
    }
    try { [void](Sync-Anchor) } catch { Write-Log $_ }

    function Update-Position {
        # While you drag it, the widget goes where the mouse takes it (to another screen too)
        if ($script:dragging) { return }
        $right = [math]::Min($script:anchorRight, $script:area.right)
        $win.Left = [math]::Max($script:area.left, $right - $win.ActualWidth)
        if ($null -eq $script:anchorTop) { $script:anchorTop = $script:anchorBottom - $win.ActualHeight }
        $now = $win.Top
        # The stack of "finished" boxes never moves its top down while open (closing one moves the
        # ones below it up); it only moves up when a new box would not fit on the screen
        $from = if ($script:cardClear) { $now } else { $script:anchorTop }
        $top = [math]::Max($script:area.top, [math]::Min($from, $script:area.bottom - $win.ActualHeight))
        # A long way back (the pill returning to its spot after the stack): slide there
        $win.BeginAnimation([System.Windows.Window]::TopProperty, $null)
        $win.Top = $top
        if (-not $RenderMode -and -not $script:cardClear -and [math]::Abs($top - $now) -gt 40) {
            $slide = [System.Windows.Media.Animation.DoubleAnimation]::new($now, $top, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(250)))
            $slide.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
            $slide.FillBehavior = 'Stop'
            $win.BeginAnimation([System.Windows.Window]::TopProperty, $slide)
        }
    }
    $win.Left = $script:anchorRight - 220
    $win.Top = $script:anchorBottom - 70
    $win.Add_SizeChanged({ Update-Position })
    $win.Add_Loaded({ Update-Position })

    $script:hwnd = [IntPtr]::Zero
    $win.Add_SourceInitialized({
        $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
        if ($script:canFocus) { [ClaudeWidget.WinFocus]::SetNoActivate($script:hwnd, $true) }
    })

    $script:clickTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:clickTimer.Interval = [TimeSpan]::FromMilliseconds([System.Windows.Forms.SystemInformation]::DoubleClickTime)
    $script:clickTimer.Add_Tick({ param($sender, $e) $sender.Stop(); try { Switch-Sessions } catch { Write-Log $_ } })
    $win.Add_MouseLeftButtonDown({
        param($src, $e)
        # Buttons, options and the text box handle their own clicks and never get here
        if ($e.ClickCount -eq 2) { $script:clickTimer.Stop(); Invoke-DoubleClick; return }
        $left = $win.Left
        $top = $win.Top
        $win.BeginAnimation([System.Windows.Window]::TopProperty, $null)
        $script:dragging = $true
        try { $win.DragMove() } catch {} finally { $script:dragging = $false }
        # A click without a move keeps the saved spot (its monitor may be unplugged right now);
        # on the idle pill it opens or closes the sessions list
        # (after the double-click time, so that a double click does not also toggle the list)
        if ($win.Left -eq $left -and $win.Top -eq $top) { $script:clickTimer.Stop(); $script:clickTimer.Start(); return }
        # Dropped across two screens: it goes to the one holding its middle, pulled fully inside it,
        # and that is the spot saved
        try { Set-Area @(Get-ScreenAreas) ($win.Left + $win.ActualWidth / 2) ($win.Top + $win.ActualHeight / 2) } catch { Write-Log $_ }
        $script:anchorRight = $win.Left + $win.ActualWidth
        $script:anchorBottom = $win.Top + $win.ActualHeight
        $script:anchorTop = $win.Top
        Update-Position
        $script:anchorRight = $win.Left + $win.ActualWidth
        $script:anchorTop = $win.Top
        $script:anchorBottom = $win.Top + $win.ActualHeight
        $script:savedAnchor = @{ right = $script:anchorRight; bottom = $script:anchorBottom; top = $script:anchorTop }
        try { [IO.File]::WriteAllText($StatePath, ($script:savedAnchor | ConvertTo-Json -Compress), $Utf8) } catch {}
    })

    # --- State ---
    $script:cache = @{}        # req-*.json already read (file name -> request)
    $script:doneCache = @{}    # done-*.json already read
    $script:seen = @{}         # requests/notices that already played their sound
    $script:current = $null    # request/question on screen
    $script:currentDone = $null    # the top "finished" notice (double click goes to its session)
    $script:doneItems = [ordered]@{} # notice key -> @{ notice; root; ui } of each box on screen
    $script:cardClear = $false
    $script:shownAt = 0
    $script:qState = New-Object System.Collections.ArrayList   # state of the questions on screen
    $script:typing = $false    # focus allowed to type an "Other answer"
    $script:prevFg = [IntPtr]::Zero
    $script:tgClosed = @{}     # notices closed here since the last Telegram round (key -> $true)

    # Every color in this file is written in the dark theme; the current theme's map translates it
    $script:colorMap = @{}
    $script:brushes = @{}
    function New-FrozenBrush([string]$hex) {
        if (-not $script:brushes.ContainsKey($hex)) {
            $b = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex)
            $b.Freeze()
            $script:brushes[$hex] = $b
        }
        return $script:brushes[$hex]
    }
    function Get-Brush([string]$hex) { return New-FrozenBrush (Convert-ThemeColor $hex $script:colorMap) }

    # Switches the theme live: recolors every element already created (walking the logical tree), by
    # way of the dark color it started from; what is created later is translated by Get-Brush.
    function Convert-ElementColors($el, [hashtable]$back, [hashtable]$new) {
        foreach ($n in 'Foreground', 'Background', 'BorderBrush', 'Fill', 'Stroke', 'CaretBrush', 'SelectionBrush') {
            try {
                $prop = $el.GetType().GetProperty($n)
                if (-not $prop -or -not $prop.CanWrite -or $prop.GetIndexParameters().Count -ne 0) { continue }
                $b = $prop.GetValue($el, $null)
                if ($b -isnot [System.Windows.Media.SolidColorBrush] -or $b.Color.A -ne 255) { continue }
                $hex = '#{0:X2}{1:X2}{2:X2}' -f $b.Color.R, $b.Color.G, $b.Color.B
                $dark = Convert-ThemeColor $hex $back
                $target = Convert-ThemeColor $dark $new
                if ($target -ne $hex) { $prop.SetValue($el, (New-FrozenBrush $target), $null) }
            } catch {}
        }
        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($el)) {
            if ($child -is [System.Windows.DependencyObject]) { Convert-ElementColors $child $back $new }
        }
    }
    function Set-Theme([string]$name) {
        $new = Get-ColorMap $name
        $back = @{}
        foreach ($k in $script:colorMap.Keys) { $back[$script:colorMap[$k]] = $k }
        Convert-ElementColors $win $back $new
        $script:colorMap = $new
    }

    # Every way of changing the theme goes through here
    function Set-LookTheme([string]$name) {
        Set-Theme $name
    }

    # --- Focus: only while typing (an "Other answer", the Telegram token) or while the right-click menu is open ---
    # The first of the two to need it remembers where you were; the last one done gives the focus back there
    $script:menuOpen = $false
    function Open-Focus {
        if ($script:typing -or $script:menuOpen) { return }
        $script:prevFg = [ClaudeWidget.WinFocus]::Foreground()
        [ClaudeWidget.WinFocus]::SetNoActivate($script:hwnd, $false)
    }
    function Close-Focus {
        if ($script:typing -or $script:menuOpen) { return }
        [ClaudeWidget.WinFocus]::SetNoActivate($script:hwnd, $true)
        # Give focus back to where you were, if it is still on the widget
        if ([ClaudeWidget.WinFocus]::Foreground() -eq $script:hwnd -and $script:prevFg -ne [IntPtr]::Zero) {
            [void][ClaudeWidget.WinFocus]::Activate($script:prevFg)
        }
        $script:prevFg = [IntPtr]::Zero
    }

    function Enable-Typing($box) {
        if ($script:canFocus -and $script:hwnd -ne [IntPtr]::Zero) {
            if (-not $script:typing) {
                Open-Focus
                $script:typing = $true
            }
            [void][ClaudeWidget.WinFocus]::Activate($script:hwnd)
        }
        [void]$win.Activate()
        $box.UpdateLayout()
        [void]$box.Focus()
        [void][System.Windows.Input.Keyboard]::Focus($box)
    }

    function Disable-Typing {
        if (-not $script:typing) { return }
        $script:typing = $false
        if ($script:canFocus -and $script:hwnd -ne [IntPtr]::Zero) { Close-Focus }
    }

    # Windows gives mouse capture and deactivation only to the active window: a menu of a window that never has
    # the focus did not close when you clicked elsewhere. The widget is the active window while its menu is open.
    function Open-MenuFocus {
        if (-not $script:canFocus -or $script:hwnd -eq [IntPtr]::Zero) { return }
        Open-Focus
        $script:menuOpen = $true
        [void][ClaudeWidget.WinFocus]::Activate($script:hwnd)
    }
    function Close-MenuFocus {
        if (-not $script:menuOpen) { return }
        $script:menuOpen = $false
        Close-Focus
    }

    function Set-Panel([string]$name) {
        # Typing goes on only on the panel it started on (the question card, or the Telegram setup card still on screen)
        if ($name -ne 'QPanel' -and -not ($name -eq 'PanelTelegram' -and $ui.PanelTelegram.Visibility -eq 'Visible')) { Disable-Typing }
        foreach ($p in 'IdlePanel', 'ReqPanel', 'QPanel', 'DonePanel', 'PanelTelegram') {
            $v = if ($p -eq $name) { 'Visible' } else { 'Collapsed' }
            if ($ui[$p].Visibility -ne $v) { $ui[$p].Visibility = $v }
        }
        if ($name -ne 'IdlePanel') { $script:sessionsOpen = $false; $ui.SessionsList.Visibility = 'Collapsed' }
        # The stacked "finished" boxes are cards of their own: the Card around them goes see-through
        $clear = $name -eq 'DonePanel'
        if ($clear -ne $script:cardClear) {
            $script:cardClear = $clear
            $ui.Card.Background = $(if ($clear) { [System.Windows.Media.Brushes]::Transparent } else { Get-Brush '#1E1E22' })
            $ui.Card.BorderThickness = New-Object System.Windows.Thickness $(if ($clear) { 0 } else { 1 })
        }
    }

    function Invoke-Attention([string]$key, [scriptblock]$sound) {
        if ($RenderMode -or $script:seen.ContainsKey($key)) { return }
        $script:seen[$key] = $true
        & $sound
        # Re-assert "always on top" in case another window took over
        $win.Topmost = $false
        $win.Topmost = $true
    }

    # Hidden for a request that never closes by itself (closeAfter Never)
    function Set-Countdown($textBlock, $r) {
        $text = Format-Countdown $r (Get-NowMs) $S.closesIn
        $textBlock.Text = $text
        $textBlock.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
    }

    function Set-QueueChip($chip, $textBlock, [int]$total) {
        if ($total -gt 1) {
            $textBlock.Text = $S.queued -f ($total - 1)
            $chip.Visibility = 'Visible'
        }
        else { $chip.Visibility = 'Collapsed' }
    }

    function Set-ProjectChip($chip, $textBlock, $item) {
        $text = Format-SessionLine ([string]$item.cwd) ([string]$item.title)
        $textBlock.Text = $text
        $chip.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
    }

    # Queue readers live in common.ps1; the caches keep each file from being re-read every tick
    function Get-Pending { Get-PendingRequests $Queue $script:cache }
    # Notices live closeAfter (read each time: the menu can change it while the widget runs)
    function Get-Done { Get-DoneNotices $Queue $script:doneCache (Get-NoticeMaxAgeMs $script:prefs) }

    # ---------------- Permission request ----------------
    # The diff of an Edit/Write under the detail box: red removed lines, green added lines
    function Set-ChangeView($change) {
        $ui.ChangeLines.Children.Clear()
        $lines = @(Get-DiffLines $change)
        if ($lines.Count -eq 0) { $ui.ChangeBox.Visibility = 'Collapsed'; return }
        foreach ($l in $lines) {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.FontFamily = New-Object System.Windows.Media.FontFamily 'Cascadia Mono, Consolas'
            $tb.FontSize = 12
            $tb.Padding = '10,1,10,1'
            $tb.TextWrapping = 'NoWrap'
            if ($l.kind -eq 'del') { $tb.Text = '- ' + $l.text; $tb.Background = Get-Brush '#3A1E1E'; $tb.Foreground = Get-Brush '#F29090' }
            elseif ($l.kind -eq 'add') { $tb.Text = '+ ' + $l.text; $tb.Background = Get-Brush '#1E3A2A'; $tb.Foreground = Get-Brush '#7FD3A0' }
            elseif ($l.kind -eq 'edits') { $tb.Text = $S.diffMoreEdits -f $l.text; $tb.Foreground = Get-Brush '#7E7E88' }
            else { $tb.Text = $S.diffMore -f $l.text; $tb.Foreground = Get-Brush '#7E7E88' }
            [void]$ui.ChangeLines.Children.Add($tb)
        }
        $ui.ChangeBox.Visibility = 'Visible'
    }
    function Get-DestinationText([string]$dest) {
        switch ($dest) {
            'session' { $S.destSession }
            'localSettings' { $S.destLocal }
            'projectSettings' { $S.destProject }
            'userSettings' { $S.destUser }
            default { $dest }
        }
    }
    # "Always allow" buttons: one per suggestion Claude Code made (at most 3), showing the rule and where it is saved
    function Set-AlwaysButtons($r) {
        $ui.AlwaysList.Children.Clear()
        $shown = 0
        foreach ($sg in @($r.suggestions)) {
            if (-not $sg -or $shown -ge 3) { continue }
            $what = switch ([string]$sg.type) {
                'addRules' {
                    $rules = @($sg.rules)
                    $S.alwaysRule -f ((Format-RuleText $rules[0]) + $(if ($rules.Count -gt 1) { ' ' + ($S.alwaysMore -f ($rules.Count - 1)) } else { '' }))
                }
                'setMode' {
                    $key = 'mode' + ([string]$sg.mode).Substring(0, 1).ToUpperInvariant() + ([string]$sg.mode).Substring(1)
                    $S.alwaysMode -f $(if ($S.PSObject.Properties[$key]) { $S.$key } else { [string]$sg.mode })
                }
                'addDirectories' {
                    $dirs = @($sg.directories)
                    $S.alwaysDir -f ([string]$dirs[0] + $(if ($dirs.Count -gt 1) { ' ' + ($S.alwaysMore -f ($dirs.Count - 1)) } else { '' }))
                }
                default { '' }
            }
            if (-not $what) { continue }
            $full = $what + '  ' + [char]0x00B7 + '  ' + (Get-DestinationText ([string]$sg.destination))
            $btn = New-Object System.Windows.Controls.Button
            $btn.Style = $win.FindResource('Btn')
            $btn.Content = $(if ($full.Length -gt 60) { $full.Substring(0, 57) + '...' } else { $full })
            $btn.ToolTip = $full
            $btn.Height = 28
            $btn.FontSize = 12
            $btn.FontWeight = [System.Windows.FontWeights]::Normal
            $btn.Padding = '12,0'
            $btn.Margin = '0,0,8,6'
            $btn.Background = Get-Brush '#2A2A30'
            $btn.BorderBrush = Get-Brush '#3A3A42'
            $btn.Foreground = Get-Brush '#C8C8D0'
            $btn.Tag = [int]$sg.index
            $btn.Add_Click({ param($src, $e) Send-Response 'allowAlways' @{ index = [int]$src.Tag } })
            [void]$ui.AlwaysList.Children.Add($btn)
            $shown++
        }
        $ui.AlwaysList.Visibility = if ($shown -gt 0) { 'Visible' } else { 'Collapsed' }
    }
    function Show-Permission($r) {
        $ui.Tool.Text = [string]$r.tool
        Set-ProjectChip $ui.ProjectChip $ui.Project $r
        if ($r.cwd) { $ui.Cwd.Text = [string]$r.cwd; $ui.Cwd.Visibility = 'Visible' } else { $ui.Cwd.Visibility = 'Collapsed' }
        $ui.Desc.Text = [string]$r.description
        $ui.Detail.Text = [string]$r.detail
        $ui.Detail.ScrollToHome()
        # The extras must never keep the card itself from showing
        try { Set-ChangeView $r.change } catch { Write-Log $_; $ui.ChangeBox.Visibility = 'Collapsed' }
        try { Set-AlwaysButtons $r } catch { Write-Log $_; $ui.AlwaysList.Children.Clear(); $ui.AlwaysList.Visibility = 'Collapsed' }
        Set-Panel 'ReqPanel'
        Invoke-Attention $r.id { Play-Sound 'request' { [System.Media.SystemSounds]::Asterisk.Play() } }
    }

    # ---------------- Question (AskUserQuestion) ----------------
    $CheckMark = [string][char]0x2713

    function New-TextBlock([string]$text, [double]$size, [string]$color, [switch]$Bold) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $tb.FontSize = $size
        $tb.Foreground = Get-Brush $color
        $tb.TextWrapping = 'Wrap'
        if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
        return $tb
    }

    # Radio (circle) or checkbox (rounded square) drawn as shapes: same size whether on or off
    function New-Indicator([bool]$multi, [hashtable]$tag) {
        $ind = New-Object System.Windows.Controls.Grid
        $ind.Width = 16
        $ind.Height = 16
        $ind.Margin = New-Object System.Windows.Thickness 0, 1, 10, 0
        $ind.VerticalAlignment = 'Top'
        if ($multi) {
            $ring = New-Object System.Windows.Controls.Border
            $ring.CornerRadius = New-Object System.Windows.CornerRadius 4
            $ring.BorderThickness = New-Object System.Windows.Thickness 1.5
            $mark = New-TextBlock $CheckMark 11 '#FFFFFF' -Bold
            $mark.HorizontalAlignment = 'Center'
            $mark.VerticalAlignment = 'Center'
            $ring.Child = $mark
            [void]$ind.Children.Add($ring)
        }
        else {
            $ring = New-Object System.Windows.Shapes.Ellipse
            $ring.StrokeThickness = 1.5
            $mark = New-Object System.Windows.Shapes.Ellipse
            $mark.Width = 8
            $mark.Height = 8
            $mark.HorizontalAlignment = 'Center'
            $mark.VerticalAlignment = 'Center'
            [void]$ind.Children.Add($ring)
            [void]$ind.Children.Add($mark)
        }
        $tag.ring = $ring
        $tag.mark = $mark
        $tag.multi = $multi
        return $ind
    }

    function New-OptionRow([string]$label, [string]$desc, [bool]$multi, [hashtable]$tag) {
        $row = New-Object System.Windows.Controls.Border
        $row.CornerRadius = New-Object System.Windows.CornerRadius 8
        $row.BorderThickness = New-Object System.Windows.Thickness 1
        $row.Padding = New-Object System.Windows.Thickness 10, 7, 10, 7
        $row.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        $dock = New-Object System.Windows.Controls.DockPanel
        $ind = New-Indicator $multi $tag
        [System.Windows.Controls.DockPanel]::SetDock($ind, 'Left')
        [void]$dock.Children.Add($ind)
        $texts = New-Object System.Windows.Controls.StackPanel
        [void]$texts.Children.Add((New-TextBlock $label 13 '#F0F0F4' -Bold))
        if ($desc) {
            $d = New-TextBlock $desc 12 '#9A9AA4'
            $d.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
            [void]$texts.Children.Add($d)
        }
        [void]$dock.Children.Add($texts)
        $row.Child = $dock
        $row.Tag = $tag
        # Handled MouseLeftButtonDown: the click picks the option instead of dragging the window
        $row.Add_MouseLeftButtonDown({ param($src, $e) $e.Handled = $true; Select-Option $src.Tag })
        return $row
    }

    function Show-Question($r) {
        Set-ProjectChip $ui.QProjectChip $ui.QProject $r
        $ui.QList.Children.Clear()
        $script:qState = New-Object System.Collections.ArrayList
        $questions = @($r.questions)
        for ($qi = 0; $qi -lt $questions.Count; $qi++) {
            $q = $questions[$qi]
            $st = @{
                text     = [string]$q.question
                multi    = [bool]$q.multiSelect
                options  = New-Object System.Collections.ArrayList
                selected = New-Object System.Collections.ArrayList
                other    = $false
                rows     = New-Object System.Collections.ArrayList
                otherBox = $null
            }
            $block = New-Object System.Windows.Controls.StackPanel
            if ($qi -lt $questions.Count - 1) { $block.Margin = New-Object System.Windows.Thickness 0, 0, 0, 16 }

            $head = New-Object System.Windows.Controls.WrapPanel
            $head.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
            if ($q.header) {
                $chip = New-Object System.Windows.Controls.Border
                $chip.CornerRadius = New-Object System.Windows.CornerRadius 6
                $chip.Padding = New-Object System.Windows.Thickness 9, 3, 9, 3
                $chip.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
                $chip.Background = Get-Brush '#22304A'
                $chip.Child = New-TextBlock ([string]$q.header) 12 '#9DB8F5' -Bold
                [void]$head.Children.Add($chip)
            }
            if ($st.multi) {
                $hint = New-TextBlock $S.multiHint 12 '#7E7E88'
                $hint.VerticalAlignment = 'Center'
                [void]$head.Children.Add($hint)
            }
            if ($head.Children.Count -gt 0) { [void]$block.Children.Add($head) }

            $qt = New-TextBlock $st.text 13.5 '#DADAE0'
            $qt.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
            [void]$block.Children.Add($qt)

            foreach ($o in @($q.options)) {
                $label = [string]$o.label
                [void]$st.options.Add($label)
                $row = New-OptionRow $label ([string]$o.description) $st.multi @{ qi = $qi; label = $label; other = $false }
                [void]$st.rows.Add($row)
                [void]$block.Children.Add($row)
            }
            $otherRow = New-OptionRow $S.otherLabel $S.otherDesc $st.multi @{ qi = $qi; label = $null; other = $true }
            [void]$st.rows.Add($otherRow)
            [void]$block.Children.Add($otherRow)

            $box = New-Object System.Windows.Controls.TextBox
            $box.Visibility = 'Collapsed'
            $box.Background = Get-Brush '#141417'
            $box.Foreground = Get-Brush '#E8E8EC'
            $box.CaretBrush = Get-Brush '#E8E8EC'
            $box.BorderBrush = Get-Brush '#D97757'
            $box.SelectionBrush = Get-Brush '#D97757'
            $box.Padding = New-Object System.Windows.Thickness 8, 6, 8, 6
            $box.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
            $box.FontSize = 13
            $box.TextWrapping = 'Wrap'
            $box.Add_TextChanged({ Update-QVisuals })
            $box.Add_KeyDown({ param($src, $e) if ($e.Key -eq 'Return') { $e.Handled = $true; Submit-Answers } })
            $st.otherBox = $box
            [void]$block.Children.Add($box)

            [void]$ui.QList.Children.Add($block)
            [void]$script:qState.Add($st)
        }
        Update-QVisuals
        Set-Panel 'QPanel'
        Invoke-Attention $r.id { Play-Sound 'request' { [System.Media.SystemSounds]::Asterisk.Play() } }
    }

    function Select-Option([hashtable]$tag) {
        $st = $script:qState[[int]$tag.qi]
        if ($tag.other) {
            if ($st.multi) { $st.other = -not $st.other }
            else { $st.selected.Clear(); $st.other = $true }
        }
        elseif ($st.multi) {
            if ($st.selected.Contains($tag.label)) { $st.selected.Remove($tag.label) } else { [void]$st.selected.Add($tag.label) }
        }
        else {
            $st.selected.Clear()
            [void]$st.selected.Add($tag.label)
            $st.other = $false
        }
        Update-QVisuals
        if ($tag.other -and $st.other) { Enable-Typing $st.otherBox }
        elseif (-not ($script:qState | Where-Object { $_.other })) { Disable-Typing }
    }

    function Update-QVisuals {
        $complete = $true
        foreach ($st in $script:qState) {
            foreach ($row in $st.rows) {
                $t = $row.Tag
                $on = if ($t.other) { $st.other } else { $st.selected.Contains($t.label) }
                $row.Background = Get-Brush $(if ($on) { '#3A2A24' } else { '#24242A' })
                $row.BorderBrush = Get-Brush $(if ($on) { '#D97757' } else { '#34343B' })
                $ringColor = Get-Brush $(if ($on) { '#D97757' } else { '#6E6E78' })
                $t.mark.Visibility = if ($on) { 'Visible' } else { 'Hidden' }
                if ($t.multi) {
                    # Checkbox: filled orange square with a white check
                    $t.ring.BorderBrush = $ringColor
                    $t.ring.Background = Get-Brush $(if ($on) { '#D97757' } else { '#00000000' })
                }
                else {
                    # Radio: orange ring with an orange dot
                    $t.ring.Stroke = $ringColor
                    $t.mark.Fill = Get-Brush '#D97757'
                }
            }
            $st.otherBox.Visibility = if ($st.other) { 'Visible' } else { 'Collapsed' }
            $otherText = $st.otherBox.Text.Trim()
            # A checked "Other answer" needs text; otherwise one checked option is enough
            $ok = if ($st.other) { $otherText.Length -gt 0 } else { $st.selected.Count -gt 0 }
            if (-not $ok) { $complete = $false }
        }
        $ui.BtnAnswer.IsEnabled = $complete
        $ui.BtnAnswer.Opacity = if ($complete) { 1.0 } else { 0.45 }
    }

    function Submit-Answers {
        $r = $script:current
        if (-not $r -or $r.kind -ne 'question' -or (Test-ClickTooSoon)) { return }
        if (-not $ui.BtnAnswer.IsEnabled) { return }
        # answers: question text -> chosen label (several: "A, B"); free text goes as typed
        $answers = [ordered]@{}
        foreach ($st in $script:qState) {
            $parts = New-Object System.Collections.ArrayList
            foreach ($label in $st.options) { if ($st.selected.Contains($label)) { [void]$parts.Add($label) } }
            if ($st.other) { [void]$parts.Add($st.otherBox.Text.Trim()) }
            $answers[$st.text] = ($parts -join ', ')
        }
        $res = Join-Path $Queue "res-$($r.id).json"
        if (-not (Test-Path -LiteralPath $res)) { Write-JsonAtomic $res ([ordered]@{ decision = 'answer'; answers = $answers }) }
        $script:current = $null
        Update-View
    }

    # ---------------- Views ----------------
    # --- Sessions list on the idle pill ---
    $script:sessionsOpen = $false
    $script:titles = @{}        # session id -> @{ at; text }
    $script:sessionRows = @()
    $script:sessionsAt = 0
    # Working sessions, with their title (re-read at most every 15 s, only while the list is open)
    # and whether a request from their project is waiting for you
    function Get-SessionRows {
        $busy = @(Get-BusySessions (Join-Path $Data 'busy') (12 * 3600 * 1000) (15 * 60 * 1000))
        $waiting = @{}
        foreach ($r in @(Get-Pending)) { $waiting[[string]$r.cwd] = $true }
        foreach ($b in $busy) {
            $c = $script:titles[$b.id]
            if ($script:sessionsOpen -and (-not $c -or ((Get-NowMs) - $c.at) -gt 15000)) {
                $c = @{ at = Get-NowMs; text = (Get-SessionTitle $b.transcript $b.id) }
                $script:titles[$b.id] = $c
            }
            [pscustomobject]@{ cwd = $b.cwd; title = $(if ($c) { $c.text } else { '' }); since = $b.since; waiting = $waiting.ContainsKey($b.cwd) }
        }
    }
    # Pill text ("no requests" / "N working") and, while open, one row per session (at most 8)
    function Set-SessionRows($rows) {
        $rows = @($rows)
        $script:sessionRows = $rows
        $ui.IdleText.Text = $Sep + $(if ($rows.Count -eq 0) { $S.idle } elseif ($rows.Count -eq 1) { $S.workingOne } else { $S.workingMany -f $rows.Count })
        Update-IdleLook
        if ($rows.Count -eq 0) { $script:sessionsOpen = $false }
        $list = $ui.SessionsList
        $list.Children.Clear()
        $list.Visibility = if ($script:sessionsOpen) { 'Visible' } else { 'Collapsed' }
        if (-not $script:sessionsOpen) { return }
        foreach ($r in @($rows | Select-Object -First 8)) {
            $row = New-Object System.Windows.Controls.DockPanel
            $row.Margin = '0,3,0,3'
            $dot = New-Object System.Windows.Shapes.Ellipse
            $dot.Width = 7
            $dot.Height = 7
            $dot.Margin = '0,0,8,0'
            $dot.VerticalAlignment = 'Center'
            $dot.Fill = Get-Brush $(if ($r.waiting) { '#D97757' } else { '#5FB98A' })
            [System.Windows.Controls.DockPanel]::SetDock($dot, 'Left')
            $mins = [int][math]::Floor(((Get-NowMs) - [int64]$r.since) / 60000)
            $age = New-TextBlock $(if ($mins -lt 1) { $S.now } elseif ($mins -lt 60) { $S.minutesAgo -f $mins } else { $S.hoursAgo -f [math]::Floor($mins / 60) }) 11.5 '#7E7E88'
            $age.Margin = '14,0,0,0'
            $age.VerticalAlignment = 'Center'
            [System.Windows.Controls.DockPanel]::SetDock($age, 'Right')
            $name = New-TextBlock (Format-SessionLine ([string]$r.cwd) ([string]$r.title)) 12 '#C8C8D0'
            $name.TextWrapping = 'NoWrap'
            $name.VerticalAlignment = 'Center'
            [void]$row.Children.Add($dot)
            [void]$row.Children.Add($age)
            [void]$row.Children.Add($name)
            [void]$list.Children.Add($row)
        }
        if ($rows.Count -gt 8) {
            [void]$list.Children.Add((New-TextBlock ($S.sessionsMore -f ($rows.Count - 8)) 11.5 '#7E7E88'))
        }
    }
    function Update-Sessions { Set-SessionRows @(Get-SessionRows) }
    # A click on the idle pill opens or closes the list
    function Switch-Sessions {
        if ($ui.IdlePanel.Visibility -ne 'Visible' -or $script:sessionRows.Count -eq 0) { return }
        $script:sessionsOpen = -not $script:sessionsOpen
        $script:sessionsAt = 0
        Update-Sessions
    }
    function Show-Idle {
        $wasIdle = $ui.IdlePanel.Visibility -eq 'Visible'
        $script:current = $null
        $script:currentDone = $null
        Set-Panel 'IdlePanel'
        # Re-read the sessions every ~2 s, not on every 400 ms tick
        if (-not $wasIdle -or ((Get-NowMs) - $script:sessionsAt) -gt 2000) {
            $script:sessionsAt = Get-NowMs
            Update-Sessions
        }
    }

    function Show-Request($r, [int]$total) {
        $script:currentDone = $null
        if (-not $script:current -or $script:current.id -ne $r.id) {
            $script:current = $r
            $script:shownAt = Get-NowMs
            if ($r.kind -eq 'question') { Show-Question $r } else { Show-Permission $r }
        }
        if ($r.kind -eq 'question') {
            Set-QueueChip $ui.QQueueChip $ui.QQueueText $total
            Set-Countdown $ui.QCountdown $r
        }
        else {
            Set-QueueChip $ui.QueueChip $ui.QueueText $total
            Set-Countdown $ui.Countdown $r
        }
    }

    # ---------------- "Finished" notices: one box each, newest on top ----------------
    # Past this many boxes the last one shows "+N more" (the card grows up from its corner)
    $DoneMaxShown = 4

    # A box for one notice, from the DoneItem template, in the current theme's colors
    function New-DoneItem($d) {
        $root = [Windows.Markup.XamlReader]::Parse($DoneItemXaml)
        $it = @{ notice = $d; root = $root; ui = @{} }
        foreach ($n in 'DoneTitle', 'DoneAgo', 'DoneTimer', 'DoneProjectChip', 'DoneProject', 'DoneMoreChip', 'DoneMoreText',
            'DoneMsg', 'BtnGoVs', 'BtnDismiss', 'BtnDoneClose') {
            $it.ui[$n] = $root.FindName($n)
        }
        foreach ($n in 'BtnGoVs', 'BtnDismiss', 'BtnDoneClose') { $it.ui[$n].Style = $win.Resources['Btn'] }
        foreach ($n in 'DoneProjectChip', 'DoneMoreChip') { $it.ui[$n].Style = $win.Resources['Chip'] }
        Convert-ElementColors $root @{} $script:colorMap
        $it.ui.DoneTitle.Text = $Sep + $(if ($d.question) { $S.doneQuestionTitle } else { $S.doneTitle })
        Set-ProjectChip $it.ui.DoneProjectChip $it.ui.DoneProject $d
        $it.ui.DoneMsg.Text = [string]$d.message
        $it.ui.BtnGoVs.Content = switch ([string]$d.kind) {
            'terminal' { $S.goToTerminal }
            'other' { $S.goToWindow }
            default { $S.goToVsCode }
        }
        $it.ui.BtnDismiss.Content = $S.ok
        # Each button knows its notice by key
        foreach ($b in 'BtnGoVs', 'BtnDismiss', 'BtnDoneClose') { $it.ui[$b].Tag = [string]$d.key }
        $it.ui.BtnDismiss.Add_Click({ param($src, $e) Close-DoneNotice ([string]$src.Tag) })
        $it.ui.BtnDoneClose.Add_Click({ param($src, $e) Close-DoneNotice ([string]$src.Tag) })
        $it.ui.BtnGoVs.Add_Click({ param($src, $e) Close-DoneNotice ([string]$src.Tag) -GoToSession })
        return $it
    }

    # Every tick: how long ago, the countdown ring, and "+N more" on the last box
    function Update-DoneItem($it, [int]$hidden) {
        $d = $it.notice
        $mins = [int][math]::Floor(((Get-NowMs) - [int64]$d.created) / 60000)
        if ($mins -lt 1) { $it.ui.DoneAgo.Text = $S.now }
        elseif ($mins -lt 60) { $it.ui.DoneAgo.Text = $S.minutesAgo -f $mins }
        else { $it.ui.DoneAgo.Text = $S.hoursAgo -f [math]::Floor($mins / 60) }
        # Countdown ring: one dash as long as the time left, in units of the stroke thickness
        # (0.0, not 0: with an int first argument PowerShell picks Max(int, int) and rounds the fraction)
        $left = [math]::Max(0.0, 1 - ((Get-NowMs) - [int64]$d.created) / (Get-NoticeMaxAgeMs $script:prefs))
        $ring = $it.ui.DoneTimer
        # Never closes by itself: no countdown (Hidden keeps the header layout)
        $ring.Visibility = if ([int]$script:prefs.closeAfter -eq 0) { 'Hidden' } else { 'Visible' }
        $len = [math]::PI * ($ring.Width - $ring.StrokeThickness) / $ring.StrokeThickness
        $ring.StrokeDashArray = [System.Windows.Media.DoubleCollection]::new([double[]]@(($left * $len), $len))
        if ($hidden -gt 0) {
            $it.ui.DoneMoreText.Text = if ($hidden -eq 1) { $S.moreOne } else { $S.moreMany -f $hidden }
            $it.ui.DoneMoreChip.Visibility = 'Visible'
        }
        else { $it.ui.DoneMoreChip.Visibility = 'Collapsed' }
    }

    # Boxes slide: a new one unfolds (pushing the ones below down), a closed one folds away (the ones
    # below move up). Height, gap and opacity go together, in $DoneMotionMs.
    $DoneMotionMs = 220
    $script:doneLeaving = New-Object System.Collections.ArrayList   # @{ root; until }: folding away
    function Start-DoneMotion($root, [bool]$In) {
        if ($RenderMode) { return }   # screenshots: boxes at rest
        $from = if ($In) { 0.0 } else { 1.0 }
        $dur = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($DoneMotionMs))
        $ease = New-Object System.Windows.Media.Animation.CubicEase
        $ease.EasingMode = 'EaseOut'
        $scale = New-Object System.Windows.Media.ScaleTransform 1.0, $from
        $root.LayoutTransform = $scale
        $a = [System.Windows.Media.Animation.DoubleAnimation]::new($from, 1.0 - $from, $dur)
        $a.EasingFunction = $ease
        $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $a)
        $root.BeginAnimation([System.Windows.UIElement]::OpacityProperty, [System.Windows.Media.Animation.DoubleAnimation]::new($from, 1.0 - $from, $dur))
        $gap = [System.Windows.Media.Animation.ThicknessAnimation]::new(
            [System.Windows.Thickness]::new(0, 0, 0, 8 * $from), [System.Windows.Thickness]::new(0, 0, 0, 8 * (1.0 - $from)), $dur)
        $gap.EasingFunction = $ease
        $root.BeginAnimation([System.Windows.FrameworkElement]::MarginProperty, $gap)
    }

    # $list: the notices, newest first. Keeps one box per notice: new ones are built in place (and ring
    # once), gone ones fold away; the boxes in between are never rebuilt.
    function Show-DoneStack($list) {
        $script:current = $null
        # Boxes done folding away leave the panel
        foreach ($l in @($script:doneLeaving)) {
            if ((Get-NowMs) -ge $l.until) { $ui.DonePanel.Children.Remove($l.root); $script:doneLeaving.Remove($l) }
        }
        $shown = @($list | Select-Object -First $DoneMaxShown)
        $keys = @($shown | ForEach-Object { [string]$_.key })
        foreach ($k in @($script:doneItems.Keys)) {
            if ($keys -contains $k) { continue }
            $root = $script:doneItems[$k].root
            $script:doneItems.Remove($k)
            Start-DoneMotion $root $false
            [void]$script:doneLeaving.Add(@{ root = $root; until = (Get-NowMs) + $DoneMotionMs + 50 })
        }
        # Oldest first, so that each new box goes right above the next older one already in place
        for ($i = $shown.Count - 1; $i -ge 0; $i--) {
            $d = $shown[$i]
            $k = [string]$d.key
            if ($script:doneItems.Contains($k)) { continue }
            $it = New-DoneItem $d
            $script:doneItems[$k] = $it
            $at = $ui.DonePanel.Children.Count
            if ($i -lt $keys.Count - 1) { $at = $ui.DonePanel.Children.IndexOf($script:doneItems[$keys[$i + 1]].root) }
            $ui.DonePanel.Children.Insert($at, $it.root)
            Start-DoneMotion $it.root $true
            $script:shownAt = Get-NowMs
            $allDone = [bool]$d.allDone
            Invoke-Attention $k {
                if ($allDone) { Play-Sound 'allDone' { [System.Media.SystemSounds]::Exclamation.Play() } }
                else { Play-Sound 'done' { [System.Media.SystemSounds]::Beep.Play() } }
            }
        }
        Set-Panel 'DonePanel'
        $script:currentDone = $shown[0]
        for ($i = 0; $i -lt $keys.Count; $i++) {
            Update-DoneItem $script:doneItems[$keys[$i]] $(if ($i -eq $keys.Count - 1) { $list.Count - $shown.Count } else { 0 })
        }
    }

    function Update-View {
        if ($script:dnd) { return }
        $p = @(Get-Pending)
        if ($p.Count -gt 0) { Show-Request $p[0] $p.Count; return }
        # The Telegram setup card waits under a request, and comes back after it
        if ($script:setup) { Show-Setup; return }
        $d = @(Get-Done)
        # (also with no notice left while the last boxes fold away)
        if ($d.Count -gt 0 -or $script:doneItems.Count -gt 0 -or $script:doneLeaving.Count -gt 0) { Show-DoneStack $d; return }
        Show-Idle
    }

    # Keeps a double click from also answering the next item in the queue
    function Test-ClickTooSoon { return ((Get-NowMs) - $script:shownAt) -lt 700 }

    function Send-Response($decision, [hashtable]$extra = @{}) {
        $r = $script:current
        if (-not $r -or (Test-ClickTooSoon)) { return }
        $res = Join-Path $Queue "res-$($r.id).json"
        if (-not (Test-Path -LiteralPath $res)) { Write-JsonAtomic $res (@{ decision = $decision } + $extra) }
        $script:current = $null
        Update-View
    }

    # The project's VS Code window (a title part equal to the project name), else any VS Code window
    function Find-VsCodeWindow([string]$project) {
        $windows = @([ClaudeWidget.WinFocus]::FindWindows('Visual Studio Code'))
        foreach ($h in $windows) {
            if (Test-TitleHasProject ([ClaudeWidget.WinFocus]::Title($h)) $project) { return $h }
        }
        if ($windows.Count -gt 0) { return $windows[0] }
        return [IntPtr]::Zero
    }

    # Brings the window remembered for the session you typed in last, if it still exists
    function Show-LatestSessionWindow {
        $dir = Join-Path $Data 'sessions'
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            try {
                $w = [IO.File]::ReadAllText($f.FullName, $Utf8) | ConvertFrom-Json
                if ([ClaudeWidget.WinFocus]::FocusHandle([int64]$w.hwnd)) { return $true }
            } catch {}
        }
        return $false
    }

    # Double click outside buttons: the finished notice's session; otherwise the latest session's
    # window, else the VS Code window of the project on screen (or any VS Code window)
    function Invoke-DoubleClick {
        if (-not $script:canFocus) { return }
        if ($script:currentDone) { Close-DoneNotice -GoToSession; return }
        if (Show-LatestSessionWindow) { return }
        $project = if ($script:current -and $script:current.cwd) { Split-Path -Leaf ([string]$script:current.cwd) } else { '' }
        $h = Find-VsCodeWindow $project
        if ($h -ne [IntPtr]::Zero) { [void][ClaudeWidget.WinFocus]::FocusHandle($h.ToInt64()) }
    }

    # Closes the notice with that key (its box's buttons), or the top one (double click).
    # -Seen: closed because you brought its session window to the front, not by a click: no click guard, and it
    # also closes a notice with no box (past the shown stack, or while do not disturb hides the boxes)
    function Close-DoneNotice([string]$Key = '', [switch]$GoToSession, [switch]$Seen) {
        # (a key no longer in the stack: a box that is already folding away)
        if ($Key -and -not $script:doneItems.Contains($Key) -and -not ($Seen -and $script:doneCache.ContainsKey($Key))) { return }
        $d = if (-not $Key) { $script:currentDone } elseif ($script:doneItems.Contains($Key)) { $script:doneItems[$Key].notice } else { $script:doneCache[$Key] }
        if (-not $d -or (-not $Seen -and (Test-ClickTooSoon))) { return }
        Remove-Item -LiteralPath $d.file -Force -ErrorAction SilentlyContinue
        # You saw it: a Telegram alert already sent for it gets edited to resolved
        $script:tgClosed[[string]$d.key] = $true
        $script:currentDone = $null
        if ($GoToSession -and $script:canFocus) {
            # The exact window remembered for that session (VS Code or terminal)...
            $focused = $d.hwnd -and [ClaudeWidget.WinFocus]::FocusHandle([int64]$d.hwnd)
            # ...otherwise, for VS Code sessions, the project's VS Code window, or any VS Code window
            if (-not $focused -and [string]$d.kind -in @('', 'vscode')) {
                $project = if ($d.cwd) { Split-Path -Leaf ([string]$d.cwd) } else { '' }
                $h = Find-VsCodeWindow $project
                if ($h -ne [IntPtr]::Zero) { [void][ClaudeWidget.WinFocus]::FocusHandle($h.ToInt64()) }
            }
        }
        Update-View
    }

    # You looked at the session: its finished notice closes (with Telegram, it can no longer alert). Runs every tick,
    # so it costs one GetForegroundWindow, and nothing at all while no notice has been read
    function Close-SeenNotices {
        if (-not $script:canFocus -or $script:doneCache.Count -eq 0) { return }
        $fg = [ClaudeWidget.WinFocus]::Foreground().ToInt64()
        # (the widget itself in front says nothing about a session)
        if ($fg -eq 0 -or $fg -eq $script:hwnd.ToInt64()) { return }
        foreach ($k in @(Get-NoticesInFront @($script:doneCache.Values) $fg)) { Close-DoneNotice $k -Seen }
    }

    $ui.BtnApprove.Add_Click({ Send-Response 'allow' })
    $ui.BtnDeny.Add_Click({ Send-Response 'deny' })
    $ui.BtnVs.Add_Click({ Send-Response 'vscode' })
    $ui.BtnAnswer.Add_Click({ Submit-Answers })
    $ui.BtnQVs.Add_Click({ Send-Response 'vscode' })

    # Hands pending requests back to VS Code and exits (right-click > Close, and the tray menu)
    function Close-Widget {
        foreach ($r in @(Get-Pending)) {
            try { Write-JsonAtomic (Join-Path $Queue "res-$($r.id).json") @{ decision = 'vscode' } } catch {}
        }
        $win.Close()
    }
    function Set-Opacity { $win.Opacity = [double]$script:prefs.opacity }
    function Set-CardScale([double]$sc) {
        $ui.Card.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $sc, $sc
    }
    function Set-Scale { Set-CardScale ([double]$script:prefs.scale); Update-Fit }
    # A tall card (a long question) at 150% would push its buttons below the screen: use the biggest
    # scale, up to the chosen one, at which the window fits the work area (the margin is not scaled)
    function Update-Fit {
        $cur = if ($ui.Card.LayoutTransform -is [System.Windows.Media.ScaleTransform]) { $ui.Card.LayoutTransform.ScaleY } else { 1.0 }
        if ($win.ActualHeight -le 0 -or $cur -le 0) { return }
        $margin = 28.0
        $unscaled = ($win.ActualHeight - $margin) / $cur + $margin
        $target = Get-FitScale ([double]$script:prefs.scale) $unscaled ([System.Windows.SystemParameters]::WorkArea.Height)
        if ([math]::Abs($target - $cur) -gt 0.005) { Set-CardScale $target }
    }
    if (-not $RenderMode) { $win.Add_SizeChanged({ try { Update-Fit } catch { Write-Log $_ } }) }
    # The idle pill's tooltip carries the status text when the pill is minimal (the text itself is hidden)
    function Update-IdleLook {
        $min = [bool]$script:prefs.minimal
        $v = if ($min) { 'Collapsed' } else { 'Visible' }
        $ui.IdleTitle.Visibility = $v
        $ui.IdleText.Visibility = $v
        $status = if ($ui.IdleText.Text.Length -gt $Sep.Length) { $ui.IdleText.Text.Substring($Sep.Length) } else { '' }
        $tip = if ($min -and $status) { $status + [Environment]::NewLine + $S.idleTip } else { $S.idleTip }
        # Only when it changed: replacing a tooltip that is open would close it
        if ($ui.IdlePanel.ToolTip -ne $tip) { $ui.IdlePanel.ToolTip = $tip }
    }
    function Set-Minimal { Update-IdleLook }
    # Right-click menu: each submenu lists fixed choices with the current one checked
    $script:prefItems = New-Object System.Collections.ArrayList
    function Sync-MenuChecks {
        foreach ($e in $script:prefItems) { $e.item.IsChecked = ($script:prefs[$e.key] -eq $e.value) }
    }
    function Set-Pref([string]$key, $value) {
        $script:prefs[$key] = $value
        switch ($key) {
            'theme' { Set-LookTheme (Resolve-Theme $script:prefs.theme (Get-WindowsLightTheme)) }
            'opacity' { Set-Opacity }
            'scale' { Set-Scale }
            'minimal' { Set-Minimal }
            # Alerts on, or just connected: what was queued while they were off must not go out now
            'telegram' { if ($value) { Remove-AlertOutbox $Queue (Get-NowMs) } }
        }
        if (-not (Save-Prefs $Data $script:prefs)) { Write-Log 'could not save prefs.json' }
        Sync-MenuChecks
    }
    function Add-ChoiceMenu($parent, [string]$header, $choices) {
        $sub = New-Object System.Windows.Controls.MenuItem
        $sub.Header = $header
        foreach ($c in $choices) {
            $item = New-Object System.Windows.Controls.MenuItem
            $item.Header = $c.label
            $item.Tag = @{ key = $c.key; value = $c.value }
            $item.Add_Click({ param($src, $e) Set-Pref $src.Tag.key $src.Tag.value })
            [void]$script:prefItems.Add(@{ item = $item; key = $c.key; value = $c.value })
            [void]$sub.Items.Add($item)
        }
        [void]$parent.Items.Add($sub)
    }
    $menu = New-Object System.Windows.Controls.ContextMenu
    Add-ChoiceMenu $menu $S.menuTheme @(
        @{ label = $S.themeDark; key = 'theme'; value = 'dark' }
        @{ label = $S.themeLight; key = 'theme'; value = 'light' }
        @{ label = $S.themeAuto; key = 'theme'; value = 'auto' })
    Add-ChoiceMenu $menu $S.menuOpacity @(foreach ($o in 1.0, 0.9, 0.8, 0.7, 0.6) { @{ label = ('{0}%' -f [int]($o * 100)); key = 'opacity'; value = [double]$o } })
    Add-ChoiceMenu $menu $S.menuVolume @(foreach ($v in 0, 25, 50, 75, 100) { @{ label = $(if ($v -eq 0) { $S.volumeMute } else { '{0}%' -f $v }); key = 'volume'; value = [int]$v } })
    Add-ChoiceMenu $menu $S.menuScale @(foreach ($z in 1.0, 1.25, 1.5) { @{ label = ('{0}%' -f [int]($z * 100)); key = 'scale'; value = [double]$z } })
    $minItem = New-Object System.Windows.Controls.MenuItem
    $minItem.Header = $S.menuMinimal
    $minItem.Add_Click({ param($src, $e) Set-Pref 'minimal' (-not [bool]$script:prefs.minimal); $src.IsChecked = [bool]$script:prefs.minimal })
    $minItem.IsChecked = [bool]$script:prefs.minimal
    [void]$menu.Items.Add($minItem)
    Add-ChoiceMenu $menu $S.menuClose @(foreach ($m in 1, 3, 5, 15, 30, 0) { @{ label = $(if ($m -eq 0) { $S.closeNever } else { $S.menuMinutes -f $m }); key = 'closeAfter'; value = [int]$m } })

    # Telegram: built again each time it opens, from telegram.json (connected or not)
    function New-MenuEntry([string]$header, [scriptblock]$onClick) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = $header
        if ($onClick) { $item.Add_Click($onClick) }
        return $item
    }
    function Update-TelegramMenu {
        $tg = $script:tgMenu
        $tg.Items.Clear()
        # The old "Alert after" choices leave with their items
        foreach ($e in @($script:prefItems | Where-Object { $_.key -eq 'notifyAfter' })) { $script:prefItems.Remove($e) }
        # (the README screenshots never read the real connection)
        $cfg = if ($RenderMode) { $null } else { Read-TelegramConfig $Data }
        if ($cfg) {
            $on = New-MenuEntry $S.tgAlertsOn { param($src, $e) Set-Pref 'telegram' (-not [bool]$script:prefs.telegram); $src.IsChecked = [bool]$script:prefs.telegram }
            $on.IsChecked = [bool]$script:prefs.telegram
            [void]$tg.Items.Add($on)
            Add-ChoiceMenu $tg $S.menuAlertAfter @(foreach ($m in 1, 3, 5) { @{ label = ($S.menuMinutes -f $m); key = 'notifyAfter'; value = [int]$m } })
            [void]$tg.Items.Add((New-MenuEntry $S.tgSendTest { Send-TelegramTest }))
            [void]$tg.Items.Add((New-MenuEntry $S.tgDisconnect { Disconnect-Telegram }))
            $caption = $S.tgConnectedTo -f $cfg.bot
        }
        else {
            [void]$tg.Items.Add((New-MenuEntry $S.tgConnect { Start-Setup }))
            $caption = $S.tgConnectCaption
        }
        [void]$tg.Items.Add((New-Object System.Windows.Controls.Separator))
        # A grey line of text, not a choice
        $note = New-MenuEntry $caption $null
        $note.IsEnabled = $false
        $note.FontSize = 11.5
        [void]$tg.Items.Add($note)
        Sync-MenuChecks
    }
    $script:tgMenu = New-MenuEntry $S.menuTelegram $null
    # (SubmenuOpened bubbles up from "Alert after" too: rebuilding then would close it)
    $script:tgMenu.Add_SubmenuOpened({ param($src, $e) if ([object]::ReferenceEquals($e.OriginalSource, $src)) { try { Update-TelegramMenu } catch { Write-Log $_ } } })
    try { Update-TelegramMenu } catch { Write-Log $_ }
    [void]$menu.Items.Add($script:tgMenu)
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    $closeItem = New-Object System.Windows.Controls.MenuItem
    $closeItem.Header = $S.closeWidget
    $closeItem.Add_Click({ Close-Widget })
    [void]$menu.Items.Add($closeItem)
    $menu.Add_Opened({ try { Open-MenuFocus } catch { Write-Log $_ } })
    # Later, at Background priority: a menu item's Click comes after Closed, and one that starts typing keeps the focus
    $menu.Add_Closed({
        [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ try { Close-MenuFocus } catch { Write-Log $_ } })
    })
    $ui.Card.ContextMenu = $menu
    Sync-MenuChecks
    # The README screenshots are always drawn at normal opacity and size
    if (-not $RenderMode) {
        Set-Opacity
        Set-Scale
    }
    Update-IdleLook
    try { Set-LookTheme (Resolve-Theme $script:prefs.theme (Get-WindowsLightTheme)) } catch { Write-Log $_ }

    # --- Tray icon and "do not disturb" ---
    # The mode is the file dnd.flag: hook.ps1 sends requests to VS Code while it exists, and here the
    # window is hidden. Re-read on every tick, so removing the file by hand works too.
    function New-DotIcon([string]$hex) {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))
        $g.FillEllipse($brush, 4, 4, 24, 24)
        $g.Dispose()
        $brush.Dispose()
        $h = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
        [ClaudeWidget.WinFocus]::DestroyIconHandle($h)
        $bmp.Dispose()
        return $icon
    }
    $script:dnd = $false
    $tray = $null
    $iconOn = $null
    $iconOff = $null
    $dndItem = $null
    function Sync-Dnd {
        $on = Test-Dnd $Data
        if ($on -eq $script:dnd) { return }
        $script:dnd = $on
        if ($tray) {
            $tray.Icon = if ($on) { $iconOff } else { $iconOn }
            $tray.Text = if ($on) { $S.trayTipDnd } else { $S.trayTip }
            $dndItem.Checked = $on
        }
        if ($on) {
            # Whatever is on screen goes back to VS Code
            foreach ($r in @(Get-Pending)) {
                try { Write-JsonAtomic (Join-Path $Queue "res-$($r.id).json") @{ decision = 'vscode' } } catch {}
            }
            $script:current = $null
            $win.Hide()
        }
        else { $win.Show() }
    }
    if (-not $RenderMode) {
        # CLAUDE_WIDGET_NO_TRAY=1 (tests): no tray icon, so killed test widgets leave no ghost icons behind
        if (-not $env:CLAUDE_WIDGET_NO_TRAY) {
            $iconOn = New-DotIcon '#D97757'
            $iconOff = New-DotIcon '#8A8A93'
            $tray = New-Object System.Windows.Forms.NotifyIcon
            $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
            $dndItem = $trayMenu.Items.Add($S.trayDnd)
            $trayClose = $trayMenu.Items.Add($S.closeWidget)
            $tray.ContextMenuStrip = $trayMenu
            $tray.Icon = $iconOn
            $tray.Text = $S.trayTip
            $toggleDnd = { Set-Dnd $Data (-not (Test-Dnd $Data)); Sync-Dnd }
            $tray.Add_MouseClick({ param($src, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $toggleDnd } })
            $dndItem.Add_Click({ & $toggleDnd })
            $trayClose.Add_Click({ Close-Widget })
            $tray.Visible = $true
        }
        $win.Add_Loaded({
            $once = New-Object System.Windows.Threading.DispatcherTimer
            $once.Interval = [TimeSpan]::FromMilliseconds(30)
            $once.Add_Tick({ param($sender, $e) $sender.Stop(); try { Sync-Dnd } catch { Write-Log $_ } })
            $once.Start()
        })

        # --- Global hotkeys (opt-in: CLAUDE_WIDGET_HOTKEYS=1) ---
        # Approve / deny act only on a permission card on screen; the third toggles "do not disturb"
        function Send-HotkeyDecision([string]$decision) {
            if ($script:current -and $script:current.kind -eq 'permission' -and -not (Test-Dnd $Data)) { Send-Response $decision }
        }
        $script:hotkeyActions = @{}
        $script:hotkeyIds = @()
        if ((Get-WidgetEnv 'CLAUDE_WIDGET_HOTKEYS') -eq '1') {
            $hotkeyDefs = @(
                @{ id = 1; name = 'CLAUDE_WIDGET_KEY_APPROVE'; text = 'Ctrl+Alt+Y'; action = { Send-HotkeyDecision 'allow' } }
                @{ id = 2; name = 'CLAUDE_WIDGET_KEY_DENY'; text = 'Ctrl+Alt+N'; action = { Send-HotkeyDecision 'deny' } }
                @{ id = 3; name = 'CLAUDE_WIDGET_KEY_DND'; text = 'Ctrl+Alt+D'; action = { Set-Dnd $Data (-not (Test-Dnd $Data)); Sync-Dnd } }
            )
            $win.Add_SourceInitialized({
                try {
                    $h = $script:hwnd
                    $source = [System.Windows.Interop.HwndSource]::FromHwnd($h)
                    $script:hotkeyHook = [System.Windows.Interop.HwndSourceHook]{
                        param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
                        if ($msg -eq 0x0312) {
                            $action = $script:hotkeyActions[[int]$wParam]
                            if ($action) {
                                $handled.Value = $true
                                try { & $action } catch { Write-Log $_ }
                            }
                        }
                        return [IntPtr]::Zero
                    }
                    $source.AddHook($script:hotkeyHook)
                    foreach ($d in $hotkeyDefs) {
                        $text = Get-WidgetEnv $d.name
                        if (-not $text) { $text = $d.text }
                        $hk = ConvertTo-Hotkey $text
                        if (-not $hk) { Write-Log "hotkey $($d.name): '$text' is not a valid hotkey"; continue }
                        if ([ClaudeWidget.HotKeys]::RegisterHotKey($h, $d.id, [uint32]$hk.mod, [uint32]$hk.vk)) {
                            $script:hotkeyActions[$d.id] = $d.action
                            $script:hotkeyIds += $d.id
                            if ($d.id -eq 1) { $ui.BtnApprove.Content = $S.approve + " ($text)" }
                            if ($d.id -eq 2) { $ui.BtnDeny.Content = $S.deny + " ($text)" }
                        }
                        else { Write-Log "hotkey $text could not be registered (another program uses it?)" }
                    }
                } catch { Write-Log $_ }
            })
        }
    }

    # Pulsing dot while a request or question is waiting (and while the Telegram setup waits for your /start)
    foreach ($dot in $ui.ReqDot, $ui.QDot, $ui.TgWaitDot) {
        $pulse = [System.Windows.Media.Animation.DoubleAnimation]::new(1.0, 0.3, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(850)))
        $pulse.AutoReverse = $true
        $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
    }

    # ---------------- Connecting Telegram (setup card) ----------------
    # Right-click > Telegram > Connect Telegram... opens it: token (getMe) -> start (/start <code> by getUpdates) -> done.
    # $script:setup is the card's state, $null when closed: @{ step; token; bot; code; name; error; busy; polling;
    # stopped; nextPollAt; focusUntil }. Nothing is saved before the right /start arrives; Cancel just forgets it.
    # The Bot API calls are under "Telegram alerts" (they share the sender's one-call-at-a-time rule).
    $script:setup = $null

    # The pasted token without spaces, line breaks or quotes around it (a token has none of them)
    function Get-SetupToken {
        $quotes = [char[]]@([char]0x22, [char]0x27, [char]0x60, [char]0x2018, [char]0x2019, [char]0x201C, [char]0x201D)
        return ($ui.TgToken.Text -replace '\s', '').Trim($quotes)
    }
    function Get-SetupLink { return 'https://t.me/{0}?start={1}' -f $script:setup.bot, $script:setup.code }

    # Draws the current step
    function Set-SetupStep {
        $st = $script:setup
        if (-not $st) { return }
        $ui.TgStepOf.Text = $S.tgStepOf -f $(switch ($st.step) { 'token' { 1 } 'start' { 2 } default { 3 } })
        $ui.TgStepToken.Visibility = if ($st.step -eq 'token') { 'Visible' } else { 'Collapsed' }
        $ui.TgStepStart.Visibility = if ($st.step -eq 'start') { 'Visible' } else { 'Collapsed' }
        $ui.TgStepDone.Visibility = if ($st.step -eq 'done') { 'Visible' } else { 'Collapsed' }
        $ui.TgNext.Visibility = $ui.TgStepToken.Visibility
        $ui.TgOpenBot.Visibility = $ui.TgStepStart.Visibility
        $ui.TgFinish.Visibility = $ui.TgStepDone.Visibility
        $ui.TgCancel.Visibility = if ($st.step -ne 'done') { 'Visible' } else { 'Collapsed' }
        $ui.TgNext.Content = if ($st.busy) { $S.tgChecking } else { $S.tgNext }
        $ok = -not $st.busy -and (Get-SetupToken).Length -gt 0
        $ui.TgNext.IsEnabled = $ok
        $ui.TgNext.Opacity = if ($ok) { 1.0 } else { 0.45 }
        $ui.TgError.Text = [string]$st.error
        $ui.TgError.Visibility = if ($st.error) { 'Visible' } else { 'Collapsed' }
        if ($st.step -eq 'start') {
            $ui.TgBotFound.Text = $S.tgBotFound -f $st.bot
            # Where the button goes (only when it changed: replacing an open tooltip would close it)
            $link = Get-SetupLink
            if ($ui.TgOpenBot.ToolTip -ne $link) { $ui.TgOpenBot.ToolTip = $link }
        }
        if ($st.step -eq 'done') {
            $ui.TgStep3Title.Text = $S.tgStep3Title -f $st.name
            $ui.TgStep3Text.Text = $S.tgStep3Text -f [int]$script:prefs.notifyAfter
        }
    }

    function Show-Setup {
        $script:current = $null
        $script:currentDone = $null
        Set-Panel 'PanelTelegram'
        # Right after you picked Connect: the token box takes the focus (not when the card comes back after a request)
        $st = $script:setup
        if ($st.step -eq 'token' -and $st.focusUntil -and (Get-NowMs) -lt $st.focusUntil) {
            $st.focusUntil = 0
            Enable-Typing $ui.TgToken
        }
    }

    # ---------------- README screenshots (-RenderSamples) ----------------
    function Save-Png($element, [string]$path) {
        $element.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $element.Arrange([System.Windows.Rect]::new([System.Windows.Point]::new(0, 0), $element.DesiredSize))
        $element.UpdateLayout()
        $scale = 2.0
        $w = [int][math]::Ceiling($element.ActualWidth * $scale)
        $h = [int][math]::Ceiling($element.ActualHeight * $scale)
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $w, $h, (96 * $scale), (96 * $scale), ([System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($element)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($path)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
    }

    function Export-Samples {
        $sample = ([IO.File]::ReadAllText($RenderSamples, $Utf8) | ConvertFrom-Json).$Lang
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        # Render the card outside the window: transparent background, shadow included
        $card = $win.Content
        $win.Content = $null
        $frame = New-Object System.Windows.Controls.Grid
        [void]$frame.Children.Add($card)
        $now = Get-NowMs

        Show-Idle
        Save-Png $frame (Join-Path $OutDir 'idle.png')

        $script:sessionsOpen = $true
        $rows = foreach ($row in @($sample.sessions)) {
            [pscustomobject]@{ cwd = [string]$row.cwd; title = [string]$row.title; since = $now - [int64]$row.minutes * 60000; waiting = [bool]$row.waiting }
        }
        Set-SessionRows $rows
        Save-Png $frame (Join-Path $OutDir 'sessions.png')
        $script:sessionsOpen = $false
        Set-SessionRows @()

        $p = $sample.permission
        $p | Add-Member -NotePropertyName id -NotePropertyValue 'sample-permission' -Force
        $p | Add-Member -NotePropertyName kind -NotePropertyValue 'permission' -Force
        $p | Add-Member -NotePropertyName created -NotePropertyValue ($now - 23000) -Force
        $p | Add-Member -NotePropertyName timeout -NotePropertyValue 300 -Force
        Show-Request $p 2
        Save-Png $frame (Join-Path $OutDir 'permission.png')

        $e = $sample.edit
        $e | Add-Member -NotePropertyName id -NotePropertyValue 'sample-edit' -Force
        $e | Add-Member -NotePropertyName kind -NotePropertyValue 'permission' -Force
        $e | Add-Member -NotePropertyName created -NotePropertyValue ($now - 41000) -Force
        $e | Add-Member -NotePropertyName timeout -NotePropertyValue 300 -Force
        Show-Request $e 1
        Save-Png $frame (Join-Path $OutDir 'edit.png')

        $q = $sample.question
        $q | Add-Member -NotePropertyName id -NotePropertyValue 'sample-question' -Force
        $q | Add-Member -NotePropertyName kind -NotePropertyValue 'question' -Force
        $q | Add-Member -NotePropertyName created -NotePropertyValue ($now - 41000) -Force
        $q | Add-Member -NotePropertyName timeout -NotePropertyValue 300 -Force
        Show-Request $q 1
        $sel = @($q.selected)
        for ($i = 0; $i -lt $script:qState.Count -and $i -lt $sel.Count; $i++) {
            foreach ($label in @($sel[$i])) { [void]$script:qState[$i].selected.Add([string]$label) }
        }
        Update-QVisuals
        Save-Png $frame (Join-Path $OutDir 'question.png')

        $d = $sample.done
        $d | Add-Member -NotePropertyName key -NotePropertyValue 'sample-done' -Force
        $d | Add-Member -NotePropertyName created -NotePropertyValue ($now - 2 * 60000) -Force
        Show-DoneStack @($d)
        Save-Png $frame (Join-Path $OutDir 'done.png')

        # The Telegram setup card, one picture per step
        $tg = $sample.telegram
        if ($tg) {
            $script:setup = @{ step = 'token'; bot = [string]$tg.bot; code = '3f9a1c07b2e4d856'; name = [string]$tg.name; error = ''; busy = $false }
            $ui.TgToken.Text = [string]$tg.token
            foreach ($step in 'token', 'start', 'done') {
                $script:setup.step = $step
                Set-SetupStep
                Show-Setup
                Save-Png $frame (Join-Path $OutDir "telegram-$step.png")
            }
            $script:setup = $null
        }
    }

    if ($RenderMode) { Export-Samples; return }

    # ---------------- Telegram alerts ----------------
    # hook.ps1 leaves the alert files of common.ps1 in the queue; the widget sends them. Every Bot API call runs in
    # a background runspace that the timer polls, one call at a time: the UI thread never waits on the network.
    # What goes out is recorded in telegram-sent.json before the call, so a restart or a second widget never sends
    # it twice (an alert lost to a crash in the middle of a send is the lesser evil).
    $TelegramScript = Join-Path $PSScriptRoot 'telegram.ps1'
    # Alerts that become due within this time of the first one go out as one message
    $TgBatchMs = 5000
    $script:tgCall = $null       # the call running: @{ kind (send|edit); call; token; and for a send alertKeys, entries, text, files, tries }
    $script:tgRetry = $null      # a send that failed in a way that may pass, tried again on the next round
    $script:tgBatchSince = 0     # when the first alert of the batch being collected became due

    # Calls a telegram.ps1 function in a runspace of its own. PowerShell classes (TelegramError) do not cross
    # runspaces, so the runspace loads telegram.ps1 itself and hands back a plain hashtable: Receive-TelegramCall.
    function Start-TelegramCall([string]$Function, [object[]]$Arguments) {
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
                param($Script, $Function, $Arguments, $BaseUrl)
                . $Script
                try { @{ ok = $true; result = (& $Function @Arguments -BaseUrl $BaseUrl) } }
                catch {
                    $e = $_.Exception
                    @{ ok = $false; status = [int]$e.Status; description = $(if ($e.Description) { [string]$e.Description } else { $e.Message }) }
                }
            }).AddArgument($TelegramScript).AddArgument($Function).AddArgument($Arguments).AddArgument($TelegramUrl)
        return @{ ps = $ps; handle = $ps.BeginInvoke(); started = Get-NowMs }
    }

    # The outcome of a finished call: @{ ok = $true; result } or @{ ok = $false; status; description }
    function Receive-TelegramCall($Call) {
        try {
            $out = @($Call.ps.EndInvoke($Call.handle))
            if ($out.Count -gt 0 -and $out[-1] -is [hashtable]) { return $out[-1] }
            return @{ ok = $false; status = 0; description = 'no result' }
        }
        catch { return @{ ok = $false; status = 0; description = $_.Exception.Message } }
        finally { $Call.ps.Dispose() }
    }

    function Write-TelegramFailure($Result, [string]$Token) {
        Write-Log ('telegram: {0} {1}' -f $Result.status, (Hide-TelegramToken ([string]$Result.description) $Token))
    }

    # ---- Calls the menu and the setup card make ----
    # Same one-call-at-a-time rule as the alerts: a queued call starts only while no alert call runs, and no alert call
    # starts while one of these runs. The longest is the setup's getUpdates long poll (20 s), only while not connected,
    # that is while no alert can go out anyway.
    $script:tgUiQueue = New-Object System.Collections.ArrayList   # @{ kind; function; arguments; setup }, oldest first
    $script:tgUiCall = $null     # the one running, with its call
    function Request-TelegramUiCall([string]$Kind, [string]$Function, [object[]]$Arguments) {
        [void]$script:tgUiQueue.Add(@{ kind = $Kind; function = $Function; arguments = $Arguments; setup = $script:setup })
    }

    # What to tell you about a failed call, by its status (never by Telegram's text)
    function Get-TelegramErrorText($Result) {
        switch ([int]$Result.status) {
            0 { return $S.tgErrNetwork }
            401 { return $S.tgErrBadToken }
            # (a token that is not even shaped like one)
            404 { return $S.tgErrBadToken }
            403 { return $S.tgErrBlocked }
            409 { return $S.tgErrWebhook }
        }
        return $S.tgErrOther -f $Result.status, $Result.description
    }

    # A short note over the widget for about 3 s (the result of Send test or Disconnect)
    $script:noteTip = $null
    function Show-TelegramNote([string]$Text) {
        if (-not $script:noteTip) {
            $script:noteTip = New-Object System.Windows.Controls.ToolTip
            $script:noteTip.PlacementTarget = $ui.Card
            $script:noteTip.Placement = 'Top'
            $script:noteTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:noteTimer.Interval = [TimeSpan]::FromSeconds(3)
            $script:noteTimer.Add_Tick({ param($sender, $e) $sender.Stop(); $script:noteTip.IsOpen = $false })
        }
        $script:noteTip.Content = $Text
        $script:noteTip.IsOpen = $true
        $script:noteTimer.Stop()
        $script:noteTimer.Start()
    }

    function Send-TelegramTest {
        if (@($script:tgUiQueue | Where-Object { $_.kind -eq 'test' }).Count -gt 0 -or ($script:tgUiCall -and $script:tgUiCall.kind -eq 'test')) { return }
        $cfg = Read-TelegramConfig $Data
        if (-not $cfg) { Show-TelegramNote $S.tgErrBadToken; return }
        Request-TelegramUiCall 'test' 'Send-TelegramText' @($cfg.token, $cfg.chat, $S.tgTest)
    }

    # Remove-TelegramConfig reports nothing: whether telegram.json is really gone is checked here
    function Disconnect-Telegram {
        Remove-TelegramConfig $Data
        Set-Pref 'telegram' $false
        if (Test-Path -LiteralPath (Join-Path $Data 'telegram.json')) {
            Write-Log 'telegram: could not delete telegram.json'
            Show-TelegramNote $S.tgErrDisconnect
        }
    }

    function Start-Setup {
        if (-not $script:setup) {
            $script:setup = @{ step = 'token'; token = ''; bot = ''; code = ''; name = ''; error = ''; busy = $false
                polling = $false; stopped = $false; nextPollAt = 0; focusUntil = 0 }
            $ui.TgToken.Text = ''
        }
        $script:setup.focusUntil = (Get-NowMs) + 2000
        Set-SetupStep
        Update-View
    }
    # Cancel, and Done once connected: the card goes (a call still running for it is ignored when it ends)
    function Close-Setup {
        $script:setup = $null
        Disable-Typing
        Update-View
    }
    function Submit-SetupToken {
        $st = $script:setup
        if (-not $st -or $st.step -ne 'token' -or $st.busy) { return }
        $token = Get-SetupToken
        if (-not $token) { return }
        $st.token = $token
        $st.busy = $true
        $st.error = ''
        Set-SetupStep
        Request-TelegramUiCall 'getMe' 'Get-TelegramBot' @($token)
    }
    # The one-time code of the "Open my bot" link: whoever sends "/start <code>" to the bot is the one bound
    function New-SetupCode {
        $bytes = New-Object byte[] 8
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    # The right /start arrived: save, alerts on, test message
    function Complete-Setup($Found) {
        $st = $script:setup
        if (-not (Save-TelegramConfig $Data $st.token ([string]$Found.chat) $st.bot ([string]$Found.name))) {
            $st.error = $S.tgErrSave
            $st.stopped = $true
            Set-SetupStep
            return
        }
        Set-Pref 'telegram' $true
        Request-TelegramUiCall 'send' 'Send-TelegramText' @($st.token, [string]$Found.chat, $S.tgTest)
        $st.token = ''
        $st.name = [string]$Found.name
        $st.step = 'done'
        $st.error = ''
        Set-SetupStep
    }

    function Complete-TelegramUiCall($Job, $Result) {
        $st = $Job.setup
        $current = $st -and [object]::ReferenceEquals($st, $script:setup)
        if (-not $Result.ok) { Write-TelegramFailure $Result ([string]$Job.arguments[0]) }
        switch ($Job.kind) {
            'getMe' {
                if (-not $current) { return }
                $st.busy = $false
                if ($Result.ok) {
                    $st.bot = [string]$Result.result.username
                    $st.code = New-SetupCode
                    $st.step = 'start'
                    $st.error = ''
                    $st.nextPollAt = 0
                    Disable-Typing
                }
                else { $st.error = Get-TelegramErrorText $Result }
                Set-SetupStep
            }
            'poll' {
                if (-not $current) { return }
                $st.polling = $false
                if ($st.step -ne 'start') { return }
                if ($Result.ok -and $Result.result) { Complete-Setup $Result.result; return }
                if ($Result.ok) { $st.error = ''; $st.nextPollAt = (Get-NowMs) + 1000 }
                # A token that stopped working, or a bot with a webhook (getUpdates refused): back to step 1
                elseif ([int]$Result.status -in @(401, 404, 409)) { $st.step = 'token'; $st.error = Get-TelegramErrorText $Result }
                # No network and the like: say so, and try again a bit later
                else { $st.error = Get-TelegramErrorText $Result; $st.nextPollAt = (Get-NowMs) + 3000 }
                Set-SetupStep
            }
            'send' {
                if (-not $Result.ok -and $current -and $st.step -eq 'done') { $st.error = Get-TelegramErrorText $Result; Set-SetupStep }
            }
            'test' { Show-TelegramNote $(if ($Result.ok) { $S.tgTestOk } else { Get-TelegramErrorText $Result }) }
        }
    }

    # Every tick: ends the call that finished, keeps the setup's long poll going, starts the next queued call
    function Update-TelegramUi {
        if ($script:tgUiCall) {
            if (-not $script:tgUiCall.call.handle.IsCompleted) { return }
            $job = $script:tgUiCall
            $script:tgUiCall = $null
            Complete-TelegramUiCall $job (Receive-TelegramCall $job.call)
        }
        $st = $script:setup
        if ($st -and $st.step -eq 'start' -and -not $st.polling -and -not $st.stopped -and (Get-NowMs) -ge $st.nextPollAt) {
            $st.polling = $true
            Request-TelegramUiCall 'poll' 'Find-TelegramStart' @($st.token, $st.code, [int64]0, 20)
        }
        if ($script:tgCall) { return }
        while ($script:tgUiQueue.Count -gt 0) {
            $job = $script:tgUiQueue[0]
            $script:tgUiQueue.RemoveAt(0)
            # The setup it was for was cancelled meanwhile
            if ($job.kind -in @('getMe', 'poll') -and -not [object]::ReferenceEquals($job.setup, $script:setup)) { continue }
            $job.call = Start-TelegramCall $job.function $job.arguments
            $script:tgUiCall = $job
            return
        }
    }

    $ui.TgOpenBotFather.Add_Click({ try { Start-Process 'https://t.me/BotFather' } catch { Write-Log $_ } })
    $ui.TgNext.Add_Click({ Submit-SetupToken })
    $ui.TgOpenBot.Add_Click({ if ($script:setup) { try { Start-Process (Get-SetupLink) } catch { Write-Log $_ } } })
    $ui.TgFinish.Add_Click({ Close-Setup })
    $ui.TgCancel.Add_Click({ Close-Setup })
    $ui.TgToken.Add_TextChanged({ if ($script:setup -and $script:setup.step -eq 'token') { $script:setup.error = ''; Set-SetupStep } })
    $ui.TgToken.Add_KeyDown({ param($src, $e) if ($e.Key -eq 'Return') { $e.Handled = $true; Submit-SetupToken } })
    # The card came back after a request: clicking the box lets you type again
    $ui.TgToken.Add_PreviewMouseLeftButtonDown({ if ($script:setup -and $script:setup.step -eq 'token') { Enable-Typing $ui.TgToken } })

    function Send-AlertBatch($Job, $Config) {
        $Job.kind = 'send'
        $Job.token = $Config.token
        $Job.call = Start-TelegramCall 'Send-TelegramText' @($Config.token, $Config.chat, $Job.text)
        $script:tgCall = $Job
    }

    # A call ended. A delivered batch keeps its message id (for the resolved edit) and its outbox files go. A send
    # that failed in a way that may pass (Test-TelegramRetryable) is tried once more on the next round; otherwise,
    # or after that, it is logged and dropped: its keys stay, so it never goes out late.
    function Complete-TelegramCall {
        $job = $script:tgCall
        $script:tgCall = $null
        $r = Receive-TelegramCall $job.call
        if ($job.kind -eq 'edit') {
            if (-not $r.ok) { Write-TelegramFailure $r $job.token }
            return
        }
        if ($r.ok) {
            $sent = Read-SentAlerts $Data
            foreach ($k in $job.alertKeys) {
                $e = $job.entries[$k]
                $e.message = [int64]$r.result
                $sent[$k] = $e
            }
            if (-not (Save-SentAlerts $Data $sent)) { Write-Log 'telegram: could not save telegram-sent.json' }
        }
        elseif ($job.tries -lt 2 -and (Test-TelegramRetryable ([int]$r.status))) { $job.tries++; $script:tgRetry = $job; return }
        else { Write-TelegramFailure $r $job.token }
        foreach ($f in $job.files) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    # Every ~2 s from the timer, before Update-View: that one stops in do not disturb, these alerts do not
    function Update-Alerts {
        if ($script:tgCall) {
            if (-not $script:tgCall.call.handle.IsCompleted) { return }
            Complete-TelegramCall
        }
        # One call at a time: a menu or setup call is running
        if ($script:tgUiCall) { return }
        if (-not (Test-TelegramReady $Data $script:prefs)) {
            $script:tgRetry = $null
            $script:tgBatchSince = 0
            $script:tgClosed.Clear()
            return
        }
        if ($script:tgRetry) {
            $job = $script:tgRetry
            $script:tgRetry = $null
            $cfg = Read-TelegramConfig $Data
            if ($cfg) { Send-AlertBatch $job $cfg } else { Write-Log 'telegram: cannot read telegram.json' }
            return
        }

        $now = Get-NowMs
        Remove-OldAlertFiles $Queue $now
        $seen = Get-SeenStamps $Queue
        $sent = Read-SentAlerts $Data
        # Get-DueAlerts is pure: outbox entries already sent, stale or answered meanwhile are deleted here
        $outbox = New-Object System.Collections.ArrayList
        foreach ($e in @(Read-AlertFiles $Queue 'tg')) {
            if ($sent.ContainsKey("req:$($e.id)") -or ($now - [int64]$e.created) -gt 30 * 60 * 1000 -or @(Select-UnseenAlerts @($e) $seen).Count -eq 0) {
                Remove-Item -LiteralPath $e.file -Force -ErrorAction SilentlyContinue
            }
            else { [void]$outbox.Add($e) }
        }
        $waits = @(Select-UnseenAlerts @(Read-AlertFiles $Queue 'wait') $seen)
        $notices = @(Select-UnseenAlerts @(Get-Done) $seen)
        $away = (Get-IdleSeconds) -ge $AwaySecs
        $afterMs = [int64]$script:prefs.notifyAfter * 60000
        # Notices are deleted at closeAfter: due 15 s before that when it comes first, or one would be gone before it alerts
        $due = @(Get-DueAlerts $outbox $notices $waits $sent $now $afterMs $away (Test-Dnd $Data) -NoticeAfterMs (Get-NoticeAlertMs $script:prefs))

        if ($due.Count -eq 0) { $script:tgBatchSince = 0 }
        elseif ($script:tgBatchSince -eq 0) { $script:tgBatchSince = $now }
        elseif ($now - $script:tgBatchSince -ge $TgBatchMs) {
            $cfg = Read-TelegramConfig $Data
            if (-not $cfg) { Write-Log 'telegram: cannot read telegram.json'; return }
            $script:tgBatchSince = 0
            $job = @{ entries = @{}; text = (Format-AlertText $due $S); tries = 1 }
            foreach ($a in $due) {
                $entry = @{ message = $null; session = [string]$a.session; at = $now; resolved = $false; text = $job.text; edited = $false }
                $job.entries[$a.key] = $entry
                $sent[$a.key] = $entry
            }
            $job.alertKeys = @($job.entries.Keys)
            # Recorded first: what could not be recorded is not sent (a restart would send it again)
            if (-not (Save-SentAlerts $Data $sent)) { Write-Log 'telegram: could not save telegram-sent.json'; return }
            $job.files = @($outbox | Where-Object { $job.entries.ContainsKey("req:$($_.id)") } | ForEach-Object { $_.file })
            Send-AlertBatch $job $cfg
            return
        }

        # Resolved: at most one edit per round, the next message on a later round
        if (Update-ResolvedAlerts $sent $seen $script:tgClosed) { [void](Save-SentAlerts $Data $sent) }
        $script:tgClosed.Clear()
        $edit = Get-ResolvedEdit $sent
        if (-not $edit) { return }
        $cfg = Read-TelegramConfig $Data
        if (-not $cfg) { Write-Log 'telegram: cannot read telegram.json'; return }
        # Marked first, like a send: an edit is tried once, never in a loop
        foreach ($k in $edit.alertKeys) { $sent[$k].edited = $true }
        if (-not (Save-SentAlerts $Data $sent)) { Write-Log 'telegram: could not save telegram-sent.json'; return }
        $script:tgCall = @{ kind = 'edit'; token = $cfg.token
            call = Start-TelegramCall 'Edit-TelegramText' @($cfg.token, $cfg.chat, $edit.message, (Format-ResolvedText $edit.text $S.tgResolved)) }
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:ticks = 0
    $timer.Add_Tick({
        # A newer version of the plugin asks this widget to close itself (and take its tray icon with it)
        if (Test-Path -LiteralPath $QuitPath) {
            Remove-Item -LiteralPath $QuitPath -Force -ErrorAction SilentlyContinue
            Close-Widget
            return
        }
        try { Sync-Dnd } catch { Write-Log $_ }
        try { Close-SeenNotices } catch { Write-Log $_ }
        # (before the alerts: a call you are waiting for gets the free slot first)
        try { Update-TelegramUi } catch { Write-Log $_ }
        if ($script:ticks % 5 -eq 0) { try { Update-Alerts } catch { Write-Log $_ } }
        try { Update-View } catch { Write-Log $_ }
        # Every ~2 s: a monitor unplugged or back, a resolution change, the taskbar moved
        $script:ticks++
        if ($script:ticks % 5 -eq 0) {
            try {
                $a = Sync-Anchor
                if ($a) {
                    Update-Position
                    Write-Log ('screens changed: anchor {0},{1} ({2})' -f [int]$a.right, [int]$a.bottom, $(if ($a.saved) { 'saved' } else { 'default' }))
                }
            } catch { Write-Log $_ }
        }
    })
    $win.Add_Closed({
        $timer.Stop()
        foreach ($id in @($script:hotkeyIds)) { [void][ClaudeWidget.HotKeys]::UnregisterHotKey($script:hwnd, $id) }
        if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    })
    $timer.Start()

    # Application.Run (not ShowDialog) honors ShowActivated=False: no focus stealing on start
    $app = New-Object System.Windows.Application
    [void]$app.Run($win)
}
catch {
    if ($RenderMode) { throw }
    Write-Log $_
}
finally {
    if ($tray) { try { $tray.Visible = $false; $tray.Dispose() } catch {} }
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
