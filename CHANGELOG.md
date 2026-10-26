# Changelog

## 2.7.0 (2026-10-25)

- **Telegram alerts (optional).** Connect from the right-click menu (**Telegram → Connect Telegram…**): a 3-step setup card inside the widget. You create a bot with BotFather, paste its token and press Start in your bot; the widget finds your chat by itself with a one-time code (without Telegram on the PC, the card shows the `/start` message to send from your phone). The token is saved in `telegram.json`, encrypted with Windows DPAPI for your Windows user. **Alerts on**, **Alert after** (1, 3 or 5 minutes), **Send test** and **Disconnect** are in the same submenu.
- **When it alerts.** A request or a question nobody answers for **Alert after**; a request that skips the widget because you are away, or a card on screen when you go away; a "finished" notice still open at **Alert after** (Claude desktop app sessions only if you are away at that moment; a notice that stays open longer does not alert later); and requests waiting in VS Code (plan approval, **Decide in VS Code**, do not disturb, widget not running) that waited **Alert after** while you are away. With "do not disturb" on, Telegram only fires when you are away. Turning **Alerts on** never sends what was queued while they were off. Alerts that fall within a few seconds go in one message, and a message is edited to "resolved" when the session moves on.
- **Close automatically.** New menu: 1, 3, 5 (default), 15, 30 minutes or **Never**, for cards and for "finished" notices. Never keeps a card until you answer, you go away or 60 minutes pass, and a notice until you close it or look at its window (12 hours at most); it shows no countdown. At **Alert after** a card that is still there stays if you are at the computer, and goes back to VS Code if you are away, so Remote Control can answer it. The `PermissionRequest` and `PreToolUse` hooks wait up to 3630 seconds (was 330).
- **A "finished" notice closes when you look at it**: when you bring its session's window to the front (not for Claude desktop app sessions, where one window holds every session).
- **New `Notification` hook** (async, prints nothing; only for permission and question prompts). It tells the widget that a session waits in VS Code, for the Telegram alerts.
- **Network.** Without Telegram connected there is still no network use. With it, only `telegram.ps1` talks to the network, only to `api.telegram.org`, and the hook never does. `prefs.json` also holds `closeAfter`, `notifyAfter` and `telegram`.
- **Fix: the `CLAUDE_WIDGET_*` variables in the `env` block of `~/.claude/settings.json` now reach the widget.** The hook starts the widget through WMI, which does not pass its environment on, so a widget started that way never saw them (reproduced with the hotkey setting). The widget now reads that block itself when it starts.
- **Fix: the right-click menu closes when you click elsewhere.**

## 2.6.0 (2026-10-25)

- **"Finished" notices stack.** One box per notice, newest on top (up to 4; the last one counts the rest), each with its own **✕**, **OK** and "go to" button. New boxes unfold and closed ones fold away, so the boxes below slide instead of jumping.
- **Notices close by themselves after 5 minutes** (was 12 hours), with a ring next to the ✕ that empties until then.
- **Notices also show with the Claude desktop app.** Its single window holds every session, so being in front no longer hides a session's notice.
- **"Question for you".** When a turn ends with a question in the Claude desktop app's "next step" box, the notice shows that question instead of the start of the reply (read from the end of the transcript, which takes a few tens of milliseconds even on long sessions).
- **The widget keeps its top edge.** Cards and notices grow downwards from where you put it (upwards only when they would not fit), and it always stays inside one monitor. Dragging works across monitors; the saved spot (`state.json`) now also has `top`.
- **Away after 5 minutes** without mouse or keyboard input (was 2), before requests and questions skip the widget. `CLAUDE_WIDGET_AWAY_SECS` still overrides it.
- **Spanish.** `CLAUDE_WIDGET_LANG=es`, or a Windows display language in Spanish.
- **Minecraft theme removed**, and with it the only network use (the Mojang download). A `prefs.json` that says `minecraft` falls back to the dark theme.

## 2.5.4 (2026-10-13)

- Internal: `widget.ps1` is 400 lines shorter. The window layout moved to `widget.xaml` and the Win32 helper code to `widget-native.cs`, both loaded by `widget.ps1` at start. No change in behavior.

## 2.5.3 (2026-10-13)

- The diff no longer shows an extra empty line when the text ends with a newline, and says when the hook left out edits (it keeps 5).
- The hotkey for "do not disturb" always reads the current state; the idle pill tooltip is not replaced while it is open; session ages go to hours after 60 minutes; sound scheme entries given as a bare file name are found in the Windows Media folder.
- README: hotkey variables need a restart, AltGr note, what the local destination means, and "do not disturb" keeps the widget hidden.

## 2.5.2 (2026-10-13)

- Small fixes: `prefs.json` is saved whole-file-at-once and a failed save is logged; a sound file Windows cannot play is logged; the README lists the `prefs.json` fields.

## 2.5.1 (2026-10-13)

- **Bigger XP orb in the Minecraft theme.** The status dot was a tiny speck because the orb picture has a transparent margin; the margin is now cropped and the dot is 14 px.

## 2.5.0 (2026-10-13)

- **Minecraft theme.** Pick it in the Theme menu: square corners, a dirt frame with a strip of grass, XP orbs for the status dots, and Minecraft sounds (request, finished, all done). The first click downloads about 4 MB of textures and sounds from Mojang's servers into the plugin data folder (nothing from Mojang is in this repository); the theme switches on when the download ends. It is the only part of the widget that uses the internet.
- The README screenshots are now always drawn with the default look, whatever your `prefs.json` says.

