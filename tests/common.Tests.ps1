# Unit tests for plugins/opaiva-code-widget/scripts/common.ps1
BeforeAll {
    # widget.ps1 plus the layout file it loads
    function Get-WidgetSource {
        $d = Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts'
        return [IO.File]::ReadAllText((Join-Path $d 'widget.ps1')) + [IO.File]::ReadAllText((Join-Path $d 'widget.xaml'))
    }
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\common.ps1')
}

Describe 'Get-MutexName' {
    # Pinned: hook.ps1 finds a widget started by an older version through this exact name
    It 'matches the name computed by version 1.1.0' {
        Get-MutexName 'C:\Users\Test\.claude\plugins\data\claude-code-widget-claude-code-widget' |
            Should -BeExactly 'Local\ClaudeCodeWidget-e163331b644e'
    }
    It 'ignores letter case in the path' {
        Get-MutexName 'C:\USERS\TEST\.CLAUDE\PLUGINS\DATA\CLAUDE-CODE-WIDGET-CLAUDE-CODE-WIDGET' |
            Should -BeExactly 'Local\ClaudeCodeWidget-e163331b644e'
    }
}

Describe 'Write-JsonAtomic' {
    BeforeAll { $accented = 'a' + [char]0x00E7 + [char]0x00E3 + 'o' }

    It 'writes UTF-8 without BOM, keeps accents and leaves no .tmp' {
        $path = Join-Path $TestDrive 'x.json'
        Write-JsonAtomic $path ([ordered]@{ text = $accented })
        [IO.File]::ReadAllBytes($path)[0] | Should -Not -Be 0xEF
        ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json).text | Should -BeExactly $accented
        "$path.tmp" | Should -Not -Exist
    }
    It '-Replace overwrites an existing file and leaves no .tmp' {
        $path = Join-Path $TestDrive 'replace.json'
        Write-JsonAtomic $path @{ v = 1 }
        Write-JsonAtomic $path @{ v = 2 } -Replace
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).v | Should -Be 2
        "$path.tmp" | Should -Not -Exist
    }
    It '-Replace also creates a file that does not exist yet' {
        $path = Join-Path $TestDrive 'replace-new.json'
        Write-JsonAtomic $path @{ v = 1 } -Replace
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).v | Should -Be 1
        "$path.tmp" | Should -Not -Exist
    }
    It 'without -Replace still refuses to overwrite an existing file' {
        $path = Join-Path $TestDrive 'create-only.json'
        Write-JsonAtomic $path @{ v = 1 }
        { Write-JsonAtomic $path @{ v = 2 } } | Should -Throw
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).v | Should -Be 1
    }
    It 'keeps objects nested deeper than 5 levels' {
        $path = Join-Path $TestDrive 'deep.json'
        Write-JsonAtomic $path @{ a = @{ b = @{ c = @{ d = @{ e = @{ f = 'deep' } } } } } }
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).a.b.c.d.e.f | Should -Be 'deep'
    }
}

Describe 'Resolve-Lang' {
    It 'maps <requested> to <expected>' -ForEach @(
        @{ requested = 'pt'; expected = 'pt' }
        @{ requested = 'PT'; expected = 'pt' }
        @{ requested = 'en'; expected = 'en' }
        @{ requested = 'es'; expected = 'es' }
        @{ requested = 'ES'; expected = 'es' }
        @{ requested = 'fr'; expected = 'en' }
    ) {
        Resolve-Lang $requested | Should -BeExactly $expected
    }
    It 'falls back to the Windows display language when empty' {
        $ui = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
        $expected = if ($ui -in @('pt', 'es')) { $ui } else { 'en' }
        Resolve-Lang '' | Should -BeExactly $expected
    }
}

Describe 'Get-Strings' {
    It '<lang> defines the same keys as en' -ForEach @(@{ lang = 'pt' }, @{ lang = 'es' }) {
        $en = @((Get-Strings 'en').PSObject.Properties.Name | Sort-Object)
        $other = @((Get-Strings $lang).PSObject.Properties.Name | Sort-Object)
        $en.Count | Should -BeGreaterThan 0
        ($other -join ',') | Should -BeExactly ($en -join ',')
    }
    It 'the phone hint of the setup names the /start code and the bot in <lang>' -ForEach @(@{ lang = 'pt' }, @{ lang = 'en' }, @{ lang = 'es' }) {
        $t = (Get-Strings $lang).tgPhoneHint -f '3f9a1c07b2e4d856', 'testbot'
        $t | Should -BeLike '*/start 3f9a1c07b2e4d856*'
        $t | Should -BeLike '*@testbot*'
    }
    It 'reads strings.json as UTF-8' {
        (Get-Strings 'pt').deniedMessage | Should -Match ([string][char]0x00E1)
    }
}

Describe 'Get-NowMs' {
    It 'returns the current Unix time in milliseconds' {
        $expected = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        [math]::Abs((Get-NowMs) - $expected) | Should -BeLessThan 5000
    }
}

Describe 'Get-PendingRequests' {
    BeforeAll {
        $deadPid = 2147483640   # no process has this id
        function New-TestRequest([string]$Queue, [string]$Id, [int64]$Created, [int]$OwnerPid = $PID, [int]$Timeout = 300) {
            $req = [ordered]@{ id = $Id; pid = $OwnerPid; kind = 'permission'; created = $Created; timeout = $Timeout; cwd = 'C:\dev\app' }
            [IO.File]::WriteAllText((Join-Path $Queue "req-$Id.json"), ($req | ConvertTo-Json -Compress))
        }
        function Get-Ids($Items) { (@($Items) | ForEach-Object { $_.id }) -join ',' }
    }
    BeforeEach {
        $queue = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $queue | Out-Null
        $cache = @{}
        $now = Get-NowMs
    }

    It 'returns live requests oldest first' {
        New-TestRequest $queue 'newer' ($now - 1000)
        New-TestRequest $queue 'older' ($now - 2000)
        Get-Ids (Get-PendingRequests $queue $cache) | Should -BeExactly 'older,newer'
    }
    It 'deletes expired requests' {
        New-TestRequest $queue 'old' ($now - 400 * 1000) -Timeout 300
        @(Get-PendingRequests $queue $cache).Count | Should -Be 0
        Join-Path $queue 'req-old.json' | Should -Not -Exist
    }
    It 'deletes requests whose hook process is gone' {
        New-TestRequest $queue 'orphan' $now -OwnerPid $deadPid
        @(Get-PendingRequests $queue $cache).Count | Should -Be 0
        Join-Path $queue 'req-orphan.json' | Should -Not -Exist
    }
    It 'skips answered requests without deleting them' {
        New-TestRequest $queue 'answered' $now
        [IO.File]::WriteAllText((Join-Path $queue 'res-answered.json'), '{"decision":"allow"}')
        @(Get-PendingRequests $queue $cache).Count | Should -Be 0
        Join-Path $queue 'req-answered.json' | Should -Exist
    }
    It 'ignores files that are not valid JSON' {
        [IO.File]::WriteAllText((Join-Path $queue 'req-bad.json'), '{not json')
        New-TestRequest $queue 'good' $now
        Get-Ids (Get-PendingRequests $queue $cache) | Should -BeExactly 'good'
    }
    It 'forgets cached requests whose file is gone' {
        New-TestRequest $queue 'gone' $now
        [void](Get-PendingRequests $queue $cache)
        $cache.ContainsKey('req-gone.json') | Should -BeTrue
        Remove-Item -LiteralPath (Join-Path $queue 'req-gone.json')
        [void](Get-PendingRequests $queue $cache)
        $cache.ContainsKey('req-gone.json') | Should -BeFalse
    }
    It 'returns nothing when the queue folder does not exist' {
        @(Get-PendingRequests (Join-Path $TestDrive 'missing') $cache).Count | Should -Be 0
    }
}

Describe 'Get-DoneNotices' {
    BeforeAll {
        $maxAge = 12 * 3600 * 1000
        function New-TestNotice([string]$Queue, [string]$Session, [int64]$Created) {
            $path = Join-Path $Queue "done-$Session-$Created.json"
            $notice = [ordered]@{ session = $Session; created = $Created; cwd = 'C:\dev\app'; message = 'hi'; hwnd = 0; kind = '' }
            [IO.File]::WriteAllText($path, ($notice | ConvertTo-Json -Compress))
            return $path
        }
    }
    BeforeEach {
        $queue = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $queue | Out-Null
        $cache = @{}
        $now = Get-NowMs
    }

    It 'returns notices newest first, with key and file' {
        [void](New-TestNotice $queue 's1' ($now - 60000))
        $newest = New-TestNotice $queue 's2' ($now - 1000)
        $list = @(Get-DoneNotices $queue $cache $maxAge)
        (($list | ForEach-Object { $_.session }) -join ',') | Should -BeExactly 's2,s1'
        $list[0].key | Should -BeExactly (Split-Path -Leaf $newest)
        Split-Path -Leaf $list[0].file | Should -BeExactly (Split-Path -Leaf $newest)
        $list[0].file | Should -Exist
    }
    It 'deletes notices older than the maximum age' {
        $stale = New-TestNotice $queue 'stale' ($now - $maxAge - 60000)
        @(Get-DoneNotices $queue $cache $maxAge).Count | Should -Be 0
        $stale | Should -Not -Exist
    }
    It 'forgets cached notices whose file is gone' {
        $path = New-TestNotice $queue 's1' ($now - 1000)
        [void](Get-DoneNotices $queue $cache $maxAge)
        $cache.Count | Should -Be 1
        Remove-Item -LiteralPath $path
        @(Get-DoneNotices $queue $cache $maxAge).Count | Should -Be 0
        $cache.Count | Should -Be 0
    }
}

