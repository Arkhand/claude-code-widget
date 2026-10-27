---
name: estado
description: Estado al 2026-10-27 y pendientes concretos para retomar
metadata:
  type: project
---

Estado al **2026-10-27**:

- **2.8.1 en `main`, pusheada, instalada y corriendo (2026-10-27).** 2.8.1: elegir la sesión en la app de Claude compara el título exacto de cada fila (botón "Más opciones para <título>") y distingue original de copia bifurcada (el registro de una copia arranca con el id de la original); reintenta ~6 s; el log dice el motivo; la lista queda abierta tras el doble click.
- 2.8.0: Antes, 2.7.1 = botón "Abrir Claude" para sesiones de la app de escritorio (no hay link para abrir una sesión existente de Code; todas comparten una ventana).
- Verificado antes de 2.7.0: `tools\test.ps1 -ExcludeTag Desktop` 525/0; `tests\widget.Tests.ps1` (sesión desbloqueada) 42/0; `claude plugin validate` OK. 2.7.1: 528/0.
- **mcp-notify retirado** y pusheado (`Arkhand/mcp-notify`, commits 8ec1f1a y 62d1a75). Respaldo de lo sacado en `~/tools/mcp-notify/retired/`; copias completas de config en `~/.claude/backups/mcp-notify-retired-2026-10-25/`.
- **Cuenta de gh:** la activa por defecto es `dmusialblueboot` (trabajo), que no tiene permiso en los repos de Arkhand. Para pushear acá: `gh auth switch --user Arkhand` y después volver.
- Pester 6.2.0 instalado. El test Desktop de hotkeys falla a veces en esta PC también en `main` (keybd_event).
- Los tests Desktop de menú/wizard necesitan la sesión desbloqueada.
- **2.8.0 publicada (2026-10-27)**: el menú del click derecho quedaba debajo del widget (la activación de 2.7.0 lo subía; reproducido 5/5 con un test de z-order, arreglado con SetWindowPos HWND_TOPMOST sobre el popup); filas de "N trabajando" clickeables; sesiones de la app de Claude elegidas por UI Automation (FRÁGIL, `claude-app.ps1`); botón +/− para la lista.
- **Test a revisar:** `disconnect says so when telegram.json cannot be deleted` falló varias veces (también en main); puede ser interferencia del mouse real (ver [[gotchas]]) o el tooltip de 3 s.

## Próximo paso

1. Correr la suite Desktop completa con la PC quieta (no se corrió entera para 2.8.0; sí los tests de menú, sesiones, render y cola).
2. Daniel ya conectó el bot (2026-10-27, `telegram.json` existe). Falta probar un aviso real. Ver si la edición a "resuelto" y los errores reales (409, 403) se comportan como en los tests.
3. Pendiente aparte: `README.es.md` + `docs/images/es/`. Después, 2.9.0 Cards y 2.10.0 Seguridad ([[roadmap]]).
