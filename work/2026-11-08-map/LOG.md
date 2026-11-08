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
- Шаг 7: `role:` записан во все 135 сервисов spheretele и x-keeper, не закоммичено (приёмка — в окне
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

## 2026-11-08, второй проход
- Роли переписаны чисто: в обоих пространствах pending были только 135 `service.yaml` с `+role:`;
  роли сохранены, файлы сброшены `practicesctl discard`, роли записаны заново `practicesctl service
  role` (строкой). Решения владельца: `ble-panels-tiles`, `tiles-service` → `infra`; `mes` — без
  роли. Итог, не закоммичено: spheretele 51 файл, +51/−0; x-keeper 83 файла, +83/−0.
- Нить по данным (4d4318b, решение 16): `ServiceMap.thread` — колонки с шагами ±2d и брокером на
  ±(2d−1), ключ брокера `id@шаг`; тест `threadFollowsData` (писатель → топик → читатель, другой
  топик не попадает, db по access, брокер в центре). Рендеры: `--service route-verdict-clean-stream`
  (hyper-position → kafka → clean-stream → kafka → ble-panels-projector, clickhouse, nn-live;
  route-verdict по http справа; ble-panels-api слева — он зовёт `/board`), `--service hyper-normalizer`.
- Брокер на уровне проекта (9ece8d6, решение 17): рендеры `--project hyper-imu` вписанный и `--zoom 1.5`
  (+ `--pin hyper-normalizer` — веер из трёх топиков).
- Подпроекты в «Рамках» (7a4418f, решение 18): `--space x-keeper` — analytics ⊃ cabinet-analysis,
  device-analysis; platform ⊃ auth; x-factory ⊃ erp, mes, scada.
- README (3d422f9): демо из трёх проектов (shop, orders, analytics) в `~/Demo` как `PRACTICES_HOME`,
  `--map --space demo --zoom 1.05` (80 %, связи сервис → сервис), `-recent ""` — чтобы в «Недавних»
  не было настоящих имён; `sips -Z 1600`; `~/Demo` удалено.
- Финал: `swift test` — 84 зелёные; Debug-рендеры всех уровней просмотрены; `./install.sh`, приложение
  перезапущено. Не запушено.

### Осталось
- Легенда «Потока» x-keeper шире окна (17 проектов в одной строке) и обрезается слева.
- При ≥ 80 % в «Рамках» линии к сервисам подпроекта идут от края внешней рамки через поле подрамки.
- Нить при 3 шагах широкая (clean-stream вверх тянет весь hyper-imu через clickhouse); вписывается
  по центру сервиса, края за экраном.
- Подписи топиков на линиях нити у брокера с многими читателями местами наползают друг на друга.

## 2026-11-08, третий проход
- Нить (144585f, решение 19): рендеры `--service route-verdict-clean-stream` (1 шаг: hyper-position →
  kafka → центр → kafka → ble-panels-projector, clickhouse, nn-live; «вызовы»: ble-panels-api слева,
  route-verdict справа; 75 %, вписана), `--hops 2` (шире окна, центр на сервисе, края сдвигом),
  `--service hyper-normalizer` (вписана, подписи топиков у читателей не сталкиваются).
- Проект (9c88d03, решение 20): `--project ble` — вписан в 56 % (был обрезан справа в 50 %),
  `--project hyper-imu` — 75 %, колонка вызывающих одна, не две.
- «Рамки» (39e0eb6, решение 21): `--space x-keeper --zoom 2.2` — sso, auth-db во всю ширину рамки auth.
- «Поток» (24de174, решение 22): `--space x-keeper --flow` — легенда в три строки проектов.
- `swift test` — 84 зелёные; `./install.sh`, приложение перезапущено. Не запушено.

### Осталось
- «Поток» x-keeper шире окна при минимуме 0.4×: колонка «Внешнее» обрезана справа (сдвигом видна).
- Нить в 2+ шага шире окна при 0.75× — так задумано (сдвиг), но внешние колонки за краем без меток.
- Карточки проекта в 180 pt режут длинные id (ble-anchors-rec…, hyper-clickhouse-…) — полный id в подсказке.
- На уровне проекта легенда перекрывает нижний ряд высоких колонок (hyper-imu), пока не сдвинуть.

## 2026-11-08, назад / вперёд
- `NavigationHistory<Entry>` в PracticesCore (visit/back/forward, новый переход стирает «вперёд»,
  повтор подряд — одна запись, предел 100), тест `NavigationHistoryTests`. В `RegistryModel.history` —
  `Place`: выбор, а для «Карты» ещё уровень, пространство, проект, сервис; карта сообщает о переходах
  через `MapState.onMove` (show/open/focus — уровни, «Нить», «Проект», меню пространств). Не сохраняется.
- Панель: шевроны «Назад»/«Вперёд» перед хлебными крошками (`Navigation.swift`). Клавиши через локальный
  монитор по key code: ⌘[ ⌘] всегда (на русской раскладке это х/ъ — `keyboardShortcut("[")` их не ловил),
  ⌘← ⌘→ — если фокус не в тексте. Кнопки мыши 3/4, `.swipe` (три пальца), два пальца —
  `trackSwipeEvent` при «Swipe between pages», со стрелкой у края окна. Не начинается над холстом
  карты (`PansSideways`, он сам панорамирует) и над `NSScrollView`, чей документ шире видимой части.
- Проверено: Debug-рендер (назад активна, вперёд погашена); на установленном приложении через System
  Events ⌘1, ⌘2, ⌘[ ×2, ⌘], ⌘→, ⌘← — экраны менялись как ожидалось. Свайп руками не проверен.