Describe 'Write-LogLine' {
    It 'appends a dated line, creating the folder' {
        $path = Join-Path $TestDrive 'logs\a.log'
        Write-LogLine $path 'first'
        Write-LogLine $path 'second'
        $lines = [IO.File]::ReadAllLines($path)
        $lines.Count | Should -Be 2
        $lines[1] | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d second$'
    }
    It 'moves the log to .old once it passes the limit, keeping a single .old' {
        $path = Join-Path $TestDrive 'r.log'
        [IO.File]::WriteAllText("$path.old", 'oldest')
        [IO.File]::WriteAllText($path, ('x' * 200))
        Write-LogLine $path 'new' 100
        [IO.File]::ReadAllText("$path.old") | Should -BeExactly ('x' * 200)
        $lines = @([IO.File]::ReadAllLines($path))
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match ' new$'
    }
    It 'keeps appending while under the limit' {
        $path = Join-Path $TestDrive 'u.log'
        [IO.File]::WriteAllText($path, "line`r`n")
        Write-LogLine $path 'more' 100
        "$path.old" | Should -Not -Exist
        @([IO.File]::ReadAllLines($path)).Count | Should -Be 2
    }
    It 'writes UTF-8 without BOM' {
        $path = Join-Path $TestDrive 'utf.log'
        $text = 'a' + [char]0x00E7 + [char]0x00E3 + 'o'
        Write-LogLine $path $text
        [IO.File]::ReadAllBytes($path)[0] | Should -Not -Be 0xEF
        [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | Should -Match ([regex]::Escape($text))
    }
    It 'never throws, even when the log cannot be written' {
        { Write-LogLine (Join-Path $TestDrive 'bad<>|.log') 'x' } | Should -Not -Throw
    }
}

Describe 'Test-TitleHasProject' {
    It 'matches "<title>"' -ForEach @(
        @{ title = 'x.ps1 - widget - Visual Studio Code'; project = 'widget' }
        @{ title = 'widget - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - widget (Workspace) - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - widget [WSL: Ubuntu] - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - WIDGET - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - my - app - Visual Studio Code'; project = 'my - app' }
        @{ title = 'x.ps1 - c++ (x86) - Visual Studio Code'; project = 'c++ (x86)' }
    ) {
        Test-TitleHasProject $title $project | Should -BeTrue
    }
    It 'does not match "<title>"' -ForEach @(
        @{ title = 'x.ps1 - claude-code-widget - Visual Studio Code'; project = 'widget' }
        @{ title = 'widget.ps1 - other - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - widgets - Visual Studio Code'; project = 'widget' }
    ) {
        Test-TitleHasProject $title $project | Should -BeFalse
    }
    It 'matches a title that starts with the unsaved-file dot' {
        $dot = [string][char]0x25CF
        Test-TitleHasProject "$dot widget - Visual Studio Code" 'widget' | Should -BeTrue
        Test-TitleHasProject "$dot x.ps1 - widget - Visual Studio Code" 'widget' | Should -BeTrue
    }
    It 'matches a translated workspace suffix' {
        $suffix = ' (Espa' + [char]0x00E7 + 'o de Trabalho)'
        Test-TitleHasProject "x.ps1 - widget$suffix - Visual Studio Code" 'widget' | Should -BeTrue
    }
    It 'is false for an empty title or project' {
        Test-TitleHasProject '' 'widget' | Should -BeFalse
        Test-TitleHasProject 'x.ps1 - widget - Visual Studio Code' '' | Should -BeFalse
    }
}

Describe 'Get-ScreenAreas' {
    It 'lists at least one screen, exactly one of them the main one' {
        $areas = @(Get-ScreenAreas)
        $areas.Count | Should -BeGreaterThan 0
        @($areas | Where-Object { $_.primary }).Count | Should -Be 1
        foreach ($a in $areas) {
            $a.right | Should -BeGreaterThan $a.left
            $a.bottom | Should -BeGreaterThan $a.top
        }
    }
    It 'uses the same units as WPF' {
        $main = @(Get-ScreenAreas | Where-Object { $_.primary })[0]
        $wa = [System.Windows.SystemParameters]::WorkArea
        [math]::Abs($main.right - $wa.Right) | Should -BeLessOrEqual 1
        [math]::Abs($main.bottom - $wa.Bottom) | Should -BeLessOrEqual 1
    }
}

Describe 'Get-ScreenKey' {
    BeforeAll { $main = @{ left = 0; top = 0; right = 2560; bottom = 1400; primary = $true } }
    It 'is the same for the same screens' {
        Get-ScreenKey @($main) | Should -BeExactly (Get-ScreenKey @($main.Clone()))
    }
    It 'changes when a screen changes' {
        $moved = $main.Clone()
        $moved.bottom = 1440
        Get-ScreenKey @($moved) | Should -Not -BeExactly (Get-ScreenKey @($main))
    }
}

Describe 'Resolve-Anchor' {
    BeforeAll {
        # Main screen 2560 x 1440 with a 40-pixel taskbar; a smaller screen on its left, bottom-aligned
        $main = @{ left = 0; top = 0; right = 2560; bottom = 1400; primary = $true }
        $side = @{ left = -1920; top = 360; right = 0; bottom = 1400; primary = $false }
    }
    It 'keeps a saved spot on the main screen' {
        $a = Resolve-Anchor @{ right = 2000; bottom = 900 } @($main, $side)
        $a.right | Should -Be 2000
        $a.bottom | Should -Be 900
        $a.saved | Should -BeTrue
    }
    It 'keeps a saved spot on another screen' {
        $a = Resolve-Anchor @{ right = -300; bottom = 1200 } @($main, $side)
        $a.right | Should -Be -300
        $a.saved | Should -BeTrue
    }
    It 'moves a spot between screens of different sizes to the main corner' {
        # Above the smaller screen: inside the box around both screens, but on neither of them
        $a = Resolve-Anchor @{ right = -300; bottom = 200 } @($main, $side)
        $a.right | Should -Be 2560
        $a.bottom | Should -Be 1400
        $a.saved | Should -BeFalse
    }
    It 'moves to the main corner when the saved screen is gone' {
        $a = Resolve-Anchor @{ right = -300; bottom = 1200 } @($main)
        $a.right | Should -Be 2560
        $a.saved | Should -BeFalse
    }
    It 'goes back to the saved spot when its screen is back' {
        $saved = @{ right = -300; bottom = 1200 }
        (Resolve-Anchor $saved @($main)).saved | Should -BeFalse
        $back = Resolve-Anchor $saved @($main, $side)
        $back.right | Should -Be -300
        $back.saved | Should -BeTrue
    }
    It 'uses the main corner without a saved spot' {
        $a = Resolve-Anchor $null @($side, $main)
        $a.right | Should -Be 2560
        $a.bottom | Should -Be 1400
    }
    It 'uses the main corner when the saved spot lacks fields' {
        $a = Resolve-Anchor ('{"x":5}' | ConvertFrom-Json) @($main)
        $a.right | Should -Be 2560
        $a.saved | Should -BeFalse
    }
    It 'reads a saved spot as loaded from state.json' {
        $a = Resolve-Anchor ('{"right":2371.09,"bottom":878.6}' | ConvertFrom-Json) @($main)
        $a.right | Should -Be 2371.09
        $a.saved | Should -BeTrue
    }
    It 'uses the first screen when none is marked main' {
        $a = Resolve-Anchor $null @(@{ left = 0; top = 0; right = 1920; bottom = 1040; primary = $false })
        $a.right | Should -Be 1920
    }
    It 'returns nothing without screens' {
        Resolve-Anchor @{ right = 2000; bottom = 900 } @() | Should -BeNullOrEmpty
    }
}

Describe 'Get-BusySessions' {
    BeforeEach {
        $busy = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $busy | Out-Null
        function Add-Busy([string]$Id, [int]$ProcessId, [int64]$AgeMs = 0, [string]$Cwd = 'C:\dev\app', [string]$Transcript = '') {
            Write-JsonAtomic (Join-Path $busy "$Id.json") ([ordered]@{ pid = $ProcessId; since = (Get-NowMs) - $AgeMs; cwd = $Cwd; transcript = $Transcript })
        }
        $maxAge = 12 * 3600 * 1000
        $quiet = 15 * 60 * 1000
    }
    It 'lists live sessions with id, cwd and transcript' {
        Add-Busy 's1' $PID 1000 'C:\dev\one' 'C:\t\one.jsonl'
        $list = @(Get-BusySessions $busy $maxAge $quiet)
        $list.Count | Should -Be 1
        $list[0].id | Should -BeExactly 's1'
        $list[0].cwd | Should -BeExactly 'C:\dev\one'
        $list[0].transcript | Should -BeExactly 'C:\t\one.jsonl'
        $list[0].since | Should -BeGreaterThan 0
    }
    It 'removes sessions whose process is gone' {
        Add-Busy 'dead' 2147483640
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 0
        Join-Path $busy 'dead.json' | Should -Not -Exist
    }
    It 'removes sessions older than the maximum age' {
        Add-Busy 'old' 0 ($maxAge + 60000)
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 0
    }
    It 'removes sessions whose transcript has been quiet too long' {
        $t = Join-Path $TestDrive 'quiet.jsonl'
        [IO.File]::WriteAllText($t, '{}')
        (Get-Item -LiteralPath $t).LastWriteTime = (Get-Date).AddMinutes(-20)
        Add-Busy 'quiet' $PID 0 'C:\dev\app' $t
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 0
    }
    It 'counts a session with an unknown process (pid 0)' {
        Add-Busy 'unknown' 0
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 1
    }
    It 'returns nothing when the folder does not exist' {
        @(Get-BusySessions (Join-Path $TestDrive 'nope') $maxAge $quiet).Count | Should -Be 0
    }
}

Describe 'Test-Dnd and Set-Dnd' {
    It 'is off by default, on after Set-Dnd and off again' {
        $dir = Join-Path $TestDrive 'dnd'
        Test-Dnd $dir | Should -BeFalse
        Set-Dnd $dir $true
        Test-Dnd $dir | Should -BeTrue
        Join-Path $dir 'dnd.flag' | Should -Exist
        Set-Dnd $dir $false
        Test-Dnd $dir | Should -BeFalse
    }
    It 'turning it off twice is harmless' {
        $dir = Join-Path $TestDrive 'dnd2'
        { Set-Dnd $dir $false; Set-Dnd $dir $false } | Should -Not -Throw
    }
}

Describe 'Format-SessionLine' {
    BeforeAll { $dot = [string][char]0x00B7 }
    It 'joins project and title' {
        Format-SessionLine 'C:\dev\my-app' 'Fix the login' | Should -BeExactly "my-app $dot Fix the login"
    }
    It 'shows only the project without a title' {
        Format-SessionLine 'C:\dev\my-app' '' | Should -BeExactly 'my-app'
        Format-SessionLine 'C:\dev\my-app' $null | Should -BeExactly 'my-app'
    }
    It 'shows only the title without a project' {
        Format-SessionLine '' 'Fix the login' | Should -BeExactly 'Fix the login'
    }
    It 'is empty without both' {
        Format-SessionLine '' '' | Should -BeExactly ''
    }
    It 'cuts a long title at 40 characters' {
        $title = 'x' * 60
        (Format-SessionLine 'C:\dev\a' $title) | Should -BeExactly ("a $dot " + ('x' * 39) + '...')
    }
    It 'does not split a surrogate pair when cutting' {
        $title = ('x' * 38) + [char]::ConvertFromUtf32(0x1F600) + 'yyyy'
        $line = Format-SessionLine '' $title
        $line | Should -BeExactly (('x' * 38) + '...')
    }
}

Describe 'Get-DiffLines' {
    BeforeAll {
        function New-Edit([string]$Old, [string]$New) { @{ kind = 'edit'; edits = @(@{ old = $Old; new = $New }) } }
    }
    It 'shows only the lines that changed, without the equal start and end' {
        $lines = @(Get-DiffLines (New-Edit "a`nb`nc" "a`nX`nc"))
        $lines.Count | Should -Be 2
        $lines[0].kind | Should -BeExactly 'del'
        $lines[0].text | Should -BeExactly 'b'
        $lines[1].kind | Should -BeExactly 'add'
        $lines[1].text | Should -BeExactly 'X'
    }
    It 'shows every line when nothing is in common' {
        $lines = @(Get-DiffLines (New-Edit "x`ny" "z"))
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'del:x,del:y,add:z'
    }
    It 'treats an empty old text as a pure addition' {
        $lines = @(Get-DiffLines (New-Edit '' "new1`nnew2"))
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'add:new1,add:new2'
    }
    It 'shows nothing when the edit changes nothing' {
        @(Get-DiffLines (New-Edit "same`nlines" "same`nlines")).Count | Should -Be 0
    }
    It 'handles Windows line endings' {
        $lines = @(Get-DiffLines (New-Edit "a`r`nb" "a`r`nc"))
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'del:b,add:c'
    }
    It 'shows a written file as added lines' {
        $lines = @(Get-DiffLines @{ kind = 'write'; content = "one`ntwo`nthree" })
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'add:one,add:two,add:three'
    }
    It 'keeps 14 lines and says how many were left out' {
        $content = (1..20 | ForEach-Object { "line $_" }) -join "`n"
        $lines = @(Get-DiffLines @{ kind = 'write'; content = $content })
        $lines.Count | Should -Be 15
        @($lines | Where-Object { $_.kind -eq 'add' }).Count | Should -Be 14
        $lines[14].kind | Should -BeExactly 'more'
        $lines[14].text | Should -BeExactly '6'
    }
    It 'follows several edits in order' {
        $change = @{ kind = 'edit'; edits = @(@{ old = 'a'; new = 'b' }, @{ old = 'c'; new = 'd' }) }
        $lines = @(Get-DiffLines $change)
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'del:a,add:b,del:c,add:d'
    }
    It 'returns nothing without a change' {
        @(Get-DiffLines $null).Count | Should -Be 0
        @(Get-DiffLines @{ kind = 'edit'; edits = @() }).Count | Should -Be 0
        @(Get-DiffLines @{ kind = 'write' }).Count | Should -Be 0
    }
}

Describe 'ConvertTo-Hotkey' {
    It 'parses <text>' -ForEach @(
        @{ text = 'Ctrl+Alt+Y'; mod = 0x4003; vk = 0x59 }
        @{ text = 'ctrl + alt + y'; mod = 0x4003; vk = 0x59 }
        @{ text = 'Shift+Win+F13'; mod = 0x400C; vk = 0x7C }
        @{ text = 'Ctrl+5'; mod = 0x4002; vk = 0x35 }
        @{ text = 'Alt+F1'; mod = 0x4001; vk = 0x70 }
    ) {
        $hk = ConvertTo-Hotkey $text
        $hk.mod | Should -Be $mod
        $hk.vk | Should -Be $vk
    }
    It 'rejects <text>' -ForEach @(
        @{ text = '' }
        @{ text = 'Y' }
        @{ text = 'Ctrl+Alt' }
        @{ text = 'Ctrl+Alt+Yes' }
        @{ text = 'Ctrl+Y+N' }
        @{ text = 'Ctrl+F25' }
        @{ text = 'Hyper+Y' }
    ) {
        ConvertTo-Hotkey $text | Should -BeNullOrEmpty
    }
}

Describe 'Format-RuleText' {
    It 'writes a rule object as Tool(content) or just Tool' {
        Format-RuleText ([pscustomobject]@{ toolName = 'Bash'; ruleContent = 'npm test *' }) | Should -BeExactly 'Bash(npm test *)'
        Format-RuleText ([pscustomobject]@{ toolName = 'Read' }) | Should -BeExactly 'Read'
        Format-RuleText ([pscustomobject]@{ toolName = 'Read'; ruleContent = '' }) | Should -BeExactly 'Read'
    }
    It 'keeps a rule that is already a string' {
        Format-RuleText 'Bash(git *)' | Should -BeExactly 'Bash(git *)'
    }
    It 'never throws on odd input' {
        { Format-RuleText $null; Format-RuleText 42; Format-RuleText @(1, 2); Format-RuleText ([pscustomobject]@{ other = 1 }) } | Should -Not -Throw
        Format-RuleText $null | Should -BeExactly ''
    }
}

Describe 'Read-Prefs / Save-Prefs' {
    BeforeEach {
        $dir = Join-Path $TestDrive ('p' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $file = Join-Path $dir 'prefs.json'
    }
    It 'gives the defaults when the file is missing' {
        $p = Read-Prefs $dir
        $p.theme | Should -Be 'dark'
        $p.opacity | Should -Be 1.0
        $p.volume | Should -Be 100
        $p.scale | Should -Be 1.0
        $p.minimal | Should -BeFalse
    }
    It 'defaults notifyAfter to 5 and telegram to false' {
        $p = Read-Prefs $dir
        $p.notifyAfter | Should -Be 5
        $p.telegram | Should -BeFalse
    }
    It 'keeps notifyAfter <n>' -ForEach @(@{ n = 1 }, @{ n = 3 }, @{ n = 5 }) {
        [IO.File]::WriteAllText($file, ('{"notifyAfter":' + $n + '}'))
        (Read-Prefs $dir).notifyAfter | Should -Be $n
    }
    It 'falls back to 5 for notifyAfter <v>' -ForEach @(@{ v = 0 }, @{ v = 2 }, @{ v = 10 }, @{ v = 'x' }, @{ v = $true }) {
        [IO.File]::WriteAllText($file, (@{ notifyAfter = $v } | ConvertTo-Json -Compress))
        (Read-Prefs $dir).notifyAfter | Should -Be 5
    }
    It 'defaults closeAfter to 5' {
        (Read-Prefs $dir).closeAfter | Should -Be 5
    }
    It 'keeps closeAfter <n>' -ForEach @(@{ n = 0 }, @{ n = 1 }, @{ n = 3 }, @{ n = 5 }, @{ n = 15 }, @{ n = 30 }) {
        [IO.File]::WriteAllText($file, ('{"closeAfter":' + $n + '}'))
        $p = Read-Prefs $dir
        $p.closeAfter | Should -Be $n
        $p.closeAfter | Should -BeOfType [int]
    }
    It 'falls back to 5 for closeAfter <v>' -ForEach @(@{ v = 2 }, @{ v = 60 }, @{ v = -1 }, @{ v = 0.5 }, @{ v = 'x' }, @{ v = $true }, @{ v = $null }) {
        [IO.File]::WriteAllText($file, (@{ closeAfter = $v } | ConvertTo-Json -Compress))
        (Read-Prefs $dir).closeAfter | Should -Be 5
    }
    It 'round-trips closeAfter <n>' -ForEach @(@{ n = 0 }, @{ n = 30 }) {
        $want = Get-DefaultPrefs
        $want.closeAfter = $n
        Save-Prefs $dir $want | Should -BeTrue
        (Read-Prefs $dir).closeAfter | Should -Be $n
    }
    It 'a prefs set without closeAfter is saved with the default, not as Never' {
        Save-Prefs $dir @{ theme = 'dark'; opacity = 1.0; volume = 100; scale = 1.0; minimal = $false } | Should -BeTrue
        (Read-Prefs $dir).closeAfter | Should -Be 5
    }
    It 'reads telegram true' {
        [IO.File]::WriteAllText($file, '{"telegram":true}')
        (Read-Prefs $dir).telegram | Should -BeTrue
    }
    It 'ignores a non-bool telegram' {
        [IO.File]::WriteAllText($file, '{"telegram":"yes"}')
        (Read-Prefs $dir).telegram | Should -BeFalse
    }
    It 'gives the defaults when the file is not JSON' {
        [IO.File]::WriteAllText($file, '{{ not json')
        (Read-Prefs $dir).theme | Should -Be 'dark'
    }
    It 'reads valid values' {
        [IO.File]::WriteAllText($file, '{"theme":"light","opacity":0.8,"volume":25,"scale":1.5,"minimal":true}')
        $p = Read-Prefs $dir
        $p.theme | Should -Be 'light'
        $p.opacity | Should -Be 0.8
        $p.volume | Should -Be 25
        $p.scale | Should -Be 1.5
        $p.minimal | Should -BeTrue
    }
    It 'falls back field by field when a value is invalid' {
        [IO.File]::WriteAllText($file, '{"theme":"pink","opacity":"x","volume":true,"scale":null,"minimal":"yes"}')
        $p = Read-Prefs $dir
        $p.theme | Should -Be 'dark'
        $p.opacity | Should -Be 1.0
        $p.volume | Should -Be 100
        $p.scale | Should -Be 1.0
        $p.minimal | Should -BeFalse
    }
    It 'keeps the valid fields next to an invalid one' {
        [IO.File]::WriteAllText($file, '{"theme":"auto","opacity":"x","volume":50}')
        $p = Read-Prefs $dir
        $p.theme | Should -Be 'auto'
        $p.volume | Should -Be 50
    }
    It 'limits numbers to their range and snaps the scale to the nearest allowed one' {
        [IO.File]::WriteAllText($file, '{"opacity":0.1,"volume":1000000000,"scale":1.4}')
        $p = Read-Prefs $dir
        $p.opacity | Should -Be 0.5
        $p.volume | Should -Be 100
        $p.scale | Should -Be 1.5
        [IO.File]::WriteAllText($file, '{"opacity":7,"volume":-5,"scale":0.2}')
        $p = Read-Prefs $dir
        $p.opacity | Should -Be 1.0
        $p.volume | Should -Be 0
        $p.scale | Should -Be 1.0
    }
    It 'ignores NaN and infinity' {
        [IO.File]::WriteAllText($file, '{"opacity":"NaN","volume":"Infinity","scale":"-Infinity"}')
        $p = Read-Prefs $dir
        $p.opacity | Should -Be 1.0
        $p.volume | Should -Be 100
        $p.scale | Should -Be 1.0
    }
    It 'writes what it reads back (round trip)' {
        $want = @{ theme = 'auto'; opacity = 0.7; volume = 0; scale = 1.25; minimal = $true }
        Save-Prefs $dir $want | Should -BeTrue
        $p = Read-Prefs $dir
        foreach ($k in $want.Keys) { $p[$k] | Should -Be $want[$k] }
    }
    It 'round-trips notifyAfter and telegram' {
        $want = @{ theme = 'dark'; opacity = 1.0; volume = 100; scale = 1.0; minimal = $false; notifyAfter = 3; telegram = $true }
        Save-Prefs $dir $want | Should -BeTrue
        $p = Read-Prefs $dir
        $p.notifyAfter | Should -Be 3
        $p.telegram | Should -BeTrue
    }
    It 'replaces an existing file' {
        Save-Prefs $dir @{ theme = 'light'; opacity = 1.0; volume = 100; scale = 1.0; minimal = $false } | Out-Null
        Save-Prefs $dir @{ theme = 'dark'; opacity = 1.0; volume = 100; scale = 1.0; minimal = $false } | Should -BeTrue
        (Read-Prefs $dir).theme | Should -Be 'dark'
    }
    It 'returns false instead of throwing when the folder does not exist' {
        Save-Prefs (Join-Path $TestDrive 'nope\nope') (Get-DefaultPrefs) | Should -BeFalse
    }
    It 'a hook reading prefs.json while the widget replaces it never gets the defaults' {
        $want = Get-DefaultPrefs
        $want.telegram = $true
        $want.notifyAfter = 1
        Save-Prefs $dir $want | Should -BeTrue
        # Another process (the hook) reads over and over while the widget saves the same prefs again and again
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
                param($Common, $Dir)
                . $Common
                $wrong = 0
                $until = [DateTime]::UtcNow.AddSeconds(3)
                while ([DateTime]::UtcNow -lt $until) { $p = Read-Prefs $Dir; if (-not $p.telegram -or $p.notifyAfter -ne 1) { $wrong++ } }
                $wrong
            }).AddArgument((Join-Path $PSScriptRoot '..\plugins\opaiva-code-widget\scripts\common.ps1')).AddArgument($dir)
        $h = $ps.BeginInvoke()
        try {
            $until = (Get-Date).AddSeconds(2.5)
            while ((Get-Date) -lt $until) { [void](Save-Prefs $dir $want); Start-Sleep -Milliseconds 5 }
            $wrong = @($ps.EndInvoke($h))[-1]
        } finally { $ps.Dispose() }
        $wrong | Should -Be 0
        Get-Content -LiteralPath $file -Raw | Should -BeExactly '{"theme":"dark","opacity":1,"volume":100,"scale":1,"minimal":false,"notifyAfter":1,"telegram":true,"closeAfter":5}'
    }
}

