# Unit tests for the pure part of plugins/opaiva-code-widget/scripts/claude-app.ps1 (which sidebar row is the session)
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\claude-app.ps1')
    # Session rows as the Claude desktop app names them in its sidebar (read on Daniel's PC, 2026-10-27)
    $rows = @(
        'cc-widget'
        'CCRT - Manual CC Abierto SAP-BTP-Developer-Partners-CCRT-App'
        'cc-widget Bifurcado de cc-widget claude-code-widget'
        'Hola'
        'Security review of claude-code-widget fork SAP-BTP-Developer-Partners-CCRT-App'
        'New session SAP-BTP-Developer-Partners-CCRT-App'
        'New session Bifurcado de New session SAP-BTP-Developer-Partners-CCRT-App'
        'EZD BMS-MDG-EZD'
        'EZD 101 Bifurcado de EZD BMS-MDG-EZD'
        'New session'
    )
}

Describe 'Find-ClaudeAppSessionIndex' {
    It 'finds a row named by title and project' {
        Find-ClaudeAppSessionIndex $rows 'Security review of claude-code-widget fork' 'SAP-BTP-Developer-Partners-CCRT-App' | Should -Be 4
    }
    It 'finds a row named by the title alone when it is the only one' {
        Find-ClaudeAppSessionIndex $rows 'Hola' 'whatever' | Should -Be 3
    }
    It 'does not take a session whose title only starts the same way' {
        # "EZD 101 ..." is another session; "EZD" with its project is row 7
        Find-ClaudeAppSessionIndex $rows 'EZD' 'BMS-MDG-EZD' | Should -Be 7
    }
    It 'gives up when the title fits more than one row (a fork keeps its title)' {
        Find-ClaudeAppSessionIndex $rows 'cc-widget' 'claude-code-widget' | Should -Be -1
        Find-ClaudeAppSessionIndex $rows 'New session' 'SAP-BTP-Developer-Partners-CCRT-App' | Should -Be -1
    }
    It 'gives up when no row fits, or without a title' {
        Find-ClaudeAppSessionIndex $rows 'Not there' 'x' | Should -Be -1
        Find-ClaudeAppSessionIndex $rows '' 'x' | Should -Be -1
        Find-ClaudeAppSessionIndex @() 'Hola' 'x' | Should -Be -1
    }
    It 'ignores letter case and surrounding spaces' {
        Find-ClaudeAppSessionIndex $rows ' hola ' 'x' | Should -Be 3
    }
}
