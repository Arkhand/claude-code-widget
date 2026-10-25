# Telegram Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The widget sends a Telegram message only when Daniel did not respond within 1/3/5 minutes (or is away), set up entirely from the widget menu, so `mcp-notify` can be retired (version 2.7.0).

**Architecture:** The hook never touches the network. It writes small files in the queue folder: an outbox entry when it gives up on a request, a "waiting in VS Code" marker when a request waits in Claude Code's own prompt, and a "seen" stamp on every session event. The widget decides what is due through one pure function (`Get-DueAlerts`, in `common.ps1`), batches it and sends it from a background runspace through `telegram.ps1`, the only file with network code. Setup is a 3-step card in the widget; the token is saved with DPAPI.

**Tech Stack:** Windows PowerShell 5.1, WPF, Pester 6.2 (`tools\test.ps1`), Telegram Bot API over HTTPS.

**Spec:** `docs/superpowers/specs/2026-10-25-telegram-alerts-design.md` (read it first; this plan does not repeat the "why").

## Global Constraints

- Every `.ps1` stays ASCII-only; all new UI text goes in `strings.json` under `pt`, `en` and `es`.
- Network code only in `plugins/opaiva-code-widget/scripts/telegram.ps1`, and only to `https://api.telegram.org/` (tests pass a localhost base URL as a parameter).
- The hook never makes a network call and never waits on one; `Stop`, `UserPromptSubmit`, `SessionStart` and `Notification` print nothing.
- The widget UI thread never waits on the network: every API call runs in a background runspace with a 10 s timeout.
- Files another process reads are written with `Write-JsonAtomic`.
- Nothing Telegram-related is written (outbox, markers, stamps) unless Telegram is ready (connected **and** `prefs.telegram`): someone who never connects sees no change besides the two general fixes in Tasks 2 and 8.
- The token is never written in clear, logged, or put in a message or on a command line.
- `notifyAfter` ∈ {1, 3, 5} minutes, default 5; `telegram` bool, default false.
- Telegram message text: plain (no `parse_mode`), at most 4096 characters.
- Git: work on branch `feat/telegram-alerts`. Daniel's rule: no commit or push without his explicit OK. The "Commit" steps below are checkpoints; run them only once he has authorized commits for this branch.
- Version 2.7.0: `plugin.json` and the top `CHANGELOG.md` entry must match (repo test).

## Review Focus

1. **Accents and emoji in messages.** PowerShell 5.1 `Invoke-RestMethod` with a string body does not send UTF-8 by default; "acción ✅" must arrive intact. Test in Task 4.
2. **Double send.** A widget restart, two ticks, or two widgets right after a plugin update must not send the same alert twice: an alert is recorded as sent before the call goes out. Test in Task 7.
3. **Telegram down, slow, or the user blocked the bot.** No UI freeze, no hook delay, one retry at most, a log line without the token, the alert dropped after 30 min. Tests in Tasks 4 and 7.
4. **Many items at once.** Ten sessions finishing together must give one message under 4096 characters, not ten messages and not a rejected one. Test in Task 5.
5. **Token pasted with spaces, a newline or quotes.** The wizard trims it and `getMe` decides; a bad token stays on step 1 with an error. Test in Task 9.

---