Describe 'close and alert times' {
    It 'Get-CloseAfterMs is closeAfter <m> min in ms (<ms>)' -ForEach @(
        @{ m = 1; ms = 60000 }, @{ m = 5; ms = 300000 }, @{ m = 30; ms = 1800000 }, @{ m = 0; ms = 3600000 }) {
        $got = Get-CloseAfterMs @{ closeAfter = $m }
        $got | Should -Be $ms
        $got | Should -BeOfType [int64]
    }
    It 'Get-CloseAfterMs gives -NeverMs for Never' {
        Get-CloseAfterMs @{ closeAfter = 0 } 43200000 | Should -Be 43200000
        Get-CloseAfterMs @{ closeAfter = 3 } 43200000 | Should -Be 180000
    }
    It 'a finished notice lasts closeAfter, 12 h with Never' {
        Get-NoticeMaxAgeMs @{ closeAfter = 5 } | Should -Be 300000
        Get-NoticeMaxAgeMs @{ closeAfter = 0 } | Should -Be (12 * 3600 * 1000)
    }
    It 'a notice alerts at min(notifyAfter, its max age - 15 s): close <close> / alert <alert> -> <ms>' -ForEach @(
        @{ close = 5; alert = 5; ms = 285000 }
        @{ close = 5; alert = 1; ms = 60000 }
        @{ close = 1; alert = 3; ms = 45000 }
        @{ close = 15; alert = 5; ms = 300000 }
        @{ close = 0; alert = 5; ms = 300000 }) {
        Get-NoticeAlertMs @{ closeAfter = $close; notifyAfter = $alert } | Should -Be $ms
    }
}

