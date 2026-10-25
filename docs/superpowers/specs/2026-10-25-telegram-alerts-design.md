# Telegram alerts (replaces mcp-notify)

Date: 2026-10-25 · Target version: 2.7.0 · Status: approved directions, waiting for Daniel's read

## Intent

Daniel keeps a separate tool, `mcp-notify` (`~/tools/mcp-notify`, repo `Arkhand/mcp-notify`, Node + TypeScript), that sends a Telegram message on every `Stop` and every `Notification` hook. It pings the phone even when he is sitting at the desk and already saw the widget. The goal is one tool: the widget decides when he really missed something and only then sends a Telegram message. Afterwards `mcp-notify` is retired.

The rule in one line: **"if I don't respond within X minutes, find me on the phone."**

## Goals

- A permission request or a question that waits unanswered in the widget for X minutes sends one Telegram message **and** is handed back to Claude Code at that same moment, so Remote Control on the phone can answer it (the widget holding it would block the phone).
- A "finished" notice that is still open after X minutes sends one Telegram message. The notice itself stays until its usual 5 minutes (nothing to hand back).
- X is 1, 3 or 5 minutes, picked in the right-click menu. Telegram on/off is in the same menu. Both are saved in `prefs.json`.
- Away from the computer (no input for `CLAUDE_WIDGET_AWAY_SECS`, default 300): a request or question sends its Telegram message right away, when the hook skips the widget or when it gives up a card already on screen because of idle.
- Requests that end up waiting in VS Code instead of the widget (plan approval, "Decide in VS Code", "do not disturb", widget not running) also reach the phone if they are still waiting X minutes later and you are away. Today mcp-notify covers these through the `Notification` hook; retiring it must not lose them.
- Everything lives in this repo. No Node, no second process type.

## Non-goals

- Approving, denying or answering from Telegram. Remote Control already does that; a second approval channel over the internet is a security risk.
- WhatsApp. `mcp-notify` supports it through whatsapp-web.js (Node + Chrome), which cannot be done from PowerShell 5.1. Daniel uses Telegram.
- Per-folder mutes (`/notify-off*` commands). "Do not disturb" and the Telegram toggle cover it.
- The MCP tool `notify_question` (Claude calling a tool to notify). It goes away with `mcp-notify`.

## Anti-goals (a failure even if it technically works)

- A phone ping for something Daniel already saw or answered at the desk.
- Several messages in a burst for one moment (several queued requests, several sessions finishing together).
- The widget UI freezing, or a hook (and so Claude Code) waiting on the network.
- The Telegram token in the repo, in `prefs.json`, in clear on disk, in a log or in a message.
- A setup that needs editing a file or knowing what a chat id is.
- Any Telegram traffic, prompt or nag for someone who never connects it (default off). Two general improvements do change behavior for everyone, on purpose: a finished notice closes when you bring its session's window to the front, and the widget reads `CLAUDE_WIDGET_*` variables from `settings.json` (bug fix).

## Decisions taken with Daniel

