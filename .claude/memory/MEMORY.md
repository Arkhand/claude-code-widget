# Memoria — claude-code-widget

Widget WPF always-on-top para Claude Code en Windows (PowerShell 5.1). Plugin `opaiva-code-widget`, marketplace `claude-code-widget`. Versión: 2.8.0 (main, instalada).

- [Contexto del fork](contexto-fork.md) — upstream OPaiva-1721 (Gabryel), fork Arkhand (Daniel), qué aportó Daniel
- [Arquitectura y mapa de código](arquitectura.md) — hook → queue → widget, qué función mirar para cada feature
- [Reglas que rompen el build](reglas-codigo.md) — ASCII-only, CRLF, strings.json, versión = CHANGELOG, sin red; las chequea repo.Tests.ps1
- [Tests y verificación](testing.md) — Pester 6.2 instalado; comandos, tag Desktop, harness, render de screenshots
- [Flujo de release](release.md) — bump de versión, CHANGELOG, READMEs en+pt, specs/plans, actualizar la copia instalada
- [Estado y pendientes](estado.md) — 2.8.0 en main, pusheada e instalada; cuenta gh para pushear; próximos pasos
- [Roadmap 2.7-2.9](roadmap.md) — Telegram (reemplaza mcp-notify), rediseño de cards, seguridad y sesiones; decisiones tomadas
- [Gotchas](gotchas.md) — trampas ya pisadas (transcripts grandes, $Data/$data, salida de hooks, timeouts)