Describe 'Format-Countdown' {
    It 'is the time left as m:ss' {
        $r = [pscustomobject]@{ created = 1000000; timeout = 300 }
        Format-Countdown $r (1000000 + 61000) 'closes in {0}:{1:00}' | Should -BeExactly 'closes in 3:59'
    }
    It 'stops at 0:00' {
        $r = [pscustomobject]@{ created = 1000000; timeout = 60 }
        Format-Countdown $r (1000000 + 999000) '{0}:{1:00}' | Should -BeExactly '0:00'
    }
    It 'is empty for a request that never closes by itself' {
        $r = [pscustomobject]@{ created = 1000000; timeout = 3600; noCountdown = $true }
        Format-Countdown $r 1000000 '{0}:{1:00}' | Should -BeExactly ''
    }
}

Describe 'Resolve-Theme' {
    It 'resolves <theme> with Windows light=<light> to <want>' -ForEach @(
        @{ theme = 'dark'; light = $false; want = 'dark' }
        @{ theme = 'dark'; light = $true; want = 'dark' }
        @{ theme = 'light'; light = $false; want = 'light' }
        @{ theme = 'auto'; light = $true; want = 'light' }
        @{ theme = 'auto'; light = $false; want = 'dark' }
        @{ theme = 'weird'; light = $true; want = 'dark' }
    ) {
        Resolve-Theme $theme $light | Should -Be $want
    }
}

Describe 'Get-ColorMap' {
    BeforeAll {
        $widgetText = (Get-WidgetSource)
        $native = @('#FFFFFF', '#D97757', '#2F6F4E')   # same in both themes
    }
    It 'is empty for the dark theme' {
        (Get-ColorMap 'dark').Count | Should -Be 0
    }
    It 'has unique values, none of them a key or a native color' {
        $m = Get-ColorMap 'light'
        $m.Count | Should -BeGreaterThan 20
        @($m.Values | Select-Object -Unique).Count | Should -Be $m.Count
        foreach ($v in $m.Values) {
            $m.ContainsKey($v) | Should -BeFalse -Because "$v is also a key"
            $native -contains $v | Should -BeFalse -Because "$v is a native color"
        }
    }
    It 'covers every color written in widget.ps1' {
        $m = Get-ColorMap 'light'
        $hex = [regex]::Matches($widgetText, '#[0-9A-Fa-f]{6}(?![0-9A-Fa-f])') | ForEach-Object { $_.Value.ToUpper() } | Sort-Object -Unique
        $missing = @($hex | Where-Object { -not $m.ContainsKey($_) -and ($native -notcontains $_) })
        $missing | Should -BeNullOrEmpty
    }
    It 'keeps text readable: dark text on the light card, light text on the dark card' {
        function Get-Lum([string]$h) { (0.299 * [Convert]::ToInt32($h.Substring(1, 2), 16) + 0.587 * [Convert]::ToInt32($h.Substring(3, 2), 16) + 0.114 * [Convert]::ToInt32($h.Substring(5, 2), 16)) }
        $m = Get-ColorMap 'light'
        (Get-Lum $m['#1E1E22']) | Should -BeGreaterThan 200   # card
        (Get-Lum $m['#F4F4F6']) | Should -BeLessThan 60       # title
        (Get-Lum $m['#E8E8EC']) | Should -BeLessThan 60       # main text
    }
}

Describe 'Convert-ThemeColor' {
    It 'maps a known color, ignoring letter case' {
        $m = @{ '#1E1E22' = '#FAFAFB' }
        Convert-ThemeColor '#1e1e22' $m | Should -Be '#FAFAFB'
    }
    It 'keeps a color that has no entry' {
        Convert-ThemeColor '#D97757' @{ '#1E1E22' = '#FAFAFB' } | Should -Be '#D97757'
    }
    It 'keeps everything with an empty map' {
        Convert-ThemeColor '#1E1E22' @{} | Should -Be '#1E1E22'
    }
    It 'goes back to the original color through the reverse map' {
        $m = Get-ColorMap 'light'
        $back = @{}
        foreach ($k in $m.Keys) { $back[$m[$k]] = $k }
        foreach ($k in $m.Keys) { Convert-ThemeColor (Convert-ThemeColor $k $m) $back | Should -Be $k }
    }
}

Describe 'Get-FitScale' {
    It 'keeps the chosen scale when the card fits the work area' {
        Get-FitScale 1.5 500 1000 | Should -Be 1.5
    }
    It 'shrinks the scale so that the card still fits the work area' {
        # 800 DIP tall at 100% on a 1000 DIP work area: 1.5 would need 1200
        Get-FitScale 1.5 800 1000 | Should -Be 1.25
    }
    It 'never goes above the chosen scale' {
        Get-FitScale 1.0 100 1000 | Should -Be 1.0
    }
    It 'shrinks below 100% when even the normal size does not fit, but not below 50%' {
        Get-FitScale 1.0 1250 1000 | Should -Be 0.8
        Get-FitScale 1.0 5000 1000 | Should -Be 0.5
    }
    It 'rounds down so that the result never overflows' {
        Get-FitScale 1.5 900 1000 | Should -Be 1.11
    }
    It 'ignores a zero or negative height (not measured yet)' {
        Get-FitScale 1.5 0 1000 | Should -Be 1.5
        Get-FitScale 1.25 -5 1000 | Should -Be 1.25
    }
}


Describe 'Get-ScriptVersion / Test-WidgetOlder' {
    It 'reads the version from the plugin cache folder name' {
        Get-ScriptVersion 'C:\x\opaiva-code-widget\2.3.0\scripts\widget.ps1' | Should -Be ([version]'2.3.0')
    }
    It 'falls back to plugin.json next to the scripts folder' {
        $root = Join-Path $TestDrive 'plug'
        New-Item -ItemType Directory -Path (Join-Path $root 'scripts'), (Join-Path $root '.claude-plugin') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.claude-plugin\plugin.json'), '{"version":"3.1.4"}')
        Get-ScriptVersion (Join-Path $root 'scripts\widget.ps1') | Should -Be ([version]'3.1.4')
    }
    It 'gives nothing when it cannot tell' {
        Get-ScriptVersion (Join-Path $TestDrive 'nowhere\scripts\widget.ps1') | Should -BeNullOrEmpty
    }
    It 'replaces a running widget only when it is older than this one' -ForEach @(
        @{ running = 'C:\a\2.3.0\scripts\widget.ps1'; own = 'C:\a\2.4.0\scripts\widget.ps1'; want = $true }
        @{ running = 'C:\a\2.4.0\scripts\widget.ps1'; own = 'C:\a\2.3.0\scripts\widget.ps1'; want = $false }
        @{ running = 'C:\a\2.10.0\scripts\widget.ps1'; own = 'C:\a\2.9.0\scripts\widget.ps1'; want = $false }
        @{ running = 'C:\a\2.4.0\scripts\widget.ps1'; own = 'C:\b\2.4.0\scripts\widget.ps1'; want = $false }
    ) {
        Test-WidgetOlder $running $own | Should -Be $want
    }
    It 'keeps the old behavior (replace) when a version is unknown' {
        Test-WidgetOlder 'C:\nowhere\scripts\widget.ps1' 'C:\a\2.4.0\scripts\widget.ps1' | Should -BeTrue
    }
}


# The Minecraft theme was removed in 2.6.0: a prefs.json saved with it falls back to the default
Describe 'Read-Prefs after the Minecraft theme' {
    It 'falls back to the default theme for a saved "minecraft"' {
        $dir = Join-Path $TestDrive ('mc' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'prefs.json'), '{"theme":"minecraft"}')
        (Read-Prefs $dir).theme | Should -Be 'dark'
    }
}
Describe 'diff details' {
    It 'a text ending with a newline has no extra empty line' {
        @(Split-TextLines "a`nb`n").Count | Should -Be 2
        @(Split-TextLines "a`r`n").Count | Should -Be 1
    }
    It 'says how many edits the hook left out' {
        $lines = @(Get-DiffLines @{ kind = 'edit'; edits = @(@{ old = 'x'; new = 'y' }); droppedEdits = 3 })
        $lines[-1].kind | Should -Be 'edits'
        $lines[-1].text | Should -Be '3'
    }
}

