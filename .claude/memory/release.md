---
name: release
description: Pasos para sacar una versión y para que la copia instalada en la PC tome el cambio
metadata:
  type: project
---

## Proceso de un cambio (convención del autor original)

1. Diseño en `docs/superpowers/specs/YYYY-MM-DD-<tema>-design.md` y plan en `docs/superpowers/plans/YYYY-MM-DD-<tema>.md` (skills superpowers brainstorming → writing-plans). Daniel no los usó para 2.6.0; para cambios grandes conviene seguirlo.
2. Rama `feat/<tema>` o `fix/<tema>`, merge a main.
3. Bump `version` en `plugins/opaiva-code-widget/.claude-plugin/plugin.json` (semver: feat = minor, fix = patch). Sin bump, las copias instaladas no se actualizan.
4. Entrada nueva arriba en `CHANGELOG.md` con `## X.Y.Z (YYYY-MM-DD)`, mismo número.
5. Actualizar `README.md` **y** `README.pt-BR.md` si cambia comportamiento visible. Si cambia la UI, regenerar screenshots ([[testing]]).
6. Commits: `type(scope): ...` en inglés + bloque `Verified:` (regla global de Daniel). El autor original ponía la versión entre paréntesis al final del título.

## Probar en la copia instalada

El plugin instalado vive en `~/.claude/plugins/cache/claude-code-widget/opaiva-code-widget/<version>/` y sale del marketplace del fork (Arkhand). Para tomar una versión nueva hace falta pushearla a `origin/main` y luego:

```
claude plugin marketplace update claude-code-widget
claude plugin update opaiva-code-widget@claude-code-widget
```

Después abrir sesión nueva o `/reload-plugins`; el hook reemplaza al widget viejo solo si es de versión menor (`Test-WidgetOlder`).
Para probar sin publicar: lanzar `widget.ps1 -DataDir <dir temporal>` desde el árbol de trabajo (no pisa el widget real si el dir es otro).

**Why:** push/merge/PR requieren pedido explícito de Daniel; la copia instalada no ve cambios locales.
**How to apply:** no pushear para "probar"; usar data dir temporal o render. Ver [[contexto-fork]].