| Item | Decision |
| --- | --- |
| Channel | Telegram only, Bot API. |
| Delay | Menu choice 1, 3 or 5 minutes. Default 5 (today's card timeout). |
| Timer model | One timer: at X the request goes back to Claude Code **and** the Telegram message is sent. |
| Finished notices | Also alert, only if still open at X. A notice closes by itself when you bring its session's window to the front (you saw it). Claude desktop app sessions (one window for all sessions, so "in front" says nothing): alert only if you are away at X. |
| Waiting in VS Code | Covered too: plan approvals and requests handed to VS Code alert if still waiting at X and you are away (new `Notification` hook). |
| Repo | Everything in this repo; `mcp-notify` is deprecated afterwards. |
| "Do not disturb" | Does not turn Telegram off (it silences the widget, not the phone). See the DND rule below. |
| Spam | Batch messages that fall in the same moment; edit a sent message to "resolved" when the session moves on. |
| Setup | Entirely from the widget menu, for someone who knows nothing about bots: a 3-step **Connect Telegram** wizard inside the widget. No file or variable to edit by hand. |
| Menu | Top level **Wait for answer ▸** 1/3/5 min. **Telegram ▸** shows **Connect Telegram…** when not connected; once connected: **Alerts on** (check), **Send test**, **Disconnect**, and a caption with the bot name. |
| Card | No Telegram label on the card: it keeps today's countdown only (Daniel: "dejá el timer nomás"). |

## Behavior

### Delay and the card timeout

`prefs.json` gets `notifyAfter` (minutes: 1, 3 or 5; default 5) and `telegram` (bool, default false).

`notifyAfter` is the time the widget holds a request, whether Telegram is on or off: the hook's wait (`$TimeoutSecs`, today fixed at 300) becomes `notifyAfter * 60`, read from `prefs.json` when the request is created. The request file's `timeout` field already carries it to the widget, so the countdown and the orphan cleanup in `Get-PendingRequests` follow without other changes. Default 5 keeps today's behavior. With Telegram off the menu item still changes how long the card waits; hence the label **Wait for answer**.

Each queued request counts from its own creation, as today, even before it is on screen.

### When a message is sent

| Situation | Telegram |
| --- | --- |
| Request/question answered in the widget in time | none |
| "Decide/Answer in VS Code" clicked | none now; becomes a "waiting in VS Code" item (see below) |
| Request/question reaches X unanswered (`waitEnd = timeout`) | yes, at X |
| Card on screen and you go idle (`waitEnd = idle`) | yes, at that moment |
| Hook skips the widget because you are away | yes, right away |
| Hook skips the widget because of "do not disturb", you are not away | none now; becomes a "waiting in VS Code" item |
| Widget did not start | none now; becomes a "waiting in VS Code" item |
| Session ended | none |
| Plan approval (`ExitPlanMode`), never shown in the widget | becomes a "waiting in VS Code" item |
| "Waiting in VS Code" item still waiting at X **and** you are away | yes |
| Finished notice still open at X (VS Code / terminal session, or no known window) | yes, at X |
| Finished notice of a Claude desktop app session still open at X | only if you are away at that moment |
| You bring the session's window to the front before X | the notice closes: none |
| Finished notice closed, or a new prompt in that session, before X | none |
| "Do not disturb" on and a finished notice reaches X | only if you are away at that moment |
| Telegram not connected, or alerts off | none, ever |

DND rule in short: with "do not disturb" on, Telegram fires only when you are away. *(My call: DND + present means you are at the desk on purpose without the widget; pinging the phone for every request would be the exact spam this replaces.)*

### Waiting in VS Code

Some requests wait in Claude Code's own prompt instead of the widget: plan approval (`ExitPlanMode`, never routed to the widget), a card handed over with **Decide/Answer in VS Code**, requests skipped because of "do not disturb" while you are present, and requests the widget could not take (did not start). Today mcp-notify alerts on them through the `Notification` hook. The widget keeps covering them, with the same "find me" rule:

- The hook writes a small "waiting in VS Code" marker for the session (in the data folder, `Write-JsonAtomic`) when it hands a request over or skips the widget for those reasons, and for `ExitPlanMode`.
- The plugin also registers the **`Notification`** hook (async, prints nothing). When Claude Code reports it is waiting for a permission or an answer and the widget is not holding a request for that session, the hook writes the same marker. That catches prompts the other paths miss. *(Builder: check the `Notification` payload fields and its notification types against the current Claude Code hooks docs before relying on them; ignore the "idle, waiting for your input" type, which the finished notice already covers.)*
- The widget sends the alert when a marker is at least X old **and** you are away. Any later hook event of that session clears the marker (and edits a sent alert to resolved).

### Finished notice closes when you look at it

Each tick the widget compares the foreground window with the windows of the open notices (`hwnd` is stored in each notice). When a notice's session window comes to the front, the notice closes (as if you clicked OK), so a reply you already read never alerts. Windows Terminal is matched per window, as today. Claude desktop app sessions are excluded (one window for every session); their notices alert at X only if you are away. This applies whether Telegram is connected or not.

### Batching

Alerts that become due within a short window (a few seconds; builder picks, around 5 s) go out as one message listing each item. One message per item otherwise. Telegram allows about one message per second per chat; batching also keeps clear of that.

### "Resolved" edit

When a session that was alerted shows activity again (any later hook event of that session: `UserPromptSubmit`, `Stop`, `PermissionRequest`, `PreToolUse` question, or its notice being closed in the widget), the sent message is edited to append a resolved mark ("✅ resolved"), so an old alert on the phone does not look pending. Known limit: if the session's next step needs no permission, the signal only comes at its `Stop`. Message ids older than a day are forgotten. *(This is the lowest-priority part; it can be its own step in the plan.)*

### Message content

Plain text (no `parse_mode`, so nothing needs escaping), in the UI language (`strings.json`, all three languages):

- Header by kind: permission waiting, question waiting, finished.
- Project (folder name) and session title, as `Format-SessionLine` builds them.
- Permission: tool and the detail (command or file path) cut to about 200 characters. Question: the first question's text. Finished: the snippet already stored in the notice (or "question for you" text).
- Batched: one block per item.

Never the token, never full file contents, never the diff.

### Connecting Telegram (setup wizard)

Setup happens entirely in the widget, for someone who has never made a bot. **Telegram ▸ Connect Telegram…** opens a setup card in the widget, in three steps (see the mockup Daniel approved, described here):

1. **Create your bot.** Short instructions (open BotFather, send `/newbot`, pick a name, copy the token), an **Open BotFather** button (opens `https://t.me/BotFather` in the default browser / Telegram app) and a text box to paste the token. **Next** checks it with `getMe`; a bad token shows an inline error and stays on step 1.
2. **Tell your bot it's you.** Shows the bot's `@username` from `getMe`, and an **Open my bot in Telegram** button that opens `https://t.me/<bot>?start=<code>`, where `<code>` is a random one-time code. The widget polls `getUpdates` (long polling, off the UI thread) until it sees `/start <code>`, and takes that message's chat id. Nobody else who messages the bot can get bound, and the user never looks up a chat id. Cancel or close at any point leaves nothing saved.
3. **Connected.** Sends a test message, shows "Connected with <first name>" and the current wait time, **Done** closes the card. Alerts are turned on.

The setup card is the second exception to "the widget never takes focus" (after **Other answer**): it takes focus while the token box needs typing/pasting and gives it back after. If a request arrives during setup, the request has priority (setup resumes after, or is cancelled; builder's call).

**Storage.** Token and chat id are saved in a `telegram.json` in the plugin data folder, the token encrypted with Windows DPAPI for the current user (`ConvertFrom-SecureString` without a key). Never in the repo, `prefs.json`, logs, or any message. **Disconnect** deletes the file. The bot name and chat first name may be stored in clear for the menu caption.

Known setup failure to handle: a bot that already has a webhook set cannot use `getUpdates`; show a clear message (use a new bot).

**Environment variables, separate fix (found in review).** `Start-Widget` creates the widget through WMI (`Win32_Process.Create`) so it outlives the session, and a process created that way does not inherit the hook's environment: a variable set in the calling process arrived empty in the created one. So `CLAUDE_WIDGET_AWAY_SECS` and the hotkey variables, documented as set in the `env` block of `~/.claude/settings.json`, are probably never seen by a widget started by a hook (likely, not yet reproduced with the real widget). Telegram no longer depends on this, but the DND + notice rule needs the same away threshold as the hook. Decision: when it starts, the widget reads the `env` object of `~/.claude/settings.json` itself (read-only, ignoring a missing or invalid file) for every `CLAUDE_WIDGET_*` variable it uses, falling back to its own environment. Confirm the bug with a test first and mention the fix in the changelog. The fake-API base URL for tests is a widget parameter, never read from settings.

### Menu

- New top-level submenu **Wait for answer ▸** 1 minute / 3 minutes / 5 minutes (`notifyAfter`, via `Add-ChoiceMenu`), with a grey caption: after that time the request goes back to VS Code and (if connected) the Telegram alert goes out. It applies with or without Telegram.
- New submenu **Telegram ▸**:
  - not connected: **Connect Telegram…** and a caption ("Alerts on your phone if you don't answer in time").
  - connected: **Alerts on** (check item, `telegram` in `prefs.json`), **Send test** (sends now; shows OK or the error kind: bad token, chat blocked the bot, no network), **Disconnect**, and a caption "Connected to @<bot>".
- Both go before the separator above **Close widget**.

### The card

No Telegram label on the card. The countdown stays exactly as today ("closes in m:ss"); under the one-timer model it already marks the moment the alert goes out.

## Constraints

- **Network in one file only.** A new `scripts/telegram.ps1` (dot-sourced by the widget) is the only file allowed to talk to the network, and only to `https://api.telegram.org`. The repo test "the plugin scripts make no network calls" becomes: no network APIs in any script except `telegram.ps1`, and every URL in `telegram.ps1` starts with `https://api.telegram.org/`. README "Security" and the 2.6.0 statement ("no network use") are updated: no network unless Telegram is turned on, and then only Telegram.
- **The hook never talks to the network.** Hooks must stay fast and `PermissionRequest` is synchronous. The hook only writes a small file (an outbox entry in the queue folder, e.g. `queue\tg-<id>.json`) describing what to send; the widget sends. For the away case the hook calls `Start-Widget` first so a sender exists. *(My call; the file name and format are the builder's.)*
- **The widget UI thread never waits on the network.** Sends run off the UI thread (background runspace or a hidden child process; builder's call), with a timeout of about 10 s. The sender must keep working while the widget is hidden ("do not disturb"): today `Update-View` returns early in DND, so the outbox and the notice-age check cannot live only inside it.
- **TLS 1.2** must be enabled explicitly in Windows PowerShell 5.1 before calling the API.
- **Failures are logged, not retried in a loop.** One retry at most; then a line in `widget.log` (without the token: log the HTTP status and Telegram's `description`). An outbox entry older than, say, 30 minutes is dropped, not sent late.
- **Only one sender.** A notice or request must never be alerted twice (widget restart, two ticks). Mark what was sent (in the outbox entry or in a small state file) before or atomically with sending.
- Existing rules hold: `.ps1` ASCII-only, new UI text in `strings.json` in `pt`, `en`, `es`, sounds only through `Play-Sound`, `Write-JsonAtomic` for files another process reads, hooks print nothing for `Stop`/`UserPromptSubmit`/`SessionStart`.
- `prefs.json`: `Read-Prefs` validates the two new fields like the others (bad value → default), `Save-Prefs` writes them.

## Tests

- `common.Tests.ps1`: `Read-Prefs`/`Save-Prefs` with the new fields (missing, invalid, each valid value).
- `hook.Tests.ps1` / `hook.e2e.Tests.ps1`: request timeout follows `notifyAfter`; outbox entry written on `timeout`, on `idle`, and on the away skip; none on answer or with Telegram off; "waiting in VS Code" marker written on "in VS Code", on DND skip while present, on `ExitPlanMode` and on a `Notification` event, and cleared by the session's next event.
- Widget: a notice closes when its window is brought to the front (except desktop app sessions); marker + away + age X sends once.
- Telegram sender: tested against a fake local Bot API (an `HttpListener` on localhost; the base URL is injectable for tests only, defaulting to `https://api.telegram.org`). Covers send, batch, edit-to-resolved, bad token response, timeout, no double send. Network tests must not reach the real API in CI.
- `repo.Tests.ps1`: the updated network rule.
- Widget: menu shows Connect when not connected and the connected items after; wizard steps against the fake API (bad token, wrong code ignored, right `/start <code>` binds, cancel saves nothing); `telegram.json` token is not readable in clear.

## Release and retiring mcp-notify

1. Version 2.7.0 in `plugin.json` and `CHANGELOG.md`; README (en, pt-BR, and es if it exists by then): a "Telegram alerts" section (connect from the menu, what triggers an alert), updated Security section, and the `settings.json` env fix.
2. After Daniel tried 2.7.0, and with his confirmation of the exact list, in his user config only:
   - Daniel connects his bot himself with the wizard (he can reuse the mcp-notify bot if it has no webhook, or create a new one);
   - remove the two `notify-cli.js` hooks (`Stop`, `Notification`) from `~/.claude/settings.json`;
   - remove the `notify` MCP server registration (`~/.claude.json`);
   - remove `~/.claude/commands/notify-*.md`;
   - add a deprecation note at the top of the `Arkhand/mcp-notify` README pointing to this widget (commit/push only when he asks).

## Left to the builder

Setup card layout details, outbox file format and naming, batching window, how the sender runs off the UI thread, where sent-message ids are kept, exact wording of the strings.