### Task 1: Preferences `notifyAfter` and `telegram`

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/common.ps1` (`Get-DefaultPrefs`, `Read-Prefs`, `Save-Prefs`, ~357-403)
- Test: `tests/common.Tests.ps1` (existing `Read-Prefs` / `Save-Prefs` describes)

**Interfaces:**
- Produces: `$prefs.notifyAfter` ([int] 1|3|5) and `$prefs.telegram` ([bool]) in every hashtable `Read-Prefs` returns; `Save-Prefs` writes both.

- [ ] **Step 1: Write the failing tests** in the `Read-Prefs` describe:
  - `It 'defaults notifyAfter to 5 and telegram to false'`: no file → `notifyAfter | Should -Be 5`, `telegram | Should -BeFalse`.
  - `It 'keeps notifyAfter 1, 3 and 5' -ForEach @(1,3,5)`: file `{"notifyAfter":<n>}` → `Should -Be <n>`.
  - `It 'falls back to 5 for notifyAfter <v>' -ForEach @(0, 2, 10, 'x', $true)`.
  - `It 'reads telegram true'`, and `'ignores a non-bool telegram'` (`"yes"` → false).
  - In `Save-Prefs`: `It 'round-trips notifyAfter and telegram'`.
- [ ] **Step 2: Run** `powershell -NoProfile -File tools\test.ps1 -ExcludeTag Desktop` → the new tests FAIL.
- [ ] **Step 3: Implement.** Defaults `notifyAfter = 5; telegram = $false`. `notifyAfter` is kept only when it is a number exactly equal to 1, 3 or 5 (not the nearest choice, unlike `scale`). `telegram` only when `-is [bool]`.
- [ ] **Step 4: Run the suite** → PASS (the existing ones too).
- [ ] **Step 5: Commit** `feat(prefs): notifyAfter and telegram preferences`

### Task 2: The widget reads `CLAUDE_WIDGET_*` from `settings.json` (bug fix)

**Files:**
- Modify: `common.ps1` (new function), `widget.ps1` (param block; hotkey block ~1155-1170; new `$AwaySecs`)
- Test: `tests/common.Tests.ps1`, `tests/widget.Tests.ps1` (Desktop)

**Interfaces:**
- Produces: `Get-ClaudeSettingsEnv([string]$Path) -> [hashtable]` (the `env` object of a settings file as string values; empty on a missing file, bad JSON or no `env`). In `widget.ps1`: param `[string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json')`, function `Get-WidgetEnv([string]$Name) -> [string]` (settings value first, then `[Environment]::GetEnvironmentVariable($Name)`, else `''`), and `$AwaySecs` ([int], from `CLAUDE_WIDGET_AWAY_SECS`, default 300), used by Task 7.

- [ ] **Step 1: Reproduce the bug first.** In `widget.Tests.ps1`, `It 'a widget started through WMI sees the hotkey setting'`: write a temp settings file with `{"env":{"CLAUDE_WIDGET_HOTKEYS":"1"}}`, start the widget the way `Start-Widget` does (`Invoke-CimMethod Win32_Process Create`, `-DataDir <tmp>`, `-SettingsPath <tmp file>`), wait for the mutex, and assert the hotkey registration is visible (use the log line the hotkey block writes, or add one: `hotkeys: registered N`). Then run the same test with the variable set only in the test process's environment and no `-SettingsPath` entry → expect no registration. Record both results in the task report; this is the evidence for the changelog line.
- [ ] **Step 2: Unit tests** for `Get-ClaudeSettingsEnv`: missing file → `@{}`; `{"env":{"A":"1","B":2}}` → `A='1'`, `B='2'`; invalid JSON → `@{}`; no `env` key → `@{}`.
- [ ] **Step 3: Run** → FAIL.
- [ ] **Step 4: Implement** `Get-ClaudeSettingsEnv` (read as UTF-8 without BOM, never throws), `Get-WidgetEnv`, and switch every `$env:CLAUDE_WIDGET_*` read in `widget.ps1` to `Get-WidgetEnv`, except `CLAUDE_WIDGET_NO_TRAY` (tests set it in the process environment). The settings file is read once at start.
- [ ] **Step 5: Run** the Desktop test and the unit tests → PASS.
- [ ] **Step 6: Commit** `fix(widget): read CLAUDE_WIDGET_* settings from settings.json (WMI start drops the env)`

### Task 3: Telegram connection storage (DPAPI)

**Files:**
- Modify: `common.ps1` (new section "Telegram connection (telegram.json)")
- Test: `tests/common.Tests.ps1`

**Interfaces:**
- Produces:
  - `Save-TelegramConfig([string]$Dir, [string]$Token, [string]$Chat, [string]$Bot, [string]$Name) -> [bool]`: writes `telegram.json` with `token` encrypted by `ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString` (DPAPI, current user, no key), `chat`, `bot` (username without `@`), `name` (chat first name), atomically.
  - `Read-TelegramConfig([string]$Dir) -> $null | @{ token; chat; bot; name }` (decrypted token; `$null` on a missing, broken or undecryptable file).
  - `Remove-TelegramConfig([string]$Dir)`.
  - `Test-TelegramReady([string]$Dir, $Prefs) -> [bool]`: `telegram.json` exists **and** `$Prefs.telegram`. Does not decrypt (the hook calls it on every event).

- [ ] **Step 1: Failing tests:** round trip returns the same token/chat/bot/name; `It 'never stores the token in clear'`: the file text does not contain the token; missing file → `$null`; a file whose `token` was encrypted by another user (simulate with garbage in `token`) → `$null`; `Test-TelegramReady` is false without the file, false with the file and `telegram=$false`, true with both.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(telegram): DPAPI-protected connection file`

### Task 4: `telegram.ps1`, the Bot API client, and a fake Bot API for tests

**Files:**
- Create: `plugins/opaiva-code-widget/scripts/telegram.ps1`
- Create: `tests/helpers/FakeTelegram.ps1` (same shape as the old `FakeMojang.ps1`: `git show 102f145:tests/helpers/FakeMojang.ps1`; `HttpListener` on `http://127.0.0.1:<random port>/` in a background runspace)
- Create: `tests/telegram.Tests.ps1`

**Interfaces:**
- Produces (all take `[string]$BaseUrl = 'https://api.telegram.org'` and `[int]$TimeoutSec = 10`, run off the UI thread, and throw a `TelegramError` with `.Status` [int] and `.Description` [string] on failure; the message never contains the token):
  - `Invoke-TelegramApi([string]$Token, [string]$Method, [hashtable]$Body) -> result object`. POST to `$BaseUrl/bot$Token/$Method`, body JSON sent as **UTF-8 bytes** with `Content-Type: application/json; charset=utf-8`; TLS 1.2 enabled first; an `ok:false` reply becomes a `TelegramError`.
  - `Get-TelegramBot([string]$Token) -> @{ id; username; first_name }` (`getMe`).
  - `Send-TelegramText([string]$Token, [string]$Chat, [string]$Text) -> [int64] message_id` (`sendMessage`, no `parse_mode`, `disable_web_page_preview = $true`).
  - `Edit-TelegramText([string]$Token, [string]$Chat, [int64]$MessageId, [string]$Text)` (`editMessageText`).
  - `Find-TelegramStart([string]$Token, [string]$Code, [int64]$Offset, [int]$WaitSec) -> $null | @{ chat; name; offset }`: `getUpdates` long poll (`timeout = $WaitSec`); returns the first `message` whose text is exactly `/start <Code>`; `offset` is the next update id to ask for, so the caller can poll again.
- FakeTelegram: `Start-FakeTelegram -> @{ Url; Requests (synchronized list of @{ method; body(string) }); Replies (synchronized hashtable method -> JSON text or @{ status; body; delayMs }) }`, `Stop-FakeTelegram($fake)`.

- [ ] **Step 1: Failing tests** in `tests/telegram.Tests.ps1` (dot-source `telegram.ps1`, start the fake in `BeforeAll`):
  - `'sends the text as UTF-8'`: `Send-TelegramText` with `"acción ✅ ñ"` → the fake's recorded body, decoded as UTF-8, contains it; returns the fake's `message_id`.
  - `'throws TelegramError with status and description on ok:false'`: reply `{"ok":false,"error_code":401,"description":"Unauthorized"}` with status 401 → `Status = 401`, `Description = 'Unauthorized'`, and the exception text does not contain the token.
  - `'times out'`: reply delayed 3 s, `-TimeoutSec 1` → throws within 2 s.
  - `'Find-TelegramStart ignores other messages and returns the chat of /start <code>'`: updates `"/start wrong"`, `"hola"`, `"/start abc123"` (chat 42, first_name "Daniel") → `@{ chat = '42'; name = 'Daniel'; offset = <last id + 1> }`.
  - `'Find-TelegramStart returns $null when nothing matches'`.
- [ ] **Step 2: Run** `powershell -NoProfile -File tools\test.ps1 -ExcludeTag Desktop` → FAIL.
- [ ] **Step 3: Implement** `telegram.ps1` (ASCII-only file, header comment saying it is the only network file) and `FakeTelegram.ps1`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(telegram): Bot API client and a fake Bot API for tests`

### Task 5: Alert files and the decision function

**Files:**
- Modify: `common.ps1` (new section "Telegram alerts"), `strings.json` (alert text keys)
- Test: `tests/common.Tests.ps1`

**Interfaces:**
- Produces:
  - File shapes in the queue folder (all via `Write-JsonAtomic`):
    - `tg-<id>.json` outbox entry, written by the hook: `{ id, kind: 'permission'|'question', session, cwd, title, detail, reason: 'timeout'|'idle'|'away', created }`.
    - `wait-<session>.json` marker: `{ session, kind: 'permission'|'question'|'plan', cwd, title, detail, created }` (one per session, newest wins).
    - `seen-<session>.json` stamp: `{ session, at }`.
  - `Add-AlertOutbox([string]$Queue, [hashtable]$Item) -> id`, `Set-WaitMarker([string]$Queue, [hashtable]$Item)`, `Set-SessionSeen([string]$Queue, [string]$Session)` (writes the stamp **and** removes `wait-<session>.json`).
  - `Get-DueAlerts($Outbox, $Notices, $Waits, $Sent, [int64]$NowMs, [int64]$AfterMs, [bool]$Away, [bool]$Dnd) -> list of @{ key; kind; session; cwd; title; text-source fields }`, a pure function with the spec's "When a message is sent" table as its contract:
    - each outbox entry is due at once (key `req:<id>`), dropped (not returned) if older than 30 min;
    - a notice is due when `NowMs - created >= AfterMs`; if `desktopApp` or `$Dnd`, also only when `$Away` (key `done:<notice key>`);
    - a wait marker is due when `NowMs - created >= AfterMs` **and** `$Away` (key `wait:<session>:<created>`);
    - nothing whose key is already in `$Sent`.
  - `Format-AlertText($Alerts, $S) -> [string]`: one block per alert (header by kind, `Format-SessionLine` of cwd/title, detail cut to 200 characters), blocks separated by a blank line, total cut to 4096 characters with a final "… +N more" line when items are left out.
  - `Read-SentAlerts([string]$Dir) -> [hashtable]` / `Save-SentAlerts([string]$Dir, [hashtable]$Sent)`: `telegram-sent.json`, key -> `@{ message; session; at; resolved }`; entries older than 24 h are dropped on read.
  - New `strings.json` keys (en text given; write pt and es): `tgPermission` "🔔 Permission waiting", `tgQuestion` "❓ Question waiting", `tgDone` "✅ Finished", `tgPlan` "📋 Plan waiting for approval", `tgMore` "… +{0} more", `tgResolved` "✅ resolved", `tgTest` "Test from Claude Code Widget: alerts work.".

- [ ] **Step 1: Failing tests,** one `It` per row of the spec's table, e.g. `'a notice of a desktop app session is due at X only when away'`, `'a wait marker is not due while present'`, `'with DND a notice is due only when away'`, `'an outbox entry older than 30 min is dropped'`, `'nothing already sent is returned'`; and `'Format-AlertText keeps 10 long items under 4096 characters and says how many were left out'`; `'Set-SessionSeen removes the wait marker'`; `'Read-SentAlerts drops entries older than 24 h'`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(telegram): alert files and the due-alert decision`

### Task 6: Hook integration and the `Notification` hook

**Files:**
- Modify: `hook.ps1` (`Wait-Response`/`New-Request` timeout, `Invoke-Hook` branches ~479-600), `hooks/hooks.json`
- Test: `tests/hook.Tests.ps1`, `tests/hook.e2e.Tests.ps1`

**Interfaces:**
- Consumes: `Read-Prefs`, `Test-TelegramReady` (Task 1, 3), `Add-AlertOutbox`, `Set-WaitMarker`, `Set-SessionSeen` (Task 5).
- Produces: request files whose `timeout` is `notifyAfter * 60`; done notices with a new field `desktopApp` ([bool], the existing `$inDesktopApp`); the queue files of Task 5.

Behavior to wire (only when `Test-TelegramReady`, except the timeout and `desktopApp`, which always apply):
- Every event with a session id calls `Set-SessionSeen` first (before any new marker is written for it).
- `PermissionRequest` / question: timeout from prefs. `waitEnd` `timeout` or `idle` → `Add-AlertOutbox` with `reason` = `waitEnd`. Away skip → `Start-Widget`, then `Add-AlertOutbox` (`reason = 'away'`). Decision `vscode`, DND skip while present, and widget did not start → `Set-WaitMarker`. `ExitPlanMode` → `Set-WaitMarker` with `kind = 'plan'`, then the normal flow (still never routed to the widget).
- New `Notification` event: if its type is a permission or answer prompt and no `req-*.json` of that session is pending → `Set-WaitMarker`; any other type → nothing. **Before coding, check the `Notification` payload (field names, `notification_type` values) against the current Claude Code hooks documentation** and pin them in a comment; ignore the idle "waiting for your input" type.
- `hooks.json`: add `Notification`, `async: true`, same command as the others.

- [ ] **Step 1: Failing tests (e2e, `HookHarness.ps1` sandbox with a `telegram.json` and `prefs.json {"telegram":true,"notifyAfter":1}`):**
  - `'the request timeout follows notifyAfter'` (the request file has `timeout = 60`).
  - `'writes an outbox entry when a request times out'` (use a short timeout override for the test, e.g. `notifyAfter` 1 plus waiting ~62 s is too slow: add a test-only `CLAUDE_WIDGET_WAIT_SECS` env override in `hook.ps1`, documented as tests only).
  - `'writes an outbox entry with reason away when the user is away'` (`CLAUDE_WIDGET_AWAY_SECS = '0'`).
  - `'writes a wait marker when the widget hands the request to VS Code'`, `'... for ExitPlanMode'`, `'... on a Notification permission prompt'`.
  - `'the next event of the session removes its wait marker and stamps seen'`.
  - `'writes nothing Telegram-related when Telegram is not connected'`.
  - `'Stop stores desktopApp'` (unit test on the notice fields if the e2e cannot fake `claude.exe`).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** the full non-Desktop suite → PASS.
- [ ] **Step 5: Commit** `feat(hook): queue Telegram alerts, waiting-in-VS-Code markers and the Notification hook`

### Task 7: Widget sender (background, batched, sent once, resolved edits)

**Files:**
- Modify: `widget.ps1` (dot-source `telegram.ps1`; new section "Telegram alerts"; timer tick ~1286-1305)
- Test: `tests/widget.Tests.ps1` (Desktop) with `FakeTelegram.ps1`

**Interfaces:**
- Consumes: Tasks 2-5. New widget param `[string]$TelegramUrl = 'https://api.telegram.org'` (tests only).
- Produces: `Start-TelegramCall([string]$Function, [object[]]$Arguments) -> @{ ps; handle; started }` (a `[powershell]` with its own runspace that dot-sources `telegram.ps1` and calls the function with `-BaseUrl $TelegramUrl`), polled each tick; `Update-Alerts` called every 5 ticks **before** `Update-View` (so it runs in DND too).

`Update-Alerts`, in order: skip if not ready or a call is still running; read outbox, notices (`Get-Done`), wait markers, sent state; `Get-DueAlerts` with `Away = idle >= $AwaySecs` (reuse the `GetLastInputInfo` approach of `hook.ps1`'s `Get-IdleSeconds`, moved to `common.ps1` so both share it) and `Dnd = Test-Dnd`; collect for ~5 s from the first due item, then **record the keys in `telegram-sent.json` before sending**; send one `Send-TelegramText` with `Format-AlertText`; on success store the message id under each key and delete the outbox files; on failure retry once on the next round, then log `telegram: <status> <description>` and leave the keys marked so they never resend. Resolved: for each sent, unresolved key whose session has a `seen-<session>.json` newer than `at`, or whose notice was closed in the widget, call `Edit-TelegramText` with the original text plus `tgResolved` and mark it resolved.

- [ ] **Step 1: Failing Desktop tests** (widget started with `-TelegramUrl <fake>`, a sandbox `telegram.json` and `prefs.json {"telegram":true,"notifyAfter":1}`):
  - `'sends one batched message for two outbox entries'` (fake records exactly 1 `sendMessage` containing both details).
  - `'does not send the same alert again after a restart'` (kill and restart the widget; still 1 `sendMessage`).
  - `'sends nothing while present for a wait marker, and sends once when away'` (`CLAUDE_WIDGET_AWAY_SECS` via the sandbox settings file: `0` for the away case).
  - `'edits the message to resolved when the session is seen again'` (write `seen-<session>.json` → 1 `editMessageText`).
  - `'keeps the UI responsive while Telegram does not answer'` (fake delays 15 s; the widget still answers a request card within 2 s).
  - `'logs a failed send without the token'` (fake returns 403 twice; `widget.log` has `telegram: 403`, does not contain the token; no third call).
- [ ] **Step 2: Run** `powershell -NoProfile -File tools\test.ps1` → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(widget): send Telegram alerts in the background`

### Task 8: A finished notice closes when its session window comes to the front

**Files:**
- Modify: `common.ps1` (pure helper), `widget.ps1` (call it in the tick)
- Test: `tests/common.Tests.ps1`

**Interfaces:**
- Produces: `Get-NoticesInFront($Notices, [int64]$ForegroundHwnd) -> [string[]]` (keys of notices with `hwnd -eq $ForegroundHwnd`, `hwnd -ne 0`, and not `desktopApp`). The widget closes those through the same path as the OK button (`Close-DoneNotice $key`, bypassing `Test-ClickTooSoon`), using `[ClaudeWidget.WinFocus]::Foreground()`. Applies with or without Telegram.

- [ ] **Step 1: Failing tests:** matching hwnd → its key; hwnd 0 → none; `desktopApp = $true` → none; two notices on the same window (two tabs of one Windows Terminal) → both keys.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (helper + one call in the tick, before `Update-Alerts`). **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(widget): close a finished notice when you look at its session`

### Task 9: Menu, setup wizard, test message, disconnect

**Files:**
- Modify: `widget.xaml` (new panel `PanelTelegram`), `widget.ps1` (menu ~1033-1080, `Set-Panel`, `Update-View` priority), `strings.json`
- Test: `tests/widget.Tests.ps1` (Desktop), `tools/samples.json` + `-RenderSamples` (one PNG per wizard step, not committed to `docs/images`)

**Interfaces:**
- Consumes: Tasks 1, 3, 4, 7 (`Start-TelegramCall`).
- Produces: menu items per the spec ("Menu" section) and a wizard with states `token` → `start` → `done`.

Pinned details:
- **Wait for answer ▸** via `Add-ChoiceMenu` (`key = 'notifyAfter'`, values 1, 3, 5) plus a disabled caption item; **Telegram ▸** rebuilt on `SubmenuOpened` from `Read-TelegramConfig`.
- Wizard step 1: `Enable-Typing` on the token box; **Open BotFather** = `Start-Process 'https://t.me/BotFather'`; **Next** trims spaces, newlines and quotes, runs `Get-TelegramBot` in the background; error → message under the box, stay. Step 2: code = 16 random hex characters; **Open my bot** = `Start-Process "https://t.me/<bot>?start=<code>"`; poll `Find-TelegramStart` (`WaitSec` 20) in the background until found or **Cancel**. Step 3: `Save-TelegramConfig`, `Set-Pref 'telegram' $true`, `Send-TelegramText` with `tgTest`, show the connected text with the current `notifyAfter`. Cancel or closing at any step saves nothing. `Disable-Typing` when leaving step 1.
- `Update-View` priority: request card > wizard > notices > idle; while a request is on screen the wizard waits and comes back after.
- **Send test** shows the result for ~3 s in the pill tooltip area (OK, or bad token / blocked / no network from the `TelegramError` status). **Disconnect** = `Remove-TelegramConfig` + `Set-Pref 'telegram' $false`.
- New `strings.json` keys (en given; write pt and es), e.g. `menuWait` "Wait for answer", `waitCaption` "After that, the request goes back to VS Code and, if connected, you get a Telegram alert.", `menuTelegram` "Telegram", `tgConnect` "Connect Telegram…", `tgConnectCaption`, `tgAlertsOn` "Alerts on", `tgSendTest` "Send test", `tgDisconnect` "Disconnect", `tgConnectedTo` "Connected to @{0}", plus the wizard texts from the mockup (steps 1-3, errors: bad token, webhook set, no network).

- [ ] **Step 1: Failing Desktop tests** against the fake: `'menu shows Connect when not connected'`, `'menu shows the connected items with the bot name'`, `'a pasted token with spaces and a newline is trimmed and accepted'`, `'a bad token stays on step 1 with an error'`, `'/start with the wrong code does not connect; the right one saves telegram.json and sends a test message'`, `'cancel saves nothing'`, `'disconnect removes telegram.json'`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS, and render the wizard PNGs; check them by eye in dark and light themes.
- [ ] **Step 5: Commit** `feat(widget): Telegram menu and setup wizard`

### Task 10: Repo rules, docs, version

**Files:**
- Modify: `tests/repo.Tests.ps1` (network rule ~139), `README.md`, `README.pt-BR.md` (and `README.es.md` if it exists by then), `CHANGELOG.md`, `plugins/opaiva-code-widget/.claude-plugin/plugin.json`

- [ ] **Step 1: Update the repo test** `'the plugin scripts make no network calls'` → `'only telegram.ps1 makes network calls, and only to api.telegram.org'`: the pattern search excludes `telegram.ps1`; in `telegram.ps1` every `https?://` literal starts with `https://api.telegram.org`. (`https://t.me/` links are opened with `Start-Process` in `widget.ps1`; allow `t.me` in `widget.ps1` explicitly in the test.)
- [ ] **Step 2: Docs:** README "Telegram alerts" section (connect from the menu, the 1/3/5 rule, what triggers an alert, DND rule, finished notice closes when you look at its window), Settings table note that `CLAUDE_WIDGET_*` in `settings.json` now reach the widget, Security section (network only when Telegram is connected, only `api.telegram.org`, token encrypted for your Windows user), "How it works" files list (`telegram.json`, `telegram-sent.json`, `tg-*`, `wait-*`, `seen-*`). CHANGELOG `## 2.7.0 (<date>)`; `plugin.json` `"version": "2.7.0"`.
- [ ] **Step 3: Run** the full suite (`tools\test.ps1`) and `claude plugin validate .` and `claude plugin validate plugins/opaiva-code-widget` → all PASS.
- [ ] **Step 4: Commit** `docs: release 2.7.0 (Telegram alerts)`

### Task 11: Retire mcp-notify (Daniel's config, after he tried 2.7.0)

Not code in this repo. Only with Daniel's explicit confirmation of this exact list:
- [ ] Daniel connects his bot with the wizard and sees a real alert.
- [ ] Remove the two `notify-cli.js` hooks (`Stop`, `Notification`) from `~/.claude/settings.json`.
- [ ] Remove the `notify` MCP server from `~/.claude.json`.
- [ ] Remove `~/.claude/commands/notify-*.md` (6 files).
- [ ] Deprecation note at the top of `~/tools/mcp-notify/README.md` pointing to the widget; commit/push to `Arkhand/mcp-notify` only when he asks.
