# End-to-end tests: hook.ps1 as a real process, JSON in on stdin, JSON out on stdout.
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\common.ps1')
    . (Join-Path $PSScriptRoot 'helpers\HookHarness.ps1')
    $pt = Get-Strings 'pt'
    function Get-QueueFiles($Sandbox, [string]$Filter = '*') {
        @(Get-ChildItem -LiteralPath $Sandbox.Queue -Filter $Filter -File -ErrorAction SilentlyContinue)
    }
}

Describe 'hook.ps1 end to end' {
    BeforeEach { $box = New-HookSandbox }
    AfterEach { Remove-HookSandbox $box }

    Context 'PermissionRequest' {
        BeforeAll {
            function New-BashEvent($Sandbox, [string]$Command) {
                New-HookEvent 'PermissionRequest' $Sandbox.Data @{ tool_name = 'Bash'; tool_input = @{ command = $Command } }
            }
        }

        It 'prints allow when the widget approves' {
            $run = Start-Hook $box (New-BashEvent $box 'npm test')
            $req = Wait-HookRequest $box
            $req.kind | Should -Be 'permission'
            $req.tool | Should -Be 'Bash'
            $req.detail | Should -BeExactly 'npm test'
            Send-WidgetResponse $box $req.id @{ decision = 'allow' }
            $r = Complete-Hook $run
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
            (Get-QueueFiles $box).Count | Should -Be 0
        }
        It 'prints deny with the localized message when the widget denies' {
            $run = Start-Hook $box (New-BashEvent $box 'rm -rf build')
            $req = Wait-HookRequest $box
            Send-WidgetResponse $box $req.id @{ decision = 'deny' }
            $r = Complete-Hook $run
            $r.Stdout | Should -Not -Match '[^\x00-\x7F]'
            $decision = ($r.Stdout | ConvertFrom-Json).hookSpecificOutput.decision
            $decision.behavior | Should -Be 'deny'
            $decision.message | Should -BeExactly $pt.deniedMessage
        }
        It 'prints nothing when the widget hands the request back' {
            $run = Start-Hook $box (New-BashEvent $box 'npm test')
            $req = Wait-HookRequest $box
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            $r = Complete-Hook $run
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
        Context 'Edit with suggestions' {
            BeforeAll {
                function New-EditEvent($Sandbox) {
                    $e = New-HookEvent 'PermissionRequest' $Sandbox.Data @{
                        tool_name = 'Edit'
                        tool_input = @{ file_path = 'C:\dev\a.ps1'; old_string = "keep`nold"; new_string = "keep`nnew" }
                    }
                    $e.permission_suggestions = @(
                        @{ type = 'removeRules'; rules = @([ordered]@{ toolName = 'Bash' }); behavior = 'allow'; destination = 'userSettings' },
                        [ordered]@{ type = 'addRules'; rules = @([ordered]@{ toolName = 'Edit'; ruleContent = 'src/**' }); behavior = 'allow'; destination = 'session'; mode = $null },
                        @{ type = 'setMode'; behavior = 'allow'; destination = 'session'; mode = 'acceptEdits' })
                    return $e
                }
            }
            It 'sends the change and only the offered suggestions to the widget' {
                $run = Start-Hook $box (New-EditEvent $box)
                $req = Wait-HookRequest $box
                $req.change.kind | Should -BeExactly 'edit'
                $req.change.edits[0].old | Should -BeExactly "keep`nold"
                @($req.suggestions).Count | Should -Be 2
                $req.suggestions[0].index | Should -Be 1
                $req.suggestions[0].rules[0].toolName | Should -BeExactly 'Edit'
                $req.suggestions[0].rules[0].ruleContent | Should -BeExactly 'src/**'
                $req.suggestions[1].index | Should -Be 2
                Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
                [void](Complete-Hook $run)
            }
            It 'allowAlways with a valid index prints that suggestion as updatedPermissions' {
                $run = Start-Hook $box (New-EditEvent $box)
                $req = Wait-HookRequest $box
                Send-WidgetResponse $box $req.id @{ decision = 'allowAlways'; index = 1 }
                $r = Complete-Hook $run
                $r.Stdout | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":[{"toolName":"Edit","ruleContent":"src/**"}],"behavior":"allow","destination":"session"}]}}}'
            }
            It 'allowAlways with an index that was not offered only allows' {
                foreach ($bad in 0, 7, -1) {
                    $run = Start-Hook $box (New-EditEvent $box)
                    $req = Wait-HookRequest $box
                    Send-WidgetResponse $box $req.id @{ decision = 'allowAlways'; index = $bad }
                    $r = Complete-Hook $run
                    $r.Stdout | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
                }
            }
            It 'ignores suggestion content in the response: only the index counts' {
                $run = Start-Hook $box (New-EditEvent $box)
                $req = Wait-HookRequest $box
                Send-WidgetResponse $box $req.id @{ decision = 'allowAlways'; index = 'abc'; type = 'addRules'; rules = @([ordered]@{ toolName = 'Bash' }); destination = 'userSettings' }
                $r = Complete-Hook $run
                $r.Stdout | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
            }
        }
        It 'sends non-ASCII input to the widget intact' {
            $command = 'echo ' + [char]0x00E7 + [char]0x00E3 + 'o'
            $run = Start-Hook $box (New-BashEvent $box $command)
            $req = Wait-HookRequest $box
            $req.detail | Should -BeExactly $command
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            [void](Complete-Hook $run)
        }
        It 'never routes plan approval (ExitPlanMode) to the widget' {
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'ExitPlanMode'; tool_input = @{ plan = 'x' } }))
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*').Count | Should -Be 0
        }
        It 'gives up within 5 s when the widget closes while waiting' {
            $run = Start-Hook $box (New-BashEvent $box 'npm test')
            [void](Wait-HookRequest $box)
            $closedAt = $run.Clock.Elapsed.TotalSeconds
            Close-FakeWidget $box
            $r = Complete-Hook $run
            $r.Stdout | Should -BeNullOrEmpty
            ($r.Seconds - $closedAt) | Should -BeLessThan 5
        }
        It 'skips the widget when the user is away' {
            $r = Complete-Hook (Start-Hook $box (New-BashEvent $box 'npm test') -Env @{ CLAUDE_WIDGET_AWAY_SECS = '0' })
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*').Count | Should -Be 0
        }
    }

    Context 'AskUserQuestion' {
        It 'returns the answers in updatedInput and keeps the questions' {
            $question = 'Qual banco usar?'
            $answer = 'Op' + [char]0x00E7 + [char]0x00E3 + 'o B'
            $questions = @(@{ question = $question; header = 'Banco'; multiSelect = $false
                    options = @(@{ label = 'A'; description = 'a' }, @{ label = 'B'; description = 'b' }) })
            $run = Start-Hook $box (New-HookEvent 'PreToolUse' $box.Data @{ tool_name = 'AskUserQuestion'; tool_input = @{ questions = $questions } })
            $req = Wait-HookRequest $box
            $req.kind | Should -Be 'question'
            $req.description | Should -BeExactly $question
            Send-WidgetResponse $box $req.id @{ decision = 'answer'; answers = @{ $question = $answer } }
            $r = Complete-Hook $run
            $r.Stdout | Should -Not -Match '[^\x00-\x7F]'
            $out = ($r.Stdout | ConvertFrom-Json).hookSpecificOutput
            $out.hookEventName | Should -Be 'PreToolUse'
            $out.permissionDecision | Should -Be 'allow'
            $out.permissionDecisionReason | Should -BeExactly $pt.answeredReason
            $out.updatedInput.answers.$question | Should -BeExactly $answer
            $out.updatedInput.questions[0].question | Should -BeExactly $question
        }
        It 'ignores PreToolUse for other tools' {
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'PreToolUse' $box.Data @{ tool_name = 'Bash'; tool_input = @{ command = 'ls' } }))
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*').Count | Should -Be 0
        }
    }

    Context 'finished notices' {
        It 'Stop creates a notice and the next prompt removes it, printing nothing' {
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'Pronto: **testes** passaram. Veja [o log](http://x/y).' }
            $sid = $stop.session_id
            $r = Complete-Hook (Start-Hook $box $stop)
            $r.Stdout | Should -BeNullOrEmpty
            $notices = Get-QueueFiles $box "done-$sid-*.json"
            $notices.Count | Should -Be 1
            $notice = [IO.File]::ReadAllText($notices[0].FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $notice.message | Should -BeExactly 'Pronto: testes passaram. Veja o log.'
            $notice.cwd | Should -BeExactly $box.Data

            $prompt = New-HookEvent 'UserPromptSubmit' $box.Data @{ prompt = 'next' }
            $prompt.session_id = $sid
            $r2 = Complete-Hook (Start-Hook $box $prompt)
            $r2.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box "done-$sid-*.json").Count | Should -Be 0
        }
        It 'Stop and PermissionRequest carry the session title' {
            $transcript = Join-Path $box.Data 'transcript.jsonl'
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok'; transcript_path = $transcript }
            [IO.File]::WriteAllText($transcript, ('{"type":"ai-title","aiTitle":"Fix the login","sessionId":"' + $stop.session_id + '"}' + "`n"))
            [void](Complete-Hook (Start-Hook $box $stop))
            $notice = (Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0]
            ([IO.File]::ReadAllText($notice.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).title | Should -BeExactly 'Fix the login'

            $perm = New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'Bash'; tool_input = @{ command = 'ls' }; transcript_path = $transcript }
            $perm.session_id = $stop.session_id
            $run = Start-Hook $box $perm
            $req = Wait-HookRequest $box
            $req.title | Should -BeExactly 'Fix the login'
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            [void](Complete-Hook $run)
        }
        It 'Stop stores the question of the Claude app and its answer buttons' {
            $transcript = Join-Path $box.Data 'transcript-ask.jsonl'
            $wrap = @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = 't1'; name = 'mcp__ccd_turn__wrap_up'
                            input = @{ recap = 'r'; ask = 'Push it?'; actions = @(@{ label = 'Yes, push'; message = 'push' }) } }) } } | ConvertTo-Json -Depth 8 -Compress
            [IO.File]::WriteAllText($transcript, ('{"type":"user","message":{"role":"user","content":"go"}}' + "`n" + $wrap + "`n"))
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok'; transcript_path = $transcript }
            [void](Complete-Hook (Start-Hook $box $stop))
            $notice = [IO.File]::ReadAllText((Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0].FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $notice.message | Should -BeExactly 'Push it?'
            $notice.question | Should -BeTrue
            # (one answer is still a list)
            , $notice.choices | Should -BeOfType [object[]]
            $notice.choices | Should -Be @('Yes, push')
        }
        It 'UserPromptSubmit marks the session as working and Stop clears it' {
            $prompt = New-HookEvent 'UserPromptSubmit' $box.Data @{ prompt = 'go' }
            [void](Complete-Hook (Start-Hook $box $prompt))
            $busyFile = Join-Path $box.Data "busy\$($prompt.session_id).json"
            $busyFile | Should -Exist
            # The prompt may have remembered the window in front (the one running this test): then Stop
            # would see you watching and write no notice
            Remove-Item -LiteralPath (Join-Path $box.Data "sessions\$($prompt.session_id).json") -Force -ErrorAction SilentlyContinue
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok' }
            $stop.session_id = $prompt.session_id
            [void](Complete-Hook (Start-Hook $box $stop))
            $busyFile | Should -Not -Exist
            $notice = (Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0]
            ([IO.File]::ReadAllText($notice.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).allDone | Should -BeFalse
        }
        It 'Stop marks "all done" when it ends a round of several sessions' {
            $busy = Join-Path $box.Data 'busy'
            New-Item -ItemType Directory -Force -Path $busy | Out-Null
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok' }
            Write-JsonAtomic (Join-Path $box.Data 'busy-round.json') @{ sessions = @('other', $stop.session_id) }
            Write-JsonAtomic (Join-Path $busy "$($stop.session_id).json") @{ pid = $PID; since = Get-NowMs }
            [void](Complete-Hook (Start-Hook $box $stop))
            $notice = (Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0]
            ([IO.File]::ReadAllText($notice.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).allDone | Should -BeTrue
        }
        It 'Stop does not mark "all done" while another session is working' {
            $busy = Join-Path $box.Data 'busy'
            New-Item -ItemType Directory -Force -Path $busy | Out-Null
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok' }
            Write-JsonAtomic (Join-Path $box.Data 'busy-round.json') @{ sessions = @('other', $stop.session_id) }
            Write-JsonAtomic (Join-Path $busy 'other.json') @{ pid = $PID; since = Get-NowMs }
            [void](Complete-Hook (Start-Hook $box $stop))
            $notice = (Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0]
            $json = [IO.File]::ReadAllText($notice.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $json.PSObject.Properties.Name | Should -Contain 'allDone'
            $json.allDone | Should -BeFalse
            Join-Path $busy 'other.json' | Should -Exist
        }
    }

    Context 'do not disturb' {
        BeforeEach { Set-Dnd $box.Data $true }
        It 'sends permission requests straight to VS Code' {
            $evt = New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'Bash'; tool_input = @{ command = 'ls' } }
            $r = Complete-Hook (Start-Hook $box $evt)
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*.json').Count | Should -Be 0
        }
        It 'sends questions straight to VS Code' {
            $evt = New-HookEvent 'PreToolUse' $box.Data @{ tool_name = 'AskUserQuestion'; tool_input = @{ questions = @(@{ question = 'Q?'; header = 'Q'; multiSelect = $false; options = @(@{ label = 'A'; description = '' }) }) } }
            $r = Complete-Hook (Start-Hook $box $evt)
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*.json').Count | Should -Be 0
        }
        It 'still writes the finished notice' {
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok' }
            [void](Complete-Hook (Start-Hook $box $stop))
            (Get-QueueFiles $box "done-$($stop.session_id)-*.json").Count | Should -Be 1
        }
        It 'gives up waiting when the mode is turned on while a request is pending' {
            Set-Dnd $box.Data $false
            $evt = New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'Bash'; tool_input = @{ command = 'ls' } }
            $run = Start-Hook $box $evt
            [void](Wait-HookRequest $box)
            Set-Dnd $box.Data $true
            $r = Complete-Hook $run 20
            $r.Stdout | Should -BeNullOrEmpty
            $run.Clock.Elapsed.TotalSeconds | Should -BeLessThan 15
        }
    }

    # After a plugin update the old widget keeps running from the old folder; the hook finds it through
    # the shared mutex name and widget.json, and replaces it. The test keeps holding the mutex, so the
    # widget the hook starts in its place finds the mutex taken and exits at once (no window).
    Context 'widget from another version' {
        BeforeEach {
            $fake = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120'
        }
        AfterEach {
            if (-not $fake.HasExited) { $fake.Kill() }
        }

        It 'replaces a widget started from another script path' {
            Write-JsonAtomic (Join-Path $box.Data 'widget.json') @{ pid = $fake.Id; script = 'C:\old\1.1.0\scripts\widget.ps1' }
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'SessionStart' $box.Data @{ source = 'startup' }))
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            $fake.WaitForExit(5000) | Should -BeTrue
            [IO.File]::ReadAllText((Join-Path $box.Data 'hook.log')) | Should -Match 'restarting widget from an older version'
            # The widget started in its place sees the mutex still taken (by the test) and steps aside
            Wait-SandboxWidgetsExit $box | Should -BeTrue
        }
        It 'asks the old widget to quit before killing it' {
            # A stand-in that leaves by itself (exit code 0) when quit.flag appears; a kill would give -1
            $flag = Join-Path $box.Data 'quit.flag'
            $polite = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command',
                ('$f = ''{0}''; $end = (Get-Date).AddSeconds(60); while ((Get-Date) -lt $end) {{ if (Test-Path -LiteralPath $f) {{ exit 0 }}; Start-Sleep -Milliseconds 100 }}; exit 5' -f $flag)
            try {
                Write-JsonAtomic (Join-Path $box.Data 'widget.json') @{ pid = $polite.Id; script = 'C:\old\1.1.0\scripts\widget.ps1' }
                $r = Complete-Hook (Start-Hook $box (New-HookEvent 'SessionStart' $box.Data @{ source = 'startup' }))
                $r.ExitCode | Should -Be 0
                $polite.WaitForExit(10000) | Should -BeTrue
                $polite.ExitCode | Should -Be 0
                $flag | Should -Not -Exist
                Wait-SandboxWidgetsExit $box | Should -BeTrue
            }
            finally { if (-not $polite.HasExited) { $polite.Kill() } }
        }
        It 'keeps a widget that is newer than this version (an old session must not downgrade it)' {
            Write-JsonAtomic (Join-Path $box.Data 'widget.json') @{ pid = $fake.Id; script = 'C:\new\99.0.0\scripts\widget.ps1' }
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'SessionStart' $box.Data @{ source = 'startup' }))
            $r.Stdout | Should -BeNullOrEmpty
            $fake.HasExited | Should -BeFalse
            [IO.File]::ReadAllText((Join-Path $box.Data 'hook.log')) | Should -Not -Match 'restarting'
        }
        It 'keeps a widget started from this version' {
            $current = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $box.Hook) 'widget.ps1'))
            Write-JsonAtomic (Join-Path $box.Data 'widget.json') @{ pid = $fake.Id; script = $current }
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'SessionStart' $box.Data @{ source = 'startup' }))
            $r.Stdout | Should -BeNullOrEmpty
            $fake.HasExited | Should -BeFalse
            [IO.File]::ReadAllText((Join-Path $box.Data 'hook.log')) | Should -Not -Match 'restarting'
        }
    }

    Context 'Telegram alerts' {
        BeforeAll {
            # Always an array (the comma keeps a single entry from being unwrapped)
            function Read-QueueJson($Sandbox, [string]$Filter) {
                return , @(Get-QueueFiles $Sandbox $Filter | ForEach-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json })
            }
            function New-BashEvent($Sandbox, [string]$Command) {
                New-HookEvent 'PermissionRequest' $Sandbox.Data @{ tool_name = 'Bash'; tool_input = @{ command = $Command } }
            }
            function New-QuestionEvent($Sandbox) {
                New-HookEvent 'PreToolUse' $Sandbox.Data @{ tool_name = 'AskUserQuestion'
                    tool_input = @{ questions = @(@{ question = 'Which DB?'; header = 'DB'; multiSelect = $false; options = @(@{ label = 'A'; description = '' }) }) } }
            }
        }
        BeforeEach {
            # Connected (the hook only checks that the file exists; the token is fake) and alerts on
            [void](Save-TelegramConfig $box.Data '123:fake-test-token' '42' 'testbot' 'Tester')
            [IO.File]::WriteAllText((Join-Path $box.Data 'prefs.json'), '{"telegram":true,"notifyAfter":1}')
        }

        It 'the request timeout follows closeAfter, not notifyAfter (<close> -> <secs>, no countdown <never>)' -ForEach @(
            @{ close = 3; secs = 180; never = $false }, @{ close = 0; secs = 3600; never = $true }) {
            [IO.File]::WriteAllText((Join-Path $box.Data 'prefs.json'), ('{"telegram":true,"notifyAfter":1,"closeAfter":' + $close + '}'))
            $evt = New-BashEvent $box 'npm test'
            $run = Start-Hook $box $evt
            $req = Wait-HookRequest $box
            $req.timeout | Should -Be $secs
            $req.noCountdown | Should -BeOfType [bool]
            $req.noCountdown | Should -Be $never
            $req.session | Should -BeExactly $evt.session_id
            Send-WidgetResponse $box $req.id @{ decision = 'allow' }
            [void](Complete-Hook $run)
        }
        It 'the request timeout is the default 5 minutes with a countdown, also without Telegram' {
            Remove-TelegramConfig $box.Data
            [IO.File]::WriteAllText((Join-Path $box.Data 'prefs.json'), '{}')
            $run = Start-Hook $box (New-QuestionEvent $box)
            $req = Wait-HookRequest $box
            $req.timeout | Should -Be 300
            $req.PSObject.Properties.Name | Should -Contain 'noCountdown'
            $req.noCountdown | Should -BeFalse
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            [void](Complete-Hook $run)
        }
        It 'alerts at notifyAfter while you are present and keeps the card until you answer' {
            $evt = New-BashEvent $box 'npm test'
            $run = Start-Hook $box $evt -Env @{ CLAUDE_WIDGET_WAIT_SECS = '30'; CLAUDE_WIDGET_ALERT_SECS = '1' }
            $req = Wait-HookRequest $box
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline -and (Get-QueueFiles $box 'tg-*.json').Count -eq 0) { Start-Sleep -Milliseconds 100 }
            $tg = Read-QueueJson $box 'tg-*.json'
            $tg.Count | Should -Be 1
            $tg[0].reason | Should -BeExactly 'unanswered'
            $tg[0].session | Should -BeExactly $evt.session_id
            $tg[0].detail | Should -BeExactly 'Bash: npm test'
            (Read-QueueJson $box "alerted-$($evt.session_id).json").Count | Should -Be 1
            # The card is still there and can still be answered
            Start-Sleep -Seconds 2
            $run.Process.HasExited | Should -BeFalse
            Join-Path $box.Queue "req-$($req.id).json" | Should -Exist
            Send-WidgetResponse $box $req.id @{ decision = 'allow' }
            $r = Complete-Hook $run
            ($r.Stdout | ConvertFrom-Json).hookSpecificOutput.decision.behavior | Should -BeExactly 'allow'
            (Get-QueueFiles $box 'tg-*.json').Count | Should -Be 1
        }
        It 'a request alerted at notifyAfter is not alerted again when it closes' {
            $evt = New-QuestionEvent $box
            $r = Complete-Hook (Start-Hook $box $evt -Env @{ CLAUDE_WIDGET_WAIT_SECS = '4'; CLAUDE_WIDGET_ALERT_SECS = '1' })
            $r.Stdout | Should -BeNullOrEmpty
            $r.Seconds | Should -BeGreaterThan 3.5
            $tg = Read-QueueJson $box 'tg-*.json'
            $tg.Count | Should -Be 1
            $tg[0].reason | Should -BeExactly 'unanswered'
            $tg[0].kind | Should -BeExactly 'question'
            (Get-QueueFiles $box 'wait-*.json').Count | Should -Be 0
        }
        It 'a request handed to VS Code after its alert gets no wait marker' {
            $evt = New-BashEvent $box 'npm test'
            $run = Start-Hook $box $evt -Env @{ CLAUDE_WIDGET_WAIT_SECS = '30'; CLAUDE_WIDGET_ALERT_SECS = '1' }
            $req = Wait-HookRequest $box
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline -and (Get-QueueFiles $box 'tg-*.json').Count -eq 0) { Start-Sleep -Milliseconds 100 }
            (Get-QueueFiles $box 'tg-*.json').Count | Should -Be 1
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            [void](Complete-Hook $run)
            (Get-QueueFiles $box 'wait-*.json').Count | Should -Be 0
            (Get-QueueFiles $box 'tg-*.json').Count | Should -Be 1
        }
        It 'writes an outbox entry when a request times out' {
            $evt = New-BashEvent $box 'npm test'
            $r = Complete-Hook (Start-Hook $box $evt -Env @{ CLAUDE_WIDGET_WAIT_SECS = '2' })
            $r.Stdout | Should -BeNullOrEmpty
            $tg = Read-QueueJson $box 'tg-*.json'
            $tg.Count | Should -Be 1
            $tg[0].reason | Should -BeExactly 'timeout'
            $tg[0].kind | Should -BeExactly 'permission'
            $tg[0].session | Should -BeExactly $evt.session_id
            $tg[0].cwd | Should -BeExactly $box.Data
            $tg[0].detail | Should -BeExactly 'Bash: npm test'
            (Get-QueueFiles $box 'wait-*.json').Count | Should -Be 0
            (Read-QueueJson $box "alerted-$($evt.session_id).json")[0].session | Should -BeExactly $evt.session_id
        }
        It 'writes an outbox entry when a question times out' {
            $evt = New-QuestionEvent $box
            [void](Complete-Hook (Start-Hook $box $evt -Env @{ CLAUDE_WIDGET_WAIT_SECS = '2' }))
            $tg = Read-QueueJson $box 'tg-*.json'
            $tg.Count | Should -Be 1
            $tg[0].kind | Should -BeExactly 'question'
            $tg[0].detail | Should -BeExactly 'Which DB?'
        }
        It 'writes an outbox entry with reason away when the user is away' {
            $evt = New-BashEvent $box 'npm test'
            $r = Complete-Hook (Start-Hook $box $evt -Env @{ CLAUDE_WIDGET_AWAY_SECS = '0' })
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*.json').Count | Should -Be 0
            $tg = Read-QueueJson $box 'tg-*.json'
            $tg.Count | Should -Be 1
            $tg[0].reason | Should -BeExactly 'away'
            $tg[0].session | Should -BeExactly $evt.session_id
        }
        It 'writes no alert when the request is answered in the widget' {
            $run = Start-Hook $box (New-BashEvent $box 'npm test')
            $req = Wait-HookRequest $box
            Send-WidgetResponse $box $req.id @{ decision = 'allow' }
            [void](Complete-Hook $run)
            (Get-QueueFiles $box 'tg-*.json').Count | Should -Be 0
            (Get-QueueFiles $box 'wait-*.json').Count | Should -Be 0
        }
        It 'writes a wait marker when the widget hands the request to VS Code' {
            $evt = New-BashEvent $box 'npm test'
            $run = Start-Hook $box $evt
            $req = Wait-HookRequest $box
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            [void](Complete-Hook $run)
            $wait = Read-QueueJson $box "wait-$($evt.session_id).json"
            $wait.Count | Should -Be 1
            $wait[0].kind | Should -BeExactly 'permission'
            $wait[0].detail | Should -BeExactly 'Bash: npm test'
            (Get-QueueFiles $box 'tg-*.json').Count | Should -Be 0
        }
        It 'writes a wait marker when do not disturb skips the widget while you are present' {
            Set-Dnd $box.Data $true
            $evt = New-BashEvent $box 'npm test'
            [void](Complete-Hook (Start-Hook $box $evt))
            (Read-QueueJson $box "wait-$($evt.session_id).json").Count | Should -Be 1
            (Get-QueueFiles $box 'tg-*.json').Count | Should -Be 0
        }
        It 'writes a wait marker for ExitPlanMode' {
            $evt = New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'ExitPlanMode'; tool_input = @{ plan = '## Plan: fix the **login**' } }
            $r = Complete-Hook (Start-Hook $box $evt)
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*.json').Count | Should -Be 0
            $wait = Read-QueueJson $box "wait-$($evt.session_id).json"
            $wait.Count | Should -Be 1
            $wait[0].kind | Should -BeExactly 'plan'
            $wait[0].detail | Should -BeExactly 'Plan: fix the login'
        }
        It 'writes a wait marker on a Notification permission prompt' {
            $evt = New-HookEvent 'Notification' $box.Data @{ notification_type = 'permission_prompt'; message = 'Claude needs your permission to use Bash'; title = 'Permission needed' }
            $r = Complete-Hook (Start-Hook $box $evt)
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            $wait = Read-QueueJson $box "wait-$($evt.session_id).json"
            $wait.Count | Should -Be 1
            $wait[0].kind | Should -BeExactly 'permission'
            $wait[0].detail | Should -BeExactly 'Claude needs your permission to use Bash'
        }
        It 'ignores the idle Notification and leaves the session unstamped' {
            $evt = New-HookEvent 'Notification' $box.Data @{ notification_type = 'idle_prompt'; message = 'Claude is waiting for your input' }
            $r = Complete-Hook (Start-Hook $box $evt)
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box).Count | Should -Be 0
        }
        It 'writes no wait marker on a Notification while the widget holds a request of that session' {
            $perm = New-BashEvent $box 'npm test'
            $run = Start-Hook $box $perm
            $req = Wait-HookRequest $box
            $note = New-HookEvent 'Notification' $box.Data @{ notification_type = 'permission_prompt'; message = 'Claude needs your permission to use Bash' }
            $note.session_id = $perm.session_id
            [void](Complete-Hook (Start-Hook $box $note))
            (Get-QueueFiles $box 'wait-*.json').Count | Should -Be 0
            Send-WidgetResponse $box $req.id @{ decision = 'allow' }
            [void](Complete-Hook $run)
        }
        It 'a Notification keeps the plan marker already there' {
            $plan = New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'ExitPlanMode'; tool_input = @{ plan = 'x' } }
            [void](Complete-Hook (Start-Hook $box $plan))
            $before = (Read-QueueJson $box "wait-$($plan.session_id).json")[0]
            $note = New-HookEvent 'Notification' $box.Data @{ notification_type = 'permission_prompt'; message = 'Claude needs your permission' }
            $note.session_id = $plan.session_id
            [void](Complete-Hook (Start-Hook $box $note))
            $after = (Read-QueueJson $box "wait-$($plan.session_id).json")[0]
            $after.kind | Should -BeExactly 'plan'
            $after.created | Should -Be $before.created
        }
        It 'a Notification right after an away alert writes no second marker; one after the session moved on does' {
            $perm = New-BashEvent $box 'npm test'
            $sid = $perm.session_id
            [void](Complete-Hook (Start-Hook $box $perm -Env @{ CLAUDE_WIDGET_AWAY_SECS = '0' }))
            (Get-QueueFiles $box 'tg-*.json').Count | Should -Be 1
            $note = New-HookEvent 'Notification' $box.Data @{ notification_type = 'permission_prompt'; message = 'Claude needs your permission to use Bash' }
            $note.session_id = $sid
            [void](Complete-Hook (Start-Hook $box $note))
            Join-Path $box.Queue "wait-$sid.json" | Should -Not -Exist
            $prompt = New-HookEvent 'UserPromptSubmit' $box.Data @{ prompt = 'go' }
            $prompt.session_id = $sid
            [void](Complete-Hook (Start-Hook $box $prompt))
            [void](Complete-Hook (Start-Hook $box $note))
            Join-Path $box.Queue "wait-$sid.json" | Should -Exist
        }
        It 'a Notification writes no marker when the session moved on after it started' {
            $note = New-HookEvent 'Notification' $box.Data @{ notification_type = 'permission_prompt'; message = 'm' }
            New-Item -ItemType Directory -Force -Path $box.Queue | Out-Null
            # Stands in for the next event's seen stamp landing while this async hook is still running
            Write-JsonAtomic (Join-Path $box.Queue "seen-$($note.session_id).json") @{ session = $note.session_id; at = (Get-NowMs) + 60000 }
            [void](Complete-Hook (Start-Hook $box $note))
            Join-Path $box.Queue "wait-$($note.session_id).json" | Should -Not -Exist
        }
        It 'writes no Telegram file for an event without a session id' {
            $events = @(
                @{ Event = (New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'ExitPlanMode'; tool_input = @{ plan = 'x' } }); Env = @{} },
                @{ Event = (New-BashEvent $box 'ls'); Env = @{ CLAUDE_WIDGET_AWAY_SECS = '0' } },
                @{ Event = (New-QuestionEvent $box); Env = @{ CLAUDE_WIDGET_AWAY_SECS = '0' } },
                @{ Event = (New-HookEvent 'Notification' $box.Data @{ notification_type = 'permission_prompt'; message = 'm' }); Env = @{} })
            foreach ($e in $events) {
                $e.Event.Remove('session_id')
                $r = Complete-Hook (Start-Hook $box $e.Event -Env $e.Env)
                $r.ExitCode | Should -Be 0
            }
            Set-Dnd $box.Data $true
            $dnd = New-BashEvent $box 'ls'; $dnd.Remove('session_id')
            [void](Complete-Hook (Start-Hook $box $dnd))
            (Get-QueueFiles $box).Count | Should -Be 0
        }
        It 'the next event of the session removes its wait marker and stamps seen' {
            $plan = New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'ExitPlanMode'; tool_input = @{ plan = 'x' } }
            [void](Complete-Hook (Start-Hook $box $plan))
            Join-Path $box.Queue "wait-$($plan.session_id).json" | Should -Exist
            $prompt = New-HookEvent 'UserPromptSubmit' $box.Data @{ prompt = 'go' }
            $prompt.session_id = $plan.session_id
            [void](Complete-Hook (Start-Hook $box $prompt))
            Join-Path $box.Queue "wait-$($plan.session_id).json" | Should -Not -Exist
            $seen = Read-QueueJson $box "seen-$($plan.session_id).json"
            $seen.Count | Should -Be 1
            $seen[0].session | Should -BeExactly $plan.session_id
        }
        It 'writes nothing Telegram-related when Telegram is not connected' {
            Remove-TelegramConfig $box.Data
            $sid = 'test-notconnected'
            $events = @(
                (New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'ExitPlanMode'; tool_input = @{ plan = 'x' } }),
                (New-HookEvent 'Notification' $box.Data @{ notification_type = 'permission_prompt'; message = 'm' }),
                (New-HookEvent 'UserPromptSubmit' $box.Data @{ prompt = 'go' }))
            foreach ($e in $events) { $e.session_id = $sid; [void](Complete-Hook (Start-Hook $box $e)) }
            $away = New-BashEvent $box 'ls'; $away.session_id = $sid
            [void](Complete-Hook (Start-Hook $box $away -Env @{ CLAUDE_WIDGET_AWAY_SECS = '0' }))
            $late = New-BashEvent $box 'ls'; $late.session_id = $sid
            [void](Complete-Hook (Start-Hook $box $late -Env @{ CLAUDE_WIDGET_WAIT_SECS = '2' }))
            (Get-QueueFiles $box 'tg-*').Count | Should -Be 0
            (Get-QueueFiles $box 'wait-*').Count | Should -Be 0
            (Get-QueueFiles $box 'seen-*').Count | Should -Be 0
        }
        It 'writes nothing Telegram-related when alerts are off' {
            [IO.File]::WriteAllText((Join-Path $box.Data 'prefs.json'), '{"telegram":false,"notifyAfter":1}')
            $evt = New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'ExitPlanMode'; tool_input = @{ plan = 'x' } }
            [void](Complete-Hook (Start-Hook $box $evt))
            (Get-QueueFiles $box).Count | Should -Be 0
        }
    }

    Context 'finished notice of a Claude desktop app session' {
        BeforeAll {
            if (-not ('CcwTest.Desk' -as [type])) {
                Add-Type -Namespace CcwTest -Name Desk -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();'
            }
        }
        It 'Stop stores desktopApp, also without Telegram' {
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok' }
            # A window that always exists stands in for the Claude desktop app's window
            New-Item -ItemType Directory -Force -Path (Join-Path $box.Data 'sessions') | Out-Null
            Write-JsonAtomic (Join-Path $box.Data "sessions\$($stop.session_id).json") @{ hwnd = [CcwTest.Desk]::GetDesktopWindow().ToInt64(); kind = 'other'; process = 'claude.exe' }
            [void](Complete-Hook (Start-Hook $box $stop))
            $notice = (Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0]
            ([IO.File]::ReadAllText($notice.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).desktopApp | Should -BeTrue
        }
        It 'Stop stores desktopApp false for other sessions' {
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok' }
            [void](Complete-Hook (Start-Hook $box $stop))
            $json = [IO.File]::ReadAllText((Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0].FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $json.PSObject.Properties.Name | Should -Contain 'desktopApp'
            $json.desktopApp | Should -BeFalse
        }
    }

    Context 'robustness' {
        It 'SessionStart prints nothing' {
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'SessionStart' $box.Data @{ source = 'startup' }))
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
        It '-EnsureWidget prints nothing when the widget is running' {
            $r = Complete-Hook (Start-Hook $box $null -Arguments @('-EnsureWidget') -RawInput '')
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            $r.Seconds | Should -BeLessThan 15
        }
        It 'exits quietly on input that is not JSON' {
            $r = Complete-Hook (Start-Hook $box $null -RawInput 'not json')
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
        It 'exits quietly on empty input' {
            $r = Complete-Hook (Start-Hook $box $null -RawInput '')
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
    }
}
