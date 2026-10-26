---
name: estado
description: Estado al 2026-10-25 y pendientes concretos para retomar
metadata:
  type: project
---

Estado al **2026-10-25**:

- Rama `feat/telegram-alerts` (desde `main` 176dac2) con **2.7.0 completa**: 11 tareas del plan + 8b (tiempos separados). Suite completa: 542 pasan, 0 fallan; `claude plugin validate` OK. Sin pushear ni mergear.
- Plan: `docs/superpowers/plans/2026-10-25-telegram-alerts.md`. Ledger con todas las decisiones (R1-R17) y menores diferidos: `.superpowers/sdd/2026-10-25-telegram-alerts/progress.md` (gitignored, se borra al cerrar).
- Revisión final de toda la rama: en curso o hecha. Ver ledger.
- **mcp-notify retirado** (con OK de Daniel): hooks sacados de `~/.claude/settings.json`, MCP `notify` removido, comandos `/notify-*` movidos. Respaldo en `~/tools/mcp-notify/retired/` y copias completas en `~/.claude/backups/mcp-notify-retired-2026-10-25/`. En el repo de mcp-notify hay 2 commits locales (`8ec1f1a`, `62d1a75`) **sin pushear**: el push falló porque git autentica como `dmusialblueboot` (sin permiso en Arkhand). Hace falta `gh auth switch --user Arkhand`; lo mismo para pushear el widget.
- Hasta instalar 2.7.0 y conectar el bot, no llegan avisos al celular.
- Instalado en la PC: 2.5.4. Para 2.7.0: merge a main + push al fork + `claude plugin marketplace update claude-code-widget` + `claude plugin update opaiva-code-widget@claude-code-widget` + `/reload-plugins`.
- Pester 6.2.0 instalado (CurrentUser).
- El test Desktop de hotkeys ('approves, denies and toggles...') falla a veces en esta PC también en main (keybd_event); no es regresión.

## Próximo paso

1. Aplicar lo que diga la revisión final (una ronda de arreglos), mergear a `main`, cambiar la cuenta de gh a Arkhand y pushear (widget y mcp-notify), con OK de Daniel.
2. Instalar 2.7.0 y conectar el bot con el asistente del menú. Probar un aviso real.
3. Pendiente aparte: `README.es.md` + `docs/images/es/`. Después, 2.8.0 Cards y 2.9.0 Seguridad ([[roadmap]]).