## 2.4.1 (2026-10-08)

- **An old session no longer downgrades the widget.** After a plugin update, a Claude Code session still running the previous version used to replace the new widget with its own old one (at its next "finished" notice). The hook now replaces a running widget only when that widget is older than the hook's own version.

## 2.4.0 (2026-10-08)

- **Look and sound from the right-click menu.** Theme (dark, light, or automatic like Windows), opacity (100-60%), volume (mute to 100%), size (100/125/150%) and a minimal idle pill (only the colored dot; the status becomes a tooltip). Each choice applies at once and is saved in `prefs.json`.
- The volume applies to the request, finished and all-done sounds. If Windows cannot play a sound file, the widget uses the system sound, which ignores the volume (Mute still silences it).

## 2.3.0 (2026-10-08)

- **Diff on the card.** The permission card of an `Edit`, `MultiEdit` or `Write` shows what changes: removed lines in red, added lines in green (up to 14 lines).
- **Always allow.** The permission card offers buttons that approve and also save one of the rules Claude Code itself suggests, showing the rule and where it is saved (this session, this project, all projects...). Only rules that allow, the modes below "bypass permissions" and folders are offered; the widget never saves anything Claude Code did not suggest.
- **Global hotkeys (off by default).** Set `CLAUDE_WIDGET_HOTKEYS=1` to approve (`Ctrl+Alt+Y`), deny (`Ctrl+Alt+N`) and toggle "do not disturb" (`Ctrl+Alt+D`) from any window. Change the keys with `CLAUDE_WIDGET_KEY_APPROVE`, `CLAUDE_WIDGET_KEY_DENY` and `CLAUDE_WIDGET_KEY_DND`.

## 2.2.1 (2026-10-08)

- **No ghost tray icons after an update.** When a plugin update replaces the running widget, the hook now asks the old one to close itself (it removes its own tray icon) and only kills it if it has not left after 4 seconds. Before, every update left a dead icon in the tray until you hovered over it.
- Internal: setting `CLAUDE_WIDGET_NO_TRAY=1` starts the widget without a tray icon; the test suite uses it so that running the tests no longer fills the tray with ghost icons.

## 2.2.0 (2026-10-08)

- **Tray icon and "do not disturb".** A tray icon (orange while active, grey in "do not disturb") toggles the mode with a left click; its menu has **Do not disturb** and **Close widget**. In the mode, permission requests and questions go straight to VS Code, the widget hides, and "finished" notices wait silently until you turn the mode off. The mode stays on until you turn it off, even after a restart. If the icon is in the hidden-icons area, drag it onto the taskbar once.
- **Sessions list.** The idle pill says how many sessions are working. Click it to see each one: project, session title and how long it has been working (orange when a request from that project is waiting).
- Long session titles are cut without splitting an emoji.

## 2.1.0 (2026-10-08)

- **Session title on the cards.** Next to the project, the cards show the session's title: the name you gave it with `/rename`, or the one Claude Code picked. Two sessions in the same project are easy to tell apart.
- **"All done" sound.** When several sessions were working and the last one finishes, its notice plays a different sound (Windows' "tada").
- **Double-click to go back.** Double-click the widget (outside its buttons) to bring back the session's window: the finished session on a "finished" notice, otherwise the session you typed in last.

## 2.0.1 (2026-10-07)

- **Monitor changes.** If the widget's monitor is unplugged while the widget is open, the widget moves to the main screen's corner within a couple of seconds, and goes back to where you put it once that monitor is back. A saved position between monitors of different sizes no longer opens the widget off screen.
- **VS Code windows are matched by the whole project name.** A project called `widget` no longer matches the `claude-code-widget` window, or a `widget.ps1` file open in another project. The "finished" notice is no longer skipped by mistake, and **Go to VS Code** brings the right window.
- `widget.log` is capped like `hook.log`: past 256 KB it moves to `widget.log.old`.

## 2.0.0 (2026-10-07)

- **Renamed to `opaiva-code-widget`.** Claude Code 2.1.292 and later reserve plugin names that start with `claude-` for Anthropic's own plugins. Install with `claude plugin install opaiva-code-widget@claude-code-widget`. The marketplace keeps its name and maps the old name to the new one, so once it is updated the old plugin stops loading and Claude Code moves your settings to the new name. If you have the old `claude-code-widget` plugin, follow [Renamed in 2.0.0](README.md#renamed-in-200): uninstall it first, and reload any open sessions. After the switch the widget starts in the default corner.

## 1.1.1 (2026-10-07)

- Internal: the hook and the widget now share their common code (`common.ps1`), and an automated test suite (Pester 5) runs on every push and pull request in GitHub Actions. No behavior change.

## 1.1.0 (2026-10-01)

- **Terminal sessions.** When you send a message, the widget remembers the window you typed in: VS Code, Windows Terminal, PowerShell or cmd. It checks the process tree to confirm the window belongs to that Claude Code session. The "finished" notice is skipped while that window is in front, and its button becomes **Go to terminal** and brings that exact window back. Before, both only knew about VS Code windows.
- Prompts sent from your phone (Remote Control) leave an unrelated window in front, so they don't change the remembered window.

## 1.0.0 (2026-10-01)

- First release: permission requests, multiple-choice questions and "finished" notices in an always-on-top widget that never takes focus. UI in English and Portuguese.
