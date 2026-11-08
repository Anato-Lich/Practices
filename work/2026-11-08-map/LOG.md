# Лог пласта map

## 2026-11-08
- Папка пласта заведена: PLAN, DECISIONS (1–7 — из задания), LOG.
- Шаг 2: `role:` в `Service` (текстом — неизвестное значение переживает сохранение; пишется только заданным),
  `ServiceMap.roles/inferredRole` по STRUCTURE §2, `practicesctl service role <id> [role]` (без коммита),
  `role` и `role_inferred` в MCP `get_service`. Связь `via: build` не считается вызовом (иначе
  `imu-sphere-api` из-за `route-verdict-tools` выходил backend). `ServiceMap.project` теперь отдаёт
  свои сервисы, вызывающих и вызываемых соседей и пары связей (без «общих» и чипов — вариант E их не
  рисует); добавлены `pairs(in:)` и `thread(_:hops:)`. Тесты: 82 зелёные. Окно до шага 4 не собирается.
