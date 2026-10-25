---
name: testing
description: Cómo verificar cambios en este repo; Pester 5.5 no está instalado en la PC de Daniel
metadata:
  type: project
---

- **En esta PC solo hay Pester 3.4.0** (el que trae Windows). `tools/test.ps1` exige ≥ 5.5 y sale con error. Instalar una vez (pedir OK a Daniel antes):
  `Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck`
- Correr todo: `powershell -NoProfile -File tools\test.ps1`
- Sin tests que abren ventanas: `powershell -NoProfile -File tools\test.ps1 -ExcludeTag Desktop` (todos los `Describe` de `tests/widget.Tests.ps1` son `-Tag 'Desktop'`).
- Correr siempre con **Windows PowerShell 5.1** (`powershell.exe`), no `pwsh`: es el runtime del plugin.
- Suites: `common.Tests.ps1` (helpers puros), `hook.Tests.ps1` (funciones dot-sourceadas), `hook.e2e.Tests.ps1` (hook.ps1 como proceso real vía `tests/helpers/HookHarness.ps1`: sandbox temporal + el test agarra el mutex del widget para que el hook no lance uno real), `widget.Tests.ps1` (widget real con `CLAUDE_WIDGET_NO_TRAY=1`), `repo.Tests.ps1` (reglas de [[reglas-codigo]]).
- Validar manifiestos: `claude plugin validate .` y `claude plugin validate plugins/opaiva-code-widget`.
- Chequeo visual: `powershell -NoProfile -File tools\render-screenshots.ps1` regenera `docs/images/{en,pt}/*.png`; para un tema: `widget.ps1 -RenderSamples tools\samples.json -OutDir <dir> -Theme light`.
- CI (`.github/workflows/test.yml`): Pester en windows-latest + validate con Claude Code por npm, en cada push/PR.

**Why:** el commit de 2.6.0 dice explícitamente "Pester suite NOT run locally"; la verificación fue a mano (parse check, renders, widget vivo, GetWindowRect).
**How to apply:** no declarar algo verificado sin correr al menos `-ExcludeTag Desktop` + validate; si Pester no está, decirlo y verificar por render/logs. Ver [[estado]].