Describe 'Get-ClaudeSettingsEnv' {
    It 'returns an empty table for a missing file' {
        $e = Get-ClaudeSettingsEnv (Join-Path $TestDrive 'nope.json')
        $e | Should -BeOfType [hashtable]
        $e.Count | Should -Be 0
    }
    It 'returns the env values as strings' {
        $p = Join-Path $TestDrive 'ok.json'
        [IO.File]::WriteAllText($p, '{"env":{"A":"1","B":2}}')
        $e = Get-ClaudeSettingsEnv $p
        $e.A | Should -BeExactly '1'
        $e.B | Should -BeExactly '2'
        $e.B | Should -BeOfType [string]
    }
    It 'reads a file with a UTF-8 BOM' {
        $p = Join-Path $TestDrive 'bom.json'
        [IO.File]::WriteAllText($p, '{"env":{"A":"1"}}', (New-Object System.Text.UTF8Encoding $true))
        (Get-ClaudeSettingsEnv $p).A | Should -BeExactly '1'
    }
    It 'returns an empty table for invalid JSON' {
        $p = Join-Path $TestDrive 'bad.json'
        [IO.File]::WriteAllText($p, '{"env": {')
        (Get-ClaudeSettingsEnv $p).Count | Should -Be 0
    }
    It 'returns an empty table when there is no env key' {
        $p = Join-Path $TestDrive 'noenv.json'
        [IO.File]::WriteAllText($p, '{"model":"x"}')
        (Get-ClaudeSettingsEnv $p).Count | Should -Be 0
    }
    It 'returns an empty table when env is not an object' {
        $p = Join-Path $TestDrive 'strenv.json'
        [IO.File]::WriteAllText($p, '{"env":"x"}')
        (Get-ClaudeSettingsEnv $p).Count | Should -Be 0
    }
}

Describe 'Telegram connection storage' {
    BeforeAll { $script:FakeToken = '123456:TEST-not-a-real-token' }
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
    }

    It 'round-trips token, chat, bot and name' {
        Save-TelegramConfig $script:Dir $script:FakeToken '987654321' 'my_test_bot' 'Dani' | Should -BeTrue
        $c = Read-TelegramConfig $script:Dir
        $c.token | Should -BeExactly $script:FakeToken
        $c.chat | Should -BeExactly '987654321'
        $c.bot | Should -BeExactly 'my_test_bot'
        $c.name | Should -BeExactly 'Dani'
    }
    It 'never stores the token in clear' {
        Save-TelegramConfig $script:Dir $script:FakeToken '1' 'b' 'n' | Out-Null
        $text = [IO.File]::ReadAllText((Join-Path $script:Dir 'telegram.json'))
        $text | Should -Not -Match ([regex]::Escape($script:FakeToken))
        $text | Should -Not -Match 'not-a-real-token'
    }
    It 'overwrites an existing connection' {
        Save-TelegramConfig $script:Dir $script:FakeToken '1' 'first_bot' 'A' | Should -BeTrue
        Save-TelegramConfig $script:Dir '654321:TEST-other-fake' '2' 'second_bot' 'B' | Should -BeTrue
        $c = Read-TelegramConfig $script:Dir
        $c.token | Should -BeExactly '654321:TEST-other-fake'
        $c.bot | Should -BeExactly 'second_bot'
        Test-Path -LiteralPath (Join-Path $script:Dir 'telegram.json.tmp') | Should -BeFalse
    }
    It 'keeps the previous connection when saving fails' {
        Save-TelegramConfig $script:Dir $script:FakeToken '1' 'first_bot' 'A' | Should -BeTrue
        # A lock on the .tmp makes the new write fail, as a full disk or an antivirus lock would
        $lock = [IO.File]::Open((Join-Path $script:Dir 'telegram.json.tmp'), 'Create', 'ReadWrite', 'None')
        try {
            Save-TelegramConfig $script:Dir '654321:TEST-other-fake' '2' 'second_bot' 'B' | Should -BeFalse
        } finally { $lock.Dispose() }
        $c = Read-TelegramConfig $script:Dir
        $c.token | Should -BeExactly $script:FakeToken
        $c.bot | Should -BeExactly 'first_bot'
    }
    It 'returns $null for a missing file' {
        Read-TelegramConfig $script:Dir | Should -BeNullOrEmpty
    }
    It 'returns $null when the token cannot be decrypted (another user or garbage)' {
        [IO.File]::WriteAllText((Join-Path $script:Dir 'telegram.json'), '{"token":"not-a-dpapi-blob","chat":"1","bot":"b","name":"n"}')
        Read-TelegramConfig $script:Dir | Should -BeNullOrEmpty
    }
    It 'returns $null for a broken file' {
        [IO.File]::WriteAllText((Join-Path $script:Dir 'telegram.json'), '{"token": ')
        Read-TelegramConfig $script:Dir | Should -BeNullOrEmpty
    }
    It 'Read-TelegramInfo gives bot and name without the token' {
        Save-TelegramConfig $script:Dir $script:FakeToken '987654321' 'my_test_bot' 'Dani' | Should -BeTrue
        $i = Read-TelegramInfo $script:Dir
        $i.bot | Should -BeExactly 'my_test_bot'
        $i.name | Should -BeExactly 'Dani'
        $i.ContainsKey('token') | Should -BeFalse
    }
    It 'Read-TelegramInfo does not decrypt (a token from another user still gives the bot)' {
        [IO.File]::WriteAllText((Join-Path $script:Dir 'telegram.json'), '{"token":"not-a-dpapi-blob","chat":"1","bot":"b","name":"n"}')
        (Read-TelegramInfo $script:Dir).bot | Should -BeExactly 'b'
    }
    It 'Read-TelegramInfo is $null for a missing file, a broken one or one without a token' {
        Read-TelegramInfo $script:Dir | Should -BeNullOrEmpty
        [IO.File]::WriteAllText((Join-Path $script:Dir 'telegram.json'), '{"token": ')
        Read-TelegramInfo $script:Dir | Should -BeNullOrEmpty
        [IO.File]::WriteAllText((Join-Path $script:Dir 'telegram.json'), '{"bot":"b","name":"n"}')
        Read-TelegramInfo $script:Dir | Should -BeNullOrEmpty
    }
    It 'removes the connection and ignores a missing one' {
        Save-TelegramConfig $script:Dir $script:FakeToken '1' 'b' 'n' | Out-Null
        Remove-TelegramConfig $script:Dir
        Test-Path -LiteralPath (Join-Path $script:Dir 'telegram.json') | Should -BeFalse
        { Remove-TelegramConfig $script:Dir } | Should -Not -Throw
    }
    It 'Test-TelegramReady needs the file and the preference' {
        Test-TelegramReady $script:Dir @{ telegram = $true } | Should -BeFalse
        Save-TelegramConfig $script:Dir $script:FakeToken '1' 'b' 'n' | Out-Null
        Test-TelegramReady $script:Dir @{ telegram = $false } | Should -BeFalse
        Test-TelegramReady $script:Dir @{ telegram = $true } | Should -BeTrue
    }
    It 'Test-TelegramReady does not decrypt (a garbage token still counts as ready)' {
        [IO.File]::WriteAllText((Join-Path $script:Dir 'telegram.json'), '{"token":"garbage"}')
        Test-TelegramReady $script:Dir @{ telegram = $true } | Should -BeTrue
    }
}

