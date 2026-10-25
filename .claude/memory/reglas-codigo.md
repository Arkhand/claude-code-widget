---
name: reglas-codigo
description: Reglas del repo que, si se rompen, fallan los tests de repo.Tests.ps1 o el runtime en PowerShell 5.1
metadata:
  type: project
---

1. **`.ps1` ASCII-only.** PowerShell 5.1 lee archivos sin BOM como ANSI; un acento rompe el script. Todo texto de UI va en `strings.json` (UTF-8, leído explícito). Esto incluye comentarios.
2. **Idiomas:** cada string nuevo va en las 3 claves de `strings.json`: `pt`, `en`, `es`.
3. **EOL:** `.ps1` CRLF, `.json`/`.md` LF (`.gitattributes`).
4. **Sonidos solo vía `Play-Sound`** en widget.ps1 (si no, el volumen no aplica).
5. **Cero red** en los scripts del plugin (test lo verifica). Tampoco assets de Mojang (`.ogg`, `.wav`).
6. En widget.ps1 ningún parámetro de handler puede llamarse como la tabla de strings (`$S`).
7. **Versión de `plugin.json` = última entrada de `CHANGELOG.md`.** Siempre que se bumpea una, la otra.
8. Nombre de plugin no puede empezar con `claude-` (reservado); marketplace mapea `claude-code-widget` → `opaiva-code-widget` en `renames`.
9. READMEs (`README.md` y `README.pt-BR.md`): el id viejo del plugin solo en la sección "Renamed in 2.0.0"; tests lo chequean en ambos.
10. Workflows de GitHub: un comando por step PowerShell y `permissions` limitadas.
11. Hooks `Stop`/`UserPromptSubmit`/`SessionStart` **no imprimen nada** (iría al contexto de Claude). Sin respuesta = sin salida = flujo normal de Claude Code.
12. Estilo: comentarios en inglés, cortos, explicando el porqué; funciones Verb-Noun; `Write-JsonAtomic` para todo JSON que lea otro proceso.

**Why:** son invariantes probados por `tests/repo.Tests.ps1` o fallas de runtime ya vividas por el autor.
**How to apply:** revisar esta lista antes de cada commit; ver [[testing]] para cómo correr los chequeos.
