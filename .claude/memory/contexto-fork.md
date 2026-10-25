---
name: contexto-fork
description: Quién es el dueño original, que este repo es el fork de Daniel y qué cambió Daniel hasta ahora
metadata:
  type: project
---

- **Upstream:** `OPaiva-1721/claude-code-widget`, autor Gabryel Paiva Neves (80 commits, 1.0.0 → 2.5.4, hasta 2026-10-13). El README y `plugin.json` siguen apuntando a OPaiva-1721.
- **Fork:** `origin` = `https://github.com/Arkhand/claude-code-widget.git` (Arkhand = Daniel). No hay remote `upstream` configurado.
- El marketplace instalado en la máquina de Daniel apunta al fork (Arkhand), no al upstream: `~/.claude/plugins/known_marketplaces.json`.
- **Aporte de Daniel (2026-10-25, PR Arkhand/claude-code-widget#1, rama `feat/es-stacked-notices`, ya mergeada en main):**
  - 2.6.0: notices "finished" apiladas (hasta 4, ring de 5 min), se muestran también con la app de escritorio de Claude, "question for you" leído del final del transcript, widget ancla el borde superior y no sale de un monitor, UI en español (`es`), se eliminó el tema Minecraft (y con él la única llamada de red: `mojang.ps1`).
  - Away pasó de 2 a 5 minutos (`$AwaySecs`, override con `CLAUDE_WIDGET_AWAY_SECS`).
- La rama remota `origin/feat/es-stacked-notices` quedó viva aunque ya está mergeada.

**Why:** define a dónde se pushea y desde dónde se instala; un PR al upstream es otra cosa que un PR al fork.
**How to apply:** pushes/PRs van a `origin` (fork) salvo que Daniel pida explícitamente contribuir a upstream; en ese caso agregar remote `upstream` primero. Ver [[release]] y [[estado]].