Describe 'Telegram alert files' {
    BeforeEach {
        $script:Q = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'Add-AlertOutbox writes the tg file with the entry and returns the id' {
        $id = Add-AlertOutbox $script:Q @{ kind = 'permission'; session = 'abc-1'; cwd = 'C:\p\app'; title = 'T'; detail = 'Bash: ls'; reason = 'timeout' }
        $id | Should -Match '^[0-9a-f]{32}$'
        $j = [IO.File]::ReadAllText((Join-Path $script:Q "tg-$id.json")) | ConvertFrom-Json
        $j.id | Should -BeExactly $id
        $j.kind | Should -BeExactly 'permission'
        $j.session | Should -BeExactly 'abc-1'
        $j.cwd | Should -BeExactly 'C:\p\app'
        $j.detail | Should -BeExactly 'Bash: ls'
        $j.reason | Should -BeExactly 'timeout'
        [math]::Abs([int64]$j.created - (Get-NowMs)) | Should -BeLessThan 5000
        (Join-Path $script:Q "tg-$id.json.tmp") | Should -Not -Exist
    }
    It 'Add-AlertOutbox keeps a created time it was given and gives each entry its own file' {
        $a = Add-AlertOutbox $script:Q @{ kind = 'question'; session = 's'; created = 1234 }
        $b = Add-AlertOutbox $script:Q @{ kind = 'question'; session = 's' }
        $a | Should -Not -Be $b
        ([IO.File]::ReadAllText((Join-Path $script:Q "tg-$a.json")) | ConvertFrom-Json).created | Should -Be 1234
        @(Get-ChildItem -LiteralPath $script:Q -Filter 'tg-*.json').Count | Should -Be 2
    }
    It 'Set-WaitMarker writes the wait file and the newest one wins' {
        Set-WaitMarker $script:Q @{ session = 's1'; kind = 'plan'; cwd = 'C:\p'; title = 'T'; detail = 'first'; created = 100 }
        Set-WaitMarker $script:Q @{ session = 's1'; kind = 'permission'; cwd = 'C:\p'; title = 'T'; detail = 'second'; created = 200 }
        $files = @(Get-ChildItem -LiteralPath $script:Q -Filter 'wait-*.json')
        $files.Count | Should -Be 1
        $files[0].Name | Should -BeExactly 'wait-s1.json'
        $j = [IO.File]::ReadAllText($files[0].FullName) | ConvertFrom-Json
        $j.detail | Should -BeExactly 'second'
        $j.kind | Should -BeExactly 'permission'
        $j.created | Should -Be 200
    }
    It 'Set-WaitMarker sanitizes the session for the file name and stores the clean id' {
        Set-WaitMarker $script:Q @{ session = '..\x/y:z-1'; kind = 'plan'; created = 1 }
        $f = @(Get-ChildItem -LiteralPath $script:Q -Filter 'wait-*.json')
        $f.Count | Should -Be 1
        $f[0].Name | Should -BeExactly 'wait-xyz-1.json'
        ([IO.File]::ReadAllText($f[0].FullName) | ConvertFrom-Json).session | Should -BeExactly 'xyz-1'
    }
    It 'Set-SessionSeen writes the stamp' {
        Set-SessionSeen $script:Q 's2'
        $j = [IO.File]::ReadAllText((Join-Path $script:Q 'seen-s2.json')) | ConvertFrom-Json
        $j.session | Should -BeExactly 's2'
        [math]::Abs([int64]$j.at - (Get-NowMs)) | Should -BeLessThan 5000
    }
    It 'Set-SessionSeen overwrites an earlier stamp' {
        Set-SessionSeen $script:Q 's2'
        { Set-SessionSeen $script:Q 's2' } | Should -Not -Throw
        @(Get-ChildItem -LiteralPath $script:Q -Filter 'seen-*.json').Count | Should -Be 1
    }
    It 'Set-SessionSeen removes the wait marker of that session only' {
        Set-WaitMarker $script:Q @{ session = 's3'; kind = 'plan'; created = 1 }
        Set-WaitMarker $script:Q @{ session = 's4'; kind = 'plan'; created = 1 }
        Set-SessionSeen $script:Q 's3'
        (Join-Path $script:Q 'wait-s3.json') | Should -Not -Exist
        (Join-Path $script:Q 'wait-s4.json') | Should -Exist
    }
    It 'Remove-AlertOutbox drops the outbox entries created before the given time, and only those' {
        $old = Add-AlertOutbox $script:Q @{ kind = 'permission'; session = 's'; created = 1000 }
        $edge = Add-AlertOutbox $script:Q @{ kind = 'permission'; session = 's'; created = 2000 }
        $new = Add-AlertOutbox $script:Q @{ kind = 'permission'; session = 's'; created = 3000 }
        Set-WaitMarker $script:Q @{ session = 's1'; kind = 'plan'; created = 1 }
        Remove-AlertOutbox $script:Q 2000
        (Join-Path $script:Q "tg-$old.json") | Should -Not -Exist
        (Join-Path $script:Q "tg-$edge.json") | Should -Exist
        (Join-Path $script:Q "tg-$new.json") | Should -Exist
        (Join-Path $script:Q 'wait-s1.json') | Should -Exist
    }
    It 'Remove-AlertOutbox works without a queue folder' {
        { Remove-AlertOutbox $script:Q (Get-NowMs) } | Should -Not -Throw
    }
    It 'Set-SessionSeen works when there is no marker and no queue folder yet' {
        { Set-SessionSeen $script:Q 'nobody' } | Should -Not -Throw
        (Join-Path $script:Q 'seen-nobody.json') | Should -Exist
    }
}

Describe 'Get-DueAlerts' {
    BeforeAll {
        $script:Now = [int64]1800000000000
        $script:After = [int64]180000   # 3 minutes
        function New-Notice($Created, $Desktop = $null) {
            $n = [pscustomobject]@{ session = 'n1'; created = [int64]$Created; cwd = 'C:\p\app'; message = 'All done'; question = $false
                title = 'T'; hwnd = 0; kind = 'done'; key = "done-n1-$Created.json"; file = "C:\q\done-n1-$Created.json" }
            if ($null -ne $Desktop) { $n | Add-Member -NotePropertyName desktopApp -NotePropertyValue $Desktop }
            return $n
        }
        function New-Entry($Id, $Created, $Reason = 'timeout', $Kind = 'permission') {
            [pscustomobject]@{ id = $Id; kind = $Kind; session = 'r1'; cwd = 'C:\p\app'; title = 'T'; detail = 'Bash: ls'; reason = $Reason; created = [int64]$Created }
        }
        function New-Wait($Session, $Created, $Kind = 'plan') {
            [pscustomobject]@{ session = $Session; kind = $Kind; cwd = 'C:\p\app'; title = 'T'; detail = 'Plan'; created = [int64]$Created }
        }
        function Get-Due($Outbox = @(), $Notices = @(), $Waits = @(), $Sent = @{}, $Away = $false, $Dnd = $false) {
            ,@(Get-DueAlerts $Outbox $Notices $Waits $Sent $script:Now $script:After $Away $Dnd)
        }
    }

    Context 'outbox entries (timeout, idle, away skip)' {
        It 'an outbox entry is due at once, whatever the reason: <reason>' -ForEach @(
            @{ reason = 'timeout' }, @{ reason = 'idle' }, @{ reason = 'away' }) {
            $r = Get-Due -Outbox @(New-Entry 'a1' ($script:Now - 1000) $reason)
            $r.Count | Should -Be 1
            $r[0].key | Should -BeExactly 'req:a1'
            $r[0].kind | Should -BeExactly 'permission'
            $r[0].session | Should -BeExactly 'r1'
            $r[0].cwd | Should -BeExactly 'C:\p\app'
            $r[0].title | Should -BeExactly 'T'
            $r[0].detail | Should -BeExactly 'Bash: ls'
        }
        It 'an outbox entry is due when you are present and without DND (the hook decided already)' {
            (Get-Due -Outbox @(New-Entry 'a1' $script:Now) -Away $false -Dnd $false).Count | Should -Be 1
        }
        It 'an outbox entry is due with DND on and not away' {
            (Get-Due -Outbox @(New-Entry 'a1' $script:Now) -Away $false -Dnd $true).Count | Should -Be 1
        }
        It 'a question entry keeps its kind' {
            (Get-Due -Outbox @(New-Entry 'q1' $script:Now 'timeout' 'question'))[0].kind | Should -BeExactly 'question'
        }
        It 'an outbox entry older than 30 min is dropped' {
            (Get-Due -Outbox @(New-Entry 'old' ($script:Now - 30 * 60000 - 1))).Count | Should -Be 0
        }
        It 'an outbox entry of exactly 30 min is still sent' {
            (Get-Due -Outbox @(New-Entry 'edge' ($script:Now - 30 * 60000))).Count | Should -Be 1
        }
    }

    Context 'finished notices' {
        It 'a notice is not due before X' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After + 1))).Count | Should -Be 0
        }
        It 'a notice is due at X without needing you to be away' {
            $r = Get-Due -Notices @(New-Notice ($script:Now - $script:After))
            $r.Count | Should -Be 1
            $r[0].key | Should -BeExactly 'done:done-n1-1799999820000.json'
            $r[0].kind | Should -BeExactly 'done'
            $r[0].session | Should -BeExactly 'n1'
            $r[0].cwd | Should -BeExactly 'C:\p\app'
            $r[0].title | Should -BeExactly 'T'
            $r[0].detail | Should -BeExactly 'All done'
        }
        It 'a notice with no desktopApp field counts as a window session' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After)) -Away $false).Count | Should -Be 1
        }
        It 'a notice of a desktop app session is not due at X while you are present' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After) $true) -Away $false).Count | Should -Be 0
        }
        It 'a notice of a desktop app session is due at X only when away' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After) $true) -Away $true).Count | Should -Be 1
        }
        It 'a notice of a desktop app session is not due before X even when away' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After + 1) $true) -Away $true).Count | Should -Be 0
        }
        It 'a notice of a window session with desktopApp false is due while present' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After) $false) -Away $false).Count | Should -Be 1
        }
        It 'with DND a notice is not due while present' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After)) -Away $false -Dnd $true).Count | Should -Be 0
        }
        It 'with DND a notice is due only when away' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After)) -Away $true -Dnd $true).Count | Should -Be 1
        }
        It 'with DND a notice is not due before X even when away' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After + 1)) -Away $true -Dnd $true).Count | Should -Be 0
        }
        It 'a question notice carries its text as the detail' {
            $n = New-Notice ($script:Now - $script:After)
            $n.question = $true
            $n.message = 'Which one?'
            (Get-Due -Notices @($n))[0].detail | Should -BeExactly 'Which one?'
        }
        It 'a question notice is marked as a question, a plain one is not' {
            $q = New-Notice ($script:Now - $script:After)
            $q.question = $true
            (Get-Due -Notices @($q))[0].question | Should -BeTrue
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After)))[0].question | Should -BeFalse
        }
        It 'NoticeAfterMs sets when notices are due (notifyAfter 5, notices expire at 5): <age> s -> <count>' -ForEach @(
            @{ age = 286; count = 1 }, @{ age = 284; count = 0 }) {
            $n = New-Notice ($script:Now - $age * 1000)
            @(Get-DueAlerts @() @($n) @() @{} $script:Now 300000 $false $false -NoticeAfterMs 285000).Count | Should -Be $count
        }
        It 'a notice is due only within 60 s after X: <age> ms past X -> <count>' -ForEach @(
            @{ age = 0; count = 1 }, @{ age = 59999; count = 1 }, @{ age = 60000; count = 0 }, @{ age = 3 * 3600000; count = 0 }) {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After - $age))).Count | Should -Be $count
        }
        It 'the 60 s window follows NoticeAfterMs: <age> ms -> <count>' -ForEach @(
            @{ age = 344999; count = 1 }, @{ age = 345000; count = 0 }) {
            $n = New-Notice ($script:Now - $age)
            @(Get-DueAlerts @() @($n) @() @{} $script:Now 300000 $false $false -NoticeAfterMs 285000).Count | Should -Be $count
        }
        It 'a desktop app notice still open hours after X does not alert when you step away now' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After - 2 * 3600000) $true) -Away $true).Count | Should -Be 0
        }
        It 'with DND a notice still open hours after X does not alert when you step away now' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After - 2 * 3600000)) -Away $true -Dnd $true).Count | Should -Be 0
        }
        It 'a notice skipped under DND at X does not alert once DND is off while you look at it' {
            (Get-Due -Notices @(New-Notice ($script:Now - $script:After - 10 * 60000)) -Away $false -Dnd $false).Count | Should -Be 0
        }
        It 'notices already past X when Telegram becomes ready (connect, Alerts on, widget restart) are not sent' {
            $old = @((New-Notice ($script:Now - $script:After - 2 * 60000)), (New-Notice ($script:Now - $script:After - 25 * 60000)),
                (New-Notice ($script:Now - 11 * 3600000) $true))
            (Get-Due -Notices $old -Away $true).Count | Should -Be 0
            (Get-Due -Notices $old -Away $false).Count | Should -Be 0
        }
        It 'NoticeAfterMs does not change outbox entries or wait markers' {
            $w = New-Wait 'w1' ($script:Now - 286000)
            @(Get-DueAlerts @() @() @($w) @{} $script:Now 300000 $true $false -NoticeAfterMs 285000).Count | Should -Be 0
        }
    }

    Context 'waiting in VS Code' {
        It 'a wait marker is not due while present' {
            (Get-Due -Waits @(New-Wait 'w1' ($script:Now - 10 * $script:After)) -Away $false).Count | Should -Be 0
        }
        It 'a wait marker is not due before X even when away' {
            (Get-Due -Waits @(New-Wait 'w1' ($script:Now - $script:After + 1)) -Away $true).Count | Should -Be 0
        }
        It 'a wait marker of kind <kind> is due at X when away' -ForEach @(
            @{ kind = 'plan' }, @{ kind = 'permission' }, @{ kind = 'question' }) {
            $r = Get-Due -Waits @(New-Wait 'w1' ($script:Now - $script:After) $kind) -Away $true
            $r.Count | Should -Be 1
            $r[0].key | Should -BeExactly 'wait:w1:1799999820000'
            $r[0].kind | Should -BeExactly $kind
            $r[0].session | Should -BeExactly 'w1'
            $r[0].detail | Should -BeExactly 'Plan'
        }
        It 'a wait marker is due when away, with or without DND' {
            (Get-Due -Waits @(New-Wait 'w1' ($script:Now - $script:After)) -Away $true -Dnd $true).Count | Should -Be 1
        }
        It 'a newer marker of the same session has its own key' {
            $a = (Get-Due -Waits @(New-Wait 'w1' ($script:Now - $script:After)) -Away $true)[0].key
            $b = (Get-Due -Waits @(New-Wait 'w1' ($script:Now - $script:After - 1)) -Away $true)[0].key
            $a | Should -Not -Be $b
        }
    }

    Context 'nothing twice' {
        It 'nothing already sent is returned' {
            $sent = @{ 'req:a1' = @{ message = 5; at = $script:Now }; 'done:done-n1-1799999820000.json' = @{}; 'wait:w1:1799999820000' = @{} }
            $r = Get-Due -Outbox @(New-Entry 'a1' $script:Now) `
                -Notices @(New-Notice ($script:Now - $script:After)) `
                -Waits @(New-Wait 'w1' ($script:Now - $script:After)) -Sent $sent -Away $true
            $r.Count | Should -Be 0
        }
        It 'only the items not sent yet are returned' {
            $sent = @{ 'req:a1' = @{ at = $script:Now } }
            $r = Get-Due -Outbox @((New-Entry 'a1' $script:Now), (New-Entry 'a2' $script:Now)) -Sent $sent
            $r.Count | Should -Be 1
            $r[0].key | Should -BeExactly 'req:a2'
        }
        It 'a null Sent table is the same as an empty one' {
            (Get-Due -Outbox @(New-Entry 'a1' $script:Now) -Sent $null).Count | Should -Be 1
        }
    }

    Context 'mixed input' {
        It 'returns everything due, oldest first' {
            $r = Get-Due -Outbox @(New-Entry 'a1' ($script:Now - 500)) `
                -Notices @(New-Notice ($script:Now - $script:After - 3000)) `
                -Waits @(New-Wait 'w1' ($script:Now - $script:After - 1000)) -Away $true
            $r.Count | Should -Be 3
            (($r | ForEach-Object { $_.key.Split(':')[0] }) -join ',') | Should -BeExactly 'done,wait,req'
        }
        It 'empty and null inputs give nothing' {
            @(Get-DueAlerts $null $null $null $null $script:Now $script:After $true $false).Count | Should -Be 0
            @(Get-DueAlerts @() @() @() @{} $script:Now $script:After $true $false).Count | Should -Be 0
        }
    }
}

