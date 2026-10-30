---
name: roadmap
description: Plan de versiones 2.7-2.11 acordado con Daniel el 2026-10-25 y las decisiones de diseño de cada una
metadata:
  type: project
---

Acordado el **2026-10-25**. Todo va al fork `Arkhand/claude-code-widget`, encima de 2.6.0. Upstream no se toca.

## 2.7.0 Telegram (reemplaza mcp-notify)
Spec: `docs/superpowers/specs/2026-10-25-telegram-alerts-design.md`.
- Regla: "si no respondo en X min, buscame en el teléfono". X = `notifyAfter` 1/3/5 min (solo Telegram).
- Tiempos separados (Daniel lo pidió después): `closeAfter` 1/3/5/15/30/Nunca cierra cards y notices (Nunca = tope 60 min en cards, 12 h en notices). Al llegar `notifyAfter` sale el Telegram; si estás away el card pasa a VS Code (para que Remote Control responda), si estás en la compu se queda. `hooks.json` timeouts 3630.
- Notices "terminó": Telegram si siguen abiertas a los X; la notice sigue hasta sus 5 min.
- Away → Telegram al instante. DND → Telegram solo si además está away.
- Batching + editar a "✅ resuelto" cuando la sesión sigue.
- Menú: **Esperar respuesta ▸** 1/3/5 (top level) y **Telegram ▸** (Conectar… / Avisos activados, Enviar prueba, Desconectar). Card sin "Telegram en…": solo el timer de siempre (pedido explícito de Daniel).
- Conexión 100% desde el widget: asistente de 3 pasos (token de BotFather → link `t.me/<bot>?start=<código>` y el widget toma el chat id por `getUpdates` → prueba). Token cifrado con DPAPI en `telegram.json` del data dir. Nada de variables para Telegram.
- Cubre también lo que queda esperando en VS Code (plan approval, "Decidir en VS Code", DND, widget caído): marcador + hook `Notification`; avisa si sigue esperando a los X y estás away.
- La notice de "terminó" se cierra sola al poner al frente la ventana de su sesión (no aplica a la app de escritorio: ahí avisa solo si away).
- Bug probable encontrado: el widget arranca por WMI y no hereda el `env` de settings.json → `CLAUDE_WIDGET_HOTKEYS`/`AWAY_SECS` no le llegan. Fix: el widget lee el `env` de `~/.claude/settings.json`. Confirmar con test primero.
- Red solo en `scripts/telegram.ps1` y solo `api.telegram.org`; el hook nunca hace red (escribe outbox, el widget envía).
- Fuera: responder desde Telegram, WhatsApp, mutes por carpeta, tool MCP.
- Después: deprecar `~/tools/mcp-notify` (hooks en settings.json, MCP en ~/.claude.json, commands notify-*.md), con lista confirmada por Daniel.

## 2.8.0 (hecho, 2026-10-27)
Menú ya no queda tapado por el widget; filas de "N trabajando" clickeables → ventana de la sesión; sesiones de la app de escritorio elegidas en su barra lateral vía UI Automation (FRÁGIL, `claude-app.ps1`); botón +/− para la lista.

## 2.10.0 Cards (UI)
Título = proyecto · sesión; sacar "Claude Code" del lugar principal; quitar cwd duplicado; paths relativos; **Approve ▾** con los Always allow adentro; "otra respuesta" como link; auto-submit en pregunta única de opción única; barra de tiempo unificada (sin "Telegram en…": Daniel lo descartó); flash "✓ aprobado/✕ denegado".
- Colores (medido WCAG): blanco sobre Approve `#D97757` = 3.1 (falla), grises `#6E6E78` 3.3 y `#7E7E88` 4.1 (fallan), claro `#7C7C86` 4.0. Subir todos a ≥ 4.5 con test sobre el mapa de colores.
- Approve/Deny no solo por color: íconos ✓/✕, Deny neutro (rojo en hover). Punto de estado → ícono (escudo / ? / ✓), clave para la pill mínima.
- Íconos con Segoe Fluent Icons / MDL2 (vienen con Windows, sin assets ni red), uno por tool en el chip.
- Menú contextual con el tema del widget (hoy es el claro default de WPF).
- Mica/Acrylic: último o afuera (frágil en WPF/PS).

## 2.11.0 Seguridad (UX)
Comandos peligrosos (badge rojo, mantener 1 s para aprobar, hotkey no aprueba); pill idle se desvanece a ~40%; botón `⋯` al hover para el menú.

**How to apply:** un spec por versión, en orden. Ver [[estado]] para dónde quedó.
