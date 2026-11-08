# Лог пласта map

## 2026-11-08
- Папка пласта заведена: PLAN, DECISIONS (1–7 — из задания), LOG.
- Шаг 2: `role:` в `Service` (текстом — неизвестное значение переживает сохранение; пишется только заданным),
  `ServiceMap.roles/inferredRole` по STRUCTURE §2, `practicesctl service role <id> [role]` (без коммита),
  `role` и `role_inferred` в MCP `get_service`. Связь `via: build` не считается вызовом (иначе
  `imu-sphere-api` из-за `route-verdict-tools` выходил backend). `ServiceMap.project` теперь отдаёт
  свои сервисы, вызывающих и вызываемых соседей и пары связей (без «общих» и чипов — вариант E их не
  рисует); добавлены `pairs(in:)` и `thread(_:hops:)`. Тесты: 82 зелёные. Окно до шага 4 не собирается.
- Шаг 3 (ca0411f): `ZoomPan` — масштаб вокруг курсора 0.4×–4×, сдвиг, двойной клик вписывает; события
  прокрутки и щипка — локальным монитором под картой (у SwiftUI на macOS нет жеста колеса). `MapState` —
  отдельный файл: камера, наведение и закрепление, роли, пары связей, кэш раскладок. Рендер: `--zoom k`,
  `--pin id`, `--flow`, `--hops n`.
- Шаги 4–6 (a622aad, одним коммитом — уровни делят `MapView`/`MapLayout`): проект E, пространство B +
  «Поток», нить сервиса, боковая панель, метки соседей за краем. Решения 8–15.
- Рендеры проверены по настоящему каталогу: `--map --project ble`, `--project hyper-imu` (+ `--zoom 2.4
  --pin hyper-normalizer`), `--space spheretele` (+ `--zoom 2`, `--flow`), `--space x-keeper`,
  `--service route-verdict-clean-stream`. Исправлено по ним: линии коридоров рамок срезались краем
  холста, «Обработка» в «Потоке» растягивалась по проекту на колонку.
- Шаг 7: `role:` записан во все 134 сервиса spheretele и x-keeper, не закоммичено (приёмка — в окне
  или `practicesctl accept`). Источник — таблицы ролей `STRUCTURE.md`, где сервиса там нет — вывод.
  **Побочный шум:** первый прогон шёл через `Registry.save` и пересобрал файлы целиком — кавычки у
  `${…}` сняты, `- name: X / secret: false` свёрнуто в `- X` (то же значение), добавлено
  `requires: []`. Смысл не изменился (проверено: удалённые строки — только эти поля, комментариев и
  неизвестных ключей не было). Откатить файлы к HEAD агенту не разрешили (защита от необратимых
  действий); после этого `service role` переведён на правку одной строки (fix(core)). Если шум не
  нужен — `practicesctl discard` и повторить `service role` по списку ниже.
- Шаг 8 пропущен: демо-каталога для снимков нет, собирать его ради одной картинки дорого; в README
  старый `docs/images/map.png`, флаги рендера карты дописаны.

### Роли, в которых не уверен
| Сервис | Записано | Почему сомнение |
|---|---|---|
| batch_worker, validator | worker | `?` в STRUCTURE |
| ble-panels-tiles, tiles-service | backend | вывод bff (зовёт только фронт), STRUCTURE — backend (общий для двух фронтов) |
| hyper-kafka-ui | ops | вывод front (UI), STRUCTURE — ops |
| hyperimu-ota-server | device | вывод ingest (сокет) |
| wifi-locator-enrich, xsm-backend-worker | processing | вывод worker (нет topic-связей в каталоге) |
| export-engine | worker | вывод backend (kind http) |
| erp-stocks-api | bff | вывод backend |
| scada, x-scanners-server, x-vision-station-api | ingest | вывод backend |
| x-vision-station-local, x-vision-stopper, x-scanners-station, x-vision-station-collector, xsmrobot | device | вывод backend/ingest/worker |
| server-monitoring, system-dev-nginx, codex-plugin-xkeeper-devices, xsm-backend-ci, xsm-backend-scripts | ops | вывод relay/front/worker |
| mes | processing | в STRUCTURE — `planned`, такой роли нет; оставлен вывод |
| xsm-mkdocs | ops | вывод bff (сайт документации — не данные) |
| accounting, outkeep | bff | нет в STRUCTURE, только вывод |
| sentry | external | нет в STRUCTURE |
| migrator | ops | нет в STRUCTURE |
