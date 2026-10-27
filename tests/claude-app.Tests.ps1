# Unit tests for the pure part of plugins/opaiva-code-widget/scripts/claude-app.ps1 (which sidebar row is the session)
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\claude-app.ps1')
    # Sidebar of the Claude desktop app as read on Daniel's PC (2026-10-27): each row's full name, and the
    # titles the app gives in its "More options for <title>" buttons
    $names = @(
        'Presion excesiva en sistema de riego'
        'cc-widget'
        'EZD Esperando entrada Pedile a la sesion 94-99 que te muestre el plan'
        'BMS - EZD - Item 94-99 Iniciado por Claude desde EZD BMS-MDG-EZD'
        'BMS - EZD - Item 97 Iniciado por Claude desde EZD'
        'cc-widget Bifurcado de cc-widget claude-code-widget'
        'Hola'
        'Security review of claude-code-widget fork SAP-BTP-Developer-Partners-CCRT-App'
        'New session SAP-BTP-Developer-Partners-CCRT-App'
        'New session'
        'EZD BMS-MDG-EZD'
    )
    $titles = @('Presion excesiva en sistema de riego', 'cc-widget', 'EZD', 'BMS - EZD - Item 94-99', 'BMS - EZD - Item 97',
        'cc-widget', 'Hola', 'Security review of claude-code-widget fork', 'New session', 'New session', 'EZD')
}

Describe 'Get-ClaudeAppRowTitles' {
    It 'gives each row the longest title it starts with' {
        $got = Get-ClaudeAppRowTitles $names @('cc-widget', 'EZD', 'BMS - EZD - Item 94-99', 'BMS - EZD - Item 97', 'Hola',
            'Presion excesiva en sistema de riego', 'Security review of claude-code-widget fork', 'New session')
        $got | Should -Be $titles
    }
    It 'gives an empty title to a row no title starts' {
        @(Get-ClaudeAppRowTitles @('Something else') @('cc-widget'))[0] | Should -BeExactly ''
    }
}

Describe 'Find-ClaudeAppSessionIndex' {
    It 'finds the row whose title is the session title, whatever the app adds after it' {
        Find-ClaudeAppSessionIndex $titles 'Hola' | Should -Be 6
        Find-ClaudeAppSessionIndex $titles 'Security review of claude-code-widget fork' | Should -Be 7
        # "Started by Claude from ..." rows
        Find-ClaudeAppSessionIndex $titles 'BMS - EZD - Item 97' | Should -Be 4
    }
    It 'does not take a session whose title only starts the same way' {
        Find-ClaudeAppSessionIndex $titles 'BMS - EZD - Item 9' | Should -Be -1
    }
    It 'gives up when the title fits more than one row (a fork keeps its title)' {
        Find-ClaudeAppSessionIndex $titles 'cc-widget' | Should -Be -1
        Find-ClaudeAppSessionIndex $titles 'New session' | Should -Be -1
        Find-ClaudeAppSessionIndex $titles 'EZD' | Should -Be -1
    }
    It 'gives up when no row fits, or without a title' {
        Find-ClaudeAppSessionIndex $titles 'Not there' | Should -Be -1
        Find-ClaudeAppSessionIndex $titles '' | Should -Be -1
        Find-ClaudeAppSessionIndex @() 'Hola' | Should -Be -1
    }
    It 'ignores letter case and surrounding spaces' {
        Find-ClaudeAppSessionIndex $titles ' hola ' | Should -Be 6
    }
}

Describe 'Find-ClaudeAppSessionIndex with forks' {
    It 'picks the original row for the original session, and the fork row for the fork' {
        Find-ClaudeAppSessionIndex $titles 'cc-widget' $names $false | Should -Be 1
        Find-ClaudeAppSessionIndex $titles 'cc-widget' $names $true | Should -Be 5
    }
    It 'still gives up when it does not know whether the session is a fork' {
        Find-ClaudeAppSessionIndex $titles 'cc-widget' $names $null | Should -Be -1
    }
    It 'still gives up when several rows remain' {
        # two "New session" rows that are not forks
        Find-ClaudeAppSessionIndex $titles 'New session' $names $false | Should -Be -1
    }
}

Describe 'Test-ClaudeSessionFork' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'projects'
        New-Item -ItemType Directory -Path $dir | Out-Null
        # A fork starts with the history it copied, which still carries the original session's id
        [IO.File]::WriteAllText((Join-Path $dir 'fork-1.jsonl'), ('{"type":"user","sessionId":"orig-1","message":{}}' + "`n" + '{"sessionId":"fork-1"}'))
        [IO.File]::WriteAllText((Join-Path $dir 'orig-1.jsonl'), ('{"type":"summary"}' + "`n" + '{"type":"user","sessionId":"orig-1"}'))
        [IO.File]::WriteAllText((Join-Path $dir 'empty-1.jsonl'), '')
    }
    It 'is a fork when the first session id in the transcript is another session' {
        Test-ClaudeSessionFork (Join-Path $dir 'fork-1.jsonl') 'fork-1' | Should -BeTrue
    }
    It 'is not a fork when the first session id is its own' {
        Test-ClaudeSessionFork (Join-Path $dir 'orig-1.jsonl') 'orig-1' | Should -BeFalse
    }
    It 'finds a transcript by session id inside its project folder' {
        $projects = Join-Path $TestDrive 'claude-projects'
        New-Item -ItemType Directory -Path (Join-Path $projects 'C--dev-web') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $projects 'C--dev-web\web-1.jsonl'), '')
        Find-ClaudeSessionTranscript 'web-1' $projects | Should -BeExactly (Join-Path $projects 'C--dev-web\web-1.jsonl')
        Find-ClaudeSessionTranscript 'nope' $projects | Should -BeExactly ''
    }
    It 'does not know without a transcript or a session id' {
        Test-ClaudeSessionFork (Join-Path $dir 'missing.jsonl') 'x' | Should -BeNullOrEmpty
        Test-ClaudeSessionFork (Join-Path $dir 'empty-1.jsonl') 'empty-1' | Should -BeNullOrEmpty
    }
}
