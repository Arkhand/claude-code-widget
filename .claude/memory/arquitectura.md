---
name: arquitectura
description: Cómo fluye un evento de Claude Code hasta el widget y qué archivo/función tocar para cada feature
metadata:
  type: reference
---

## Flujo

```
Claude Code ──hook──▶ hook.ps1 ──queue\req-<id>.json──▶ widget.ps1 (WPF, 1 proceso por usuario)
            ◀─JSON──           ◀──queue\res-<id>.json──
```

- `plugins/opaiva-code-widget/hooks/hooks.json`: 5 eventos, todos llaman al mismo `hook.ps1`.
  - `PermissionRequest` y `PreToolUse(AskUserQuestion)`: síncronos, timeout 330 s; escriben request y esperan respuesta (`Wait-Response`).
  - `SessionStart`, `Stop`, `UserPromptSubmit`: `async: true`, nunca imprimen nada.
- `hook.ps1` → `Invoke-Hook` (≈ línea 479) rutea por `hook_event_name`. Dot-sourcear el archivo solo define funciones (así lo usan los tests).
- `widget.ps1` (≈1330 líneas): loop que pollea la queue; prioridad requests > done notices > pill idle. Layout en `widget.xaml`, Win32 P/Invoke en `widget-native.cs`.
- `common.ps1`: helpers compartidos (mutex, `Write-JsonAtomic`, `Resolve-Lang`/`Get-Strings`, readers de queue, prefs, temas, pantallas, versión).
- `strings.json`: textos UI en `pt`, `en`, `es` (UTF-8).

## Datos en runtime

`%USERPROFILE%\.claude\plugins\data\opaiva-code-widget-claude-code-widget\` (o `$env:CLAUDE_PLUGIN_DATA`):
`queue\` (req/res/done-<session>-<ms>), `sessions\` (ventana por sesión), `busy\` + `busy-round.json`, `dnd.flag`, `quit.flag`, `state.json` (posición, incluye `top`), `prefs.json`, `hook.log` / `widget.log` (256 KB + `.old`).
Primer lugar para diagnosticar: esos dos logs.

## Dónde tocar según feature

| Feature | Dónde |
| --- | --- |
| Card de permiso, diff, Always allow | widget: `Show-Permission`, `Set-ChangeView`, `Set-AlwaysButtons`; hook: `New-ChangeInfo`, `Get-OfferedSuggestions`, `ConvertTo-UpdatedPermission`, `New-PermissionOutput` |
| Preguntas (AskUserQuestion) | widget: `Show-Question`, `Select-Option`, `Submit-Answers`; hook: `New-AnswerOutput` |
| Notices "finished" apiladas | widget: `New-DoneItem`, `Update-DoneItem`, `Start-DoneMotion`, `Show-DoneStack`, `Close-DoneNotice`; hook (Stop): `Get-LastAssistantText`, `Get-PendingAsk`, `Test-UserWatching` |
| Ventana de la sesión / "Go to" | hook: `Save-SessionWindow`, `Get-ProcessTree`, `Get-WindowKind`; widget: `Find-VsCodeWindow`, `Show-LatestSessionWindow` |
| Sesiones trabajando / sonido "all done" | hook: `Set-SessionBusy`, `Complete-SessionBusy`; common: `Get-BusySessions` |
| Posición / monitores / escala | widget: `Sync-Anchor`, `Set-Area`, `Update-Position`, `Update-Fit`; common: `Get-ScreenAreas`, `Resolve-Anchor`, `Get-FitScale` |
| Tema, opacidad, volumen, menú | common: `Read-Prefs`/`Save-Prefs`, `Get-ColorMap`, `Resolve-Theme`; widget: `Set-Pref`, `Add-ChoiceMenu`, `Play-Sound` |
| Away / DND / hotkeys | hook: `Get-IdleSeconds`, `Test-Away`; common: `Test-Dnd`/`Set-Dnd`, `ConvertTo-Hotkey`; widget: `Sync-Dnd`, `Send-HotkeyDecision` |
| Arranque y reemplazo del widget | hook: `Start-Widget`, `Test-Widget`; common: `Get-ScriptVersion`, `Test-WidgetOlder` (solo reemplaza un widget más viejo) |
| Screenshots README | `widget.ps1 -RenderSamples` + `tools/render-screenshots.ps1`, datos en `tools/samples.json` |

Relacionado: [[reglas-codigo]], [[gotchas]].
