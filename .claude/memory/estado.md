---
name: estado
description: Estado al **2026-10-26**:

- **2.7.1 en `main` (1b3e78b), pusheada a `Arkhand/claude-code-widget`, instalada y corriendo.** 2.7.1 = botón "Abrir Claude" para sesiones de la app de escritorio (no hay link para abrir una sesión existente de Code; todas comparten una ventana).
- Verificado antes del merge: `tools	est.ps1 -ExcludeTag Desktop` 525/0; `tests\widget.Tests.ps1` (sesión desbloqueada) 42/0; `claude plugin validate` OK.
- **mcp-notify retirado** y pusheado (`Arkhand/mcp-notify`, commits 8ec1f1a y 62d1a75). Respaldo de lo sacado en `~/tools/mcp-notify/retired/`; copias completas de config en `~/.claude/backups/mcp-notify-retired-2026-10-25/`.
- **Cuenta de gh:** la activa por defecto es `dmusialblueboot` (trabajo), que no tiene permiso en los repos de Arkhand. Para pushear acá: `gh auth switch --user Arkhand` y después volver.
- Pester 6.2.0 instalado. El test Desktop de hotkeys falla a veces en esta PC también en `main` (keybd_event).
- Los tests Desktop de menú/wizard necesitan la sesión desbloqueada.

## Próximo paso

1. Daniel conecta el bot desde el menú (click derecho → Telegram → Conectar) y prueba un aviso real. Ver si la edición a "resuelto" y los errores reales (409, 403) se comportan como en los tests.
3. Pendiente aparte: `README.es.md` + `docs/images/es/`. Después, 2.8.0 Cards y 2.9.0 Seguridad ([[roadmap]]).