Describe 'Format-AlertText' {
    BeforeAll {
        $script:S = Get-Strings 'en'
        function New-Alert($Kind = 'permission', $Detail = 'Bash: ls', $Title = 'Fix login', $Cwd = 'C:\p\app') {
            @{ key = "req:$([guid]::NewGuid())"; kind = $Kind; session = 's'; cwd = $Cwd; title = $Title; detail = $Detail }
        }
    }

    It 'a permission alert has the header, the session line and the detail' {
        $t = Format-AlertText @(New-Alert) $script:S
        $t | Should -BeExactly ($script:S.tgPermission + "`n" + (Format-SessionLine 'C:\p\app' 'Fix login') + "`n" + 'Bash: ls')
    }
    It 'the header follows the kind: <kind>' -ForEach @(
        @{ kind = 'permission'; key = 'tgPermission' }, @{ kind = 'question'; key = 'tgQuestion' },
        @{ kind = 'done'; key = 'tgDone' }, @{ kind = 'plan'; key = 'tgPlan' }) {
        (Format-AlertText @(New-Alert $kind) $script:S).StartsWith($script:S.$key + "`n") | Should -BeTrue
    }
    It 'a finished notice that asks a question gets the "question for you" header in <lang>' -ForEach @(
        @{ lang = 'pt' }, @{ lang = 'en' }, @{ lang = 'es' }) {
        $s = Get-Strings $lang
        $s.tgDoneQuestion | Should -Not -BeNullOrEmpty
        $s.tgDoneQuestion | Should -Not -Be $s.tgDone
        $a = New-Alert 'done' 'Which one?'
        $a.question = $true
        (Format-AlertText @($a) $s).StartsWith($s.tgDoneQuestion + "`n") | Should -BeTrue
        (Format-AlertText @(New-Alert 'done' 'All done') $s).StartsWith($s.tgDone + "`n") | Should -BeTrue
    }
    It 'a missing detail leaves no empty line' {
        $t = Format-AlertText @(New-Alert 'done' '') $script:S
        $t | Should -BeExactly ($script:S.tgDone + "`n" + (Format-SessionLine 'C:\p\app' 'Fix login'))
    }
    It 'a missing project and title leaves out the session line' {
        $t = Format-AlertText @(New-Alert 'done' 'x' '' '') $script:S
        $t | Should -BeExactly ($script:S.tgDone + "`nx")
    }
    It 'cuts a long detail to 200 characters' {
        $t = Format-AlertText @(New-Alert 'permission' ('d' * 500)) $script:S
        $detail = $t.Split("`n")[2]
        $detail.Length | Should -Be 200
        $detail.EndsWith('...') | Should -BeTrue
    }
    It 'keeps a detail of exactly 200 characters whole' {
        $d = 'd' * 200
        (Format-AlertText @(New-Alert 'permission' $d) $script:S).Split("`n")[2] | Should -BeExactly $d
    }
    It 'does not split an emoji when cutting the detail' {
        $d = ('a' * 196) + [char]::ConvertFromUtf32(0x1F600) + 'tail'
        $detail = (Format-AlertText @(New-Alert 'permission' $d) $script:S).Split("`n")[2]
        $detail.Length | Should -BeLessOrEqual 200
        foreach ($i in 0..($detail.Length - 1)) {
            if ([char]::IsHighSurrogate($detail[$i])) { [char]::IsLowSurrogate($detail[$i + 1]) | Should -BeTrue }
        }
    }
    It 'separates the blocks with a blank line' {
        $t = Format-AlertText @((New-Alert 'permission' 'one'), (New-Alert 'done' 'two')) $script:S
        $blocks = $t -split "`n`n"
        $blocks.Count | Should -Be 2
        $blocks[0] | Should -Match 'one$'
        $blocks[1] | Should -Match 'two$'
    }
    It 'accepts a single alert that is not wrapped in an array' {
        { Format-AlertText (New-Alert) $script:S } | Should -Not -Throw
    }
    It 'is plain text: no markdown markers are added' {
        $t = Format-AlertText @(New-Alert) $script:S
        $t | Should -Not -Match '[*_`]'
    }
    It 'Format-AlertText keeps 10 long items under 4096 characters and says how many were left out' {
        $alerts = 1..10 | ForEach-Object { New-Alert 'permission' ('x' * 5000) ('t' * 300) ('C:\p\' + ('f' * 200)) }
        $t = Format-AlertText $alerts $script:S
        $t.Length | Should -BeLessOrEqual 4096
        $shown = @($t -split "`n`n" | Where-Object { $_.StartsWith($script:S.tgPermission) }).Count
        $shown | Should -BeGreaterThan 0
        $left = 10 - $shown
        $left | Should -BeGreaterThan 0
        $t.EndsWith(($script:S.tgMore -f $left)) | Should -BeTrue
    }
    It 'says nothing about leftovers when everything fits' {
        $t = Format-AlertText @((New-Alert), (New-Alert)) $script:S
        $t | Should -Not -Match 'more'
    }
    It 'holds the cap even for a single huge title, project and detail' {
        $t = Format-AlertText @(New-Alert 'permission' ('x' * 100000) ('t' * 100000) ('C:\' + ('p' * 100000))) $script:S
        $t.Length | Should -BeLessOrEqual 4096
        $t.StartsWith($script:S.tgPermission) | Should -BeTrue
    }
    It 'holds the cap with 1000 short items' {
        $alerts = 1..1000 | ForEach-Object { New-Alert 'done' 'ok' }
        $t = Format-AlertText $alerts $script:S
        $t.Length | Should -BeLessOrEqual 4096
        $t | Should -Match '\+\d+ more$'
    }
    It 'gives nothing for no alerts' {
        Format-AlertText @() $script:S | Should -BeExactly ''
    }
}

Describe 'Read-SentAlerts / Save-SentAlerts' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
    }

    It 'reads an empty table when there is no file' {
        $r = Read-SentAlerts $script:Dir
        $r | Should -BeOfType [hashtable]
        $r.Count | Should -Be 0
    }
    It 'saves and reads back key -> message, session, at, resolved' {
        $now = Get-NowMs
        $sent = @{ 'req:a1' = @{ message = 77; session = 's1'; at = $now; resolved = $false }
                   'done:d1' = @{ message = 78; session = 's2'; at = $now - 1000; resolved = $true } }
        Save-SentAlerts $script:Dir $sent | Should -BeTrue
        $r = Read-SentAlerts $script:Dir
        $r.Count | Should -Be 2
        $r['req:a1'].message | Should -Be 77
        $r['req:a1'].session | Should -BeExactly 's1'
        $r['req:a1'].at | Should -Be $now
        $r['req:a1'].resolved | Should -BeFalse
        $r['done:d1'].resolved | Should -BeTrue
        $r['req:a1'] | Should -BeOfType [hashtable]
    }
    It 'overwrites the previous file and leaves no .tmp' {
        $now = Get-NowMs
        Save-SentAlerts $script:Dir @{ 'a' = @{ message = 1; session = 's'; at = $now; resolved = $false } } | Out-Null
        Save-SentAlerts $script:Dir @{ 'b' = @{ message = 2; session = 's'; at = $now; resolved = $false } } | Should -BeTrue
        $r = Read-SentAlerts $script:Dir
        $r.ContainsKey('a') | Should -BeFalse
        $r.ContainsKey('b') | Should -BeTrue
        (Join-Path $script:Dir 'telegram-sent.json.tmp') | Should -Not -Exist
    }
    It 'Read-SentAlerts drops entries older than 24 h' {
        $now = Get-NowMs
        $h = 3600000
        Save-SentAlerts $script:Dir @{
            'old'   = @{ message = 1; session = 's'; at = $now - 24 * $h - 60000; resolved = $false }
            'fresh' = @{ message = 2; session = 's'; at = $now - 23 * $h; resolved = $false } } | Out-Null
        $r = Read-SentAlerts $script:Dir
        $r.ContainsKey('old') | Should -BeFalse
        $r.ContainsKey('fresh') | Should -BeTrue
    }
    It 'drops entries that have no usable time' {
        [IO.File]::WriteAllText((Join-Path $script:Dir 'telegram-sent.json'), '{"a":{"message":1},"b":{"message":2,"at":"soon"},"c":5}')
        (Read-SentAlerts $script:Dir).Count | Should -Be 0
    }
    It 'reads an empty table from a broken file' {
        [IO.File]::WriteAllText((Join-Path $script:Dir 'telegram-sent.json'), '{"a": ')
        (Read-SentAlerts $script:Dir).Count | Should -Be 0
    }
    It 'Save-SentAlerts returns $false when it cannot write' {
        $lock = [IO.File]::Open((Join-Path $script:Dir 'telegram-sent.json.tmp'), 'Create', 'ReadWrite', 'None')
        try { Save-SentAlerts $script:Dir @{ 'a' = @{ at = (Get-NowMs) } } | Should -BeFalse } finally { $lock.Dispose() }
    }
}

Describe 'Read-SentAlerts keeps what the resolved edit needs' {
    It 'reads back the message text and the edited flag, and a missing message id as null' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $now = Get-NowMs
        Save-SentAlerts $dir @{
            'req:a' = @{ message = 5; session = 's'; at = $now; resolved = $true; text = 'Hello'; edited = $true }
            'req:b' = @{ message = $null; session = 's'; at = $now; resolved = $false } } | Out-Null
        $r = Read-SentAlerts $dir
        $r['req:a'].text | Should -BeExactly 'Hello'
        $r['req:a'].edited | Should -BeTrue
        $r['req:b'].message | Should -BeNullOrEmpty
        $r['req:b'].text | Should -BeExactly ''
        $r['req:b'].edited | Should -BeFalse
    }
}

Describe 'ConvertTo-AwaySecs' {
    It 'keeps <text> as <secs>' -ForEach @(@{ text = '0'; secs = 0 }, @{ text = '1'; secs = 1 }, @{ text = '600'; secs = 600 }) {
        ConvertTo-AwaySecs $text | Should -Be $secs
    }
    It 'falls back to 300 for "<text>"' -ForEach @(@{ text = '' }, @{ text = '-5' }, @{ text = 'abc' }, @{ text = '1.5' }, @{ text = '99999999999' }) {
        ConvertTo-AwaySecs $text | Should -Be 300
    }
}

Describe 'Test-TelegramRetryable' {
    # A retry can send twice (a timeout may have been delivered), so only failures that may pass next time qualify
    It 'retries status <status>' -ForEach @(@{ status = 0 }, @{ status = 429 }, @{ status = 500 }, @{ status = 502 }, @{ status = 503 }) {
        Test-TelegramRetryable $status | Should -BeTrue
    }
    It 'does not retry status <status>' -ForEach @(@{ status = 400 }, @{ status = 401 }, @{ status = 403 }, @{ status = 404 }, @{ status = 200 }) {
        Test-TelegramRetryable $status | Should -BeFalse
    }
}

Describe 'Get-IdleSeconds' {
    It 'returns the seconds since the last input as a non-negative number' {
        $s = Get-IdleSeconds
        $s | Should -BeOfType [int]
        $s | Should -BeGreaterOrEqual 0
    }
}

Describe 'Telegram sender helpers' {
    BeforeEach {
        $script:Q = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Q | Out-Null
    }

    It 'Read-AlertFiles reads the files with that prefix, adds the file path and skips broken ones' {
        $id = Add-AlertOutbox $script:Q @{ kind = 'permission'; session = 's1'; detail = 'ls' }
        Set-WaitMarker $script:Q @{ session = 's2'; kind = 'plan'; created = 1 }
        [IO.File]::WriteAllText((Join-Path $script:Q 'tg-broken.json'), '{"id": ')
        $r = @(Read-AlertFiles $script:Q 'tg')
        $r.Count | Should -Be 1
        $r[0].id | Should -BeExactly $id
        $r[0].file | Should -BeExactly (Join-Path $script:Q "tg-$id.json")
    }
    It 'Get-SeenStamps maps each session to its seen time' {
        Set-SessionSeen $script:Q 's1'
        [IO.File]::WriteAllText((Join-Path $script:Q 'seen-s2.json'), '{"session":"s2","at":1234}')
        $t = Get-SeenStamps $script:Q
        $t | Should -BeOfType [hashtable]
        $t['s2'] | Should -Be 1234
        [math]::Abs($t['s1'] - (Get-NowMs)) | Should -BeLessThan 5000
    }
    It 'Select-UnseenAlerts drops items whose session was seen after they were created, and keeps the rest' {
        $items = @(
            [pscustomobject]@{ session = 'old'; created = [int64]100 }
            [pscustomobject]@{ session = 'same'; created = [int64]200 }
            [pscustomobject]@{ session = 'later'; created = [int64]300 }
            [pscustomobject]@{ session = 'none'; created = [int64]400 })
        $seen = @{ old = [int64]150; same = [int64]200; later = [int64]250 }
        $r = @(Select-UnseenAlerts $items $seen)
        ($r | ForEach-Object { $_.session }) -join ',' | Should -BeExactly 'same,later,none'
    }
    It 'Remove-OldAlertFiles removes stamps and markers older than 24 h and outbox entries older than 30 min' {
        foreach ($n in 'seen-a.json', 'alerted-a.json', 'wait-a.json', 'seen-b.json', 'tg-old.json', 'tg-new.json', 'done-a-1.json', 'req-a.json') {
            [IO.File]::WriteAllText((Join-Path $script:Q $n), '{}')
        }
        $day = [DateTime]::UtcNow.AddHours(-25)
        foreach ($n in 'seen-a.json', 'alerted-a.json', 'wait-a.json', 'done-a-1.json', 'req-a.json') { [IO.File]::SetLastWriteTimeUtc((Join-Path $script:Q $n), $day) }
        [IO.File]::SetLastWriteTimeUtc((Join-Path $script:Q 'tg-old.json'), [DateTime]::UtcNow.AddMinutes(-31))
        [IO.File]::SetLastWriteTimeUtc((Join-Path $script:Q 'seen-b.json'), [DateTime]::UtcNow.AddHours(-23))
        Remove-OldAlertFiles $script:Q (Get-NowMs)
        $left = @(Get-ChildItem -LiteralPath $script:Q -File | ForEach-Object { $_.Name } | Sort-Object)
        $left -join ',' | Should -BeExactly 'done-a-1.json,req-a.json,seen-b.json,tg-new.json'
    }

    Context 'resolved' {
        BeforeAll {
            function New-Sent($Message, $Session, $At, $Resolved = $false, $Edited = $false, $Text = 'Alert') {
                @{ message = $Message; session = $Session; at = [int64]$At; resolved = $Resolved; text = $Text; edited = $Edited }
            }
        }
        It 'Update-ResolvedAlerts marks an alert resolved when its session was seen after it was sent' {
            $sent = @{ 'req:a' = (New-Sent 1 's1' 100); 'req:b' = (New-Sent 2 's2' 100); 'req:c' = (New-Sent 3 's3' 100) }
            Update-ResolvedAlerts $sent @{ s1 = [int64]150; s2 = [int64]100 } @{} | Should -BeTrue
            $sent['req:a'].resolved | Should -BeTrue
            $sent['req:b'].resolved | Should -BeFalse
            $sent['req:c'].resolved | Should -BeFalse
        }
        It 'Update-ResolvedAlerts marks a finished notice resolved when it was closed in the widget' {
            $sent = @{ 'done:done-s1-5.json' = (New-Sent 1 's1' 100); 'done:done-s2-6.json' = (New-Sent 2 's2' 100) }
            Update-ResolvedAlerts $sent @{} @{ 'done-s1-5.json' = $true } | Should -BeTrue
            $sent['done:done-s1-5.json'].resolved | Should -BeTrue
            $sent['done:done-s2-6.json'].resolved | Should -BeFalse
        }
        It 'Update-ResolvedAlerts returns false when nothing changed' {
            $sent = @{ 'req:a' = (New-Sent 1 's1' 100 $true) }
            Update-ResolvedAlerts $sent @{ s1 = [int64]500 } @{} | Should -BeFalse
        }
        It 'Get-ResolvedEdit gives a message whose alerts are all resolved, once' {
            $sent = @{ 'req:a' = (New-Sent 7 's1' 100 $true -Text 'Batch'); 'req:b' = (New-Sent 7 's2' 100 $true -Text 'Batch') }
            $e = Get-ResolvedEdit $sent
            $e.message | Should -Be 7
            $e.text | Should -BeExactly 'Batch'
            @($e.alertKeys | Sort-Object) -join ',' | Should -BeExactly 'req:a,req:b'
            foreach ($k in $e.alertKeys) { $sent[$k].edited = $true }
            Get-ResolvedEdit $sent | Should -BeNullOrEmpty
        }
        It 'Get-ResolvedEdit waits until every alert of a batch is resolved' {
            $sent = @{ 'req:a' = (New-Sent 7 's1' 100 $true); 'req:b' = (New-Sent 7 's2' 100 $false) }
            Get-ResolvedEdit $sent | Should -BeNullOrEmpty
        }
        It 'Get-ResolvedEdit skips alerts that were never delivered (no message id) or have no text' {
            $sent = @{ 'req:a' = (New-Sent $null 's1' 100 $true); 'req:b' = (New-Sent 8 's2' 100 $true -Text '') }
            Get-ResolvedEdit $sent | Should -BeNullOrEmpty
        }
        It 'Format-ResolvedText appends the mark after a blank line' {
            Format-ResolvedText 'Alert' 'OK resolved' | Should -BeExactly "Alert`n`nOK resolved"
        }
        It 'Format-ResolvedText cuts a long text so the result fits in 4096 characters' {
            $r = Format-ResolvedText ('x' * 4096) 'OK resolved'
            $r.Length | Should -BeLessOrEqual 4096
            $r | Should -BeLike "*...`n`nOK resolved"
        }
    }
}

Describe 'Get-NoticesInFront' {
    BeforeAll {
        function New-Notice([string]$Key, $Hwnd, $Desktop) {
            $n = [pscustomobject]@{ key = $Key; hwnd = $Hwnd }
            if ($null -ne $Desktop) { $n | Add-Member -NotePropertyName desktopApp -NotePropertyValue $Desktop }
            return $n
        }
    }
    It 'returns the key of the notice whose window is in front' {
        $n = @((New-Notice 'a' 100 $false), (New-Notice 'b' 200 $false))
        @(Get-NoticesInFront $n 200) | Should -Be @('b')
    }
    It 'returns nothing when no notice has that window' {
        @(Get-NoticesInFront @((New-Notice 'a' 100 $false)) 300).Count | Should -Be 0
    }
    It 'ignores a notice whose window is unknown (hwnd 0), even when nothing is in front' {
        @(Get-NoticesInFront @((New-Notice 'a' 0 $false)) 0).Count | Should -Be 0
    }
    It 'ignores Claude desktop app notices: one window serves every session' {
        @(Get-NoticesInFront @((New-Notice 'a' 100 $true)) 100).Count | Should -Be 0
    }
    It 'treats a notice without desktopApp (an old one) as not a desktop app' {
        @(Get-NoticesInFront @((New-Notice 'a' 100 $null)) 100) | Should -Be @('a')
    }
    It 'returns both keys for two notices on the same window (two tabs of one terminal)' {
        $n = @((New-Notice 'a' 100 $false), (New-Notice 'b' 100 $false), (New-Notice 'c' 200 $false))
        @(Get-NoticesInFront $n 100) | Should -Be @('a', 'b')
    }
    It 'accepts no notices' {
        @(Get-NoticesInFront @() 100).Count | Should -Be 0
        @(Get-NoticesInFront $null 100).Count | Should -Be 0
    }
}
