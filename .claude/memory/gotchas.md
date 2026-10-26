---
name: gotchas
description: Trampas técnicas ya encontradas en este código que no son obvias leyendo una función suelta
metadata:
  type: feedback
---

- **Transcripts grandes:** `Get-Content -Tail` tardó ~25 s sobre un transcript de 2.4 MB. `Get-PendingAsk` lee el final del archivo directo (20-90 ms). No volver a `Get-Content` para leer transcripts en un hook.
- **Variables case-insensitive:** `$data` y `$Data` son la misma; `$Data` es la carpeta de datos. Por eso el evento se llama `$evt`. Cuidado al nombrar variables nuevas.
- **Salida de hooks:** cualquier cosa impresa en `Stop`/`UserPromptSubmit`/`SessionStart` termina en el contexto de Claude. Usar `[void]` / `Out-Null` y `Write-HookLog`.
- **Timeouts encadenados:** hook síncrono 330 s en `hooks.json` vs límite de 5 min del card en el widget; si se cambia uno, revisar el otro.
- **Foco:** el widget nunca toma foco salvo al escribir ("Other answer", token de Telegram: `Enable-Typing`/`Disable-Typing`) y mientras el menú del click derecho está abierto (`Open-MenuFocus`/`Close-MenuFocus`). Los dos comparten `Open-Focus`/`Close-Focus`: el primero guarda la ventana previa, el último devuelve el foco. Cualquier ventana o control nuevo tiene que respetarlo. `Test-ClickTooSoon` (700 ms) evita clicks accidentales al aparecer un card.
- **Menú contextual con WS_EX_NOACTIVATE:** Windows solo da captura de mouse y desactivación a la ventana activa, así que el menú no se cerraba al hacer click afuera (bug de Daniel, 2.7.0). Por eso el widget se activa mientras el menú está abierto. El `Click` de un `MenuItem` llega después de `Closed`: `Close-MenuFocus` corre diferido (prioridad Background).
- **Tests Desktop con UI Automation:** `Find-WidgetElement`/`Invoke-WidgetElement` en `tests/widget.Tests.ps1` manejan menú y botones por nombre o `x:Name`; el menú se abre con un click derecho real (`Open-WidgetMenu`, mueve el mouse).
- **Away:** con 5 min sin input los requests saltean el widget, incluso un card ya en pantalla. Al probar a mano, mover el mouse o subir `CLAUDE_WIDGET_AWAY_SECS`.
- **App de escritorio de Claude:** una sola ventana para todas las sesiones, por eso estar "en frente" no oculta sus notices (a diferencia de VS Code/terminal).
- **Windows Terminal:** la ventana se detecta por ventana, no por pestaña.
- **Tests y tray:** sin `CLAUDE_WIDGET_NO_TRAY=1` cada widget de test deja un ícono fantasma en la bandeja.
- **ExitPlanMode** nunca se rutea al widget (a propósito).

**Why:** cada punto costó tiempo de debugging (al autor original o a Daniel en 2.6.0).
**How to apply:** revisar antes de tocar hook.ps1 o el loop del widget. Ver [[arquitectura]].
