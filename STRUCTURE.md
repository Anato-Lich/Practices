# Структура каталога: оси, роли, контуры — предложение (7 ноября 2026)

Черновик на проверку. Всё выведено из связей в каталоге (418 связей, 123 сервиса) и описаний
сервисов, не из имён. Что выведено неуверенно — помечено `?`. После правок становится спецификацией:
по ней делаются поля в `service.yaml`, карта и обзор пространства.

## 1. Три оси вместо одной цепочки

Один сервис описывают три независимых вещи, и ни одна не выражается через другую:

| Ось | Вопрос | Сколько значений | Где живёт |
|---|---|---|---|
| **Проект** (папка) | где лежит код, какие репозитории | ровно один | как сейчас: `projects/<id>` |
| **Роль** (слой) | что сервис делает в потоке данных | ровно одна | поле `role:` в `service.yaml`, по умолчанию выводится из связей |
| **Контур** (продукт) | какому продукту/потоку служит | один или несколько | поле `flows:` в `service.yaml`; по умолчанию — контуры проекта |

Почему не дерево: `hyper-imu` — один проект-папка, но его сервисы служат двум продуктам
(панели BLE и IMU-Sphere); `wifi-db` зовут и Сфера, и `device-analysis` из Кипера; `kafka` — всем.
Цепочка ролей ветвится ровно там, где один поток расходится на несколько контуров, и сходится
там, где несколько контуров берут из общего ядра. Поэтому карта пространства — это **слои
по ролям сверху вниз × контуры слева направо**, а общие сервисы растянуты на несколько контуров.

## 2. Роли

Главная цепочка (сверху вниз на карте) и три боковые группы. Правило вывода — по связям и виду;
имя не участвует. Поле `role:` в карточке переопределяет вывод.

| Роль | Кто это | Правило вывода |
|---|---|---|
| `front` | SPA, nginx перед ней, входные шлюзы для людей | `kind: frontend`, или HTTP, которого никто не зовёт, а он зовёт только HTTP |
| `bff` | API, которое существует ради своего фронта | HTTP, которого зовёт только фронт того же контура |
| `backend` | API, которое зовут другие сервисы | HTTP с вызывающими не-фронтами (другие API, воркеры, другие проекты) |
| `processing` | потоковая обработка | воркер с `topic`-связями или Redis Streams: читает поток, пишет поток/базу |
| `worker` | периодические задания | воркер без потока: cron/batch, читает базы и API, пишет базу/файлы |
| `infra` | хранилища и шины | kind postgres / clickhouse / redis / kafka / rabbitmq / s3 |
| — боковые — | | |
| `ingest` | вход данных от машин и приборов | socket/HTTP, куда пишут прошивки, станции, партнёры; сам пишет в шину или базу |
| `relay` | выход данных наружу | воркер, у которого есть `write` во внешний (`external`) сервис |
| `device` | прошивки, станции, роботы на месте | kind firmware; `other`, что живёт на ПК/плате у оборудования |
| `ops` | CI, реестры, миграции, мониторинг, разовые тулзы | kind script / tool / monitor; `other` без связей данных |
| `external` | чужие системы | тег `external` (есть) |

Почему именно эти боковые: `ingest` и `device` — источники (сверху слева: прибор → приёмник →
шина), `relay` и `external` — стоки (справа), `ops` не участвует в потоке данных и на карте
скрыт по умолчанию. Без них «Workers» превращается в свалку из приёмников, прошивок и CI.

Что остаётся спорным и решается полем, а не кодом: HTTP-сервис, которого зовут и фронт, и
воркеры (`route-verdict`, `ble-anchors`) — `backend`; потоковый воркер с HTTP-ручкой
(`route-verdict-clean-stream`) — `processing`.

## 3. Контуры

### SphereTele — два продукта на общем ядре

| Контур | Что это | Проекты-папки |
|---|---|---|
| `ble-panels` | панели администратора и перевозчика по BLE-меткам | `ble` (панели, якоря, проекторы, отчёты, ретрансляция), `nn-mapmatch` ? |
| `imu-sphere` | панель разбора IMU | `imu-sphere` |
| `core` | общий приёмник и обработка, из которых берут оба | `hyper-imu`, `route-verdict`, `wifi-locator` |

`nn-mapmatch` (`nn-live`) — к `ble-panels`, как вы сказали; по связям он читает Kafka и
ClickHouse ядра и пишет в Kafka, так что технически он ядро, а по потребителю — панели. ?

### SphereTele — роли по сервисам

| Роль | ble-panels | imu-sphere | core (общее) |
|---|---|---|---|
| front | ble-panels-frontend | imu-sphere-frontend | |
| bff | ble-panels-api | imu-sphere-api | |
| backend | ble-anchors, ble-panels-tiles, tiles ? | | wifi-db, route-verdict, valhalla |
| processing | ble-panels-projector, nn-live ? | imu-sphere-worker | hyper-normalizer, hyper-calibrator, hyper-imu-sec, hyper-position, hyper-scan-forwarder, hyper-verdict-ingest, control-pair, route-verdict-clean-stream, wifi-locator-enrich |
| worker | ble-panels-metrics, bus-reports, track-store, wifi-learning | | validator ?, batch_worker ? |
| infra | ble-anchors-pg, ble-panels-pg | imu-sphere-pg | kafka, clickhouse, hyper-redis, hyper-norm-redis, wifi-locator-pg, wifi-locator-redis |
| ingest | ble-anchors-receiver | | hyper-receiver |
| relay | wialon-relay | | |
| device | | | hyperimu-apm32f405-firmware, hyperimu-ota-server |
| ops | | | hyper-monitoring, hyper-kafka-ui, hyper-tools, hyper-clickhouse-migrations, route-verdict-tools |
| external | wialon-relay-target | | pakz-crypto-service, zvezda-cs, yandex-locator |

Поток, который это рисует: прибор → `hyper-receiver` → `kafka` → нормализация → позиция →
чистка/вердикт → (a) проектор → `ble-panels-pg` → `ble-panels-api` → панели, (b) `imu-sphere-worker`
→ `imu-sphere-pg` → `imu-sphere-api` → панель IMU, (c) `wialon-relay` → наружу. Ветвление — после
обработки; схождение — на `kafka`/`clickhouse`/`wifi-db`/`ble-anchors`, которые зовут обе ветки.

### X-Keeper — ядро и продуктовые контуры

| Контур | Проекты-папки | Примечание |
|---|---|---|
| `core` (сейчас `platform`) | `platform`, `auth` | sso, system-api, devices-api, xkdb, xkeeper-pg, api-static, tiles-service, wifi-location-api, arm-pg; переименовать проект в «Ядро X-Keeper» |
| `analytics` | `cabinet-analysis`, `device-analysis` | как есть |
| `factory` | `scada`, `mes`, `erp`, `x-vision`, `x-scanners`, `x-shopfloor` | как есть (`x-factory`) |
| `service` ? | `rma`, `warehouse` | ремонты и склад; сейчас «отдельные проекты», связаны между собой |
| `sim` ? | `xsm`, `flyrelay` ? | SIM-менеджер; flyrelay — ретрансляция в СППИ, отдельная вещь |

Проект `external` распускается: каждый чужой сервис — к проекту своего вызывающего
(`beeline-iot`, `mts-iot`, `glonass-api`, `github` → `device-analysis`; `isdayoff` → `rma`;
`moysklad` → `x-shopfloor`; `sppi` → `flyrelay`; `ipinfo`, `yandex-oauth` → `auth`);
с несколькими вызывающими — в ядро (`telegram-bot-api` ← device-analysis, server-monitoring, xsm;
`smtp-yandex` ← device-analysis, warehouse, xsm).

### X-Keeper — роли по сервисам

| Роль | Сервисы |
|---|---|
| front | cabinet-analysis-frontend, device-analysis-web, rma-frontend, x-shopfloor-frontend, x-vision-cloud-frontend, x-vision-gateway, xsm-frontend, xsm-gateway, scada-web |
| bff | cabinet-analysis-api, device-analysis-bff, rma-backend, x-shopfloor-backend, x-vision-client-api, xsm-manage-api, erp-stocks-api |
| backend | sso, system-api, devices-api, api-static, tiles-service, wifi-location-api, warehouse-api, device-analysis-api, xsm-intra-api, erpnext, xkeeper-mcp, osrm |
| processing | scada-outbox, xsm-backend-worker |
| worker | export-engine |
| infra | auth-db, xkeeper-pg, arm-pg, device-analysis-clickhouse, device-analysis-redis, xsm-redis, x-vision-minio, scada-pg, scada-mq |
| ingest | xkdb, scada, x-vision-station-api, x-scanners-server |
| relay | flyrelay |
| device | x-vision-stopper, x-vision-station-local, x-vision-station-collector, x-scanners-station, xsmrobot |
| ops | ci-workflows-templates, nexus-registry, gitlab-rnd, system-dev-nginx, codex-plugin-xkeeper-devices, server-monitoring, xsm-backend-ci, xsm-backend-scripts |
| planned | mes |

Корень, который вы хотели видеть: слой `infra` + `backend` ядра (xkdb, xkeeper-pg, system-api,
sso) — внизу карты, из него вверх идут все контуры, фронты — наверху.

## 4. Как это ложится в данные и экраны

- `service.yaml`: `role: bff` (одно значение из таблицы §2; нет — выводится) и `flows: [ble-panels, core]`
  (нет — контуры проекта). `project.yaml`: `flows: [core]` — контуры по умолчанию для сервисов проекта.
  Контуры пространства перечислены в `space.yaml: flows:` с названиями и порядком слева направо.
- Агент ставит `role:`/`flows:` по коду, когда вывод по связям ошибается; правка проходит приёмку,
  как любая другая. В обзоре пространства — список сервисов, у которых роль выведена, а не задана.
- Карта пространства: строки — роли главной цепочки (front → bff → backend → processing/worker →
  infra), колонки — контуры (`ble-panels` | `core` | `imu-sphere`); сервис нескольких контуров
  занимает их ширину; `ingest`/`device` слева, `relay`/`external` справа, `ops` скрыты.
  Линии — только через границы ролей, с направлением «берёт у».
- Обзор пространства: вместо «проектов · 0 групп» — контуры с их проектами, и роли со счётчиками.
- Боковая панель: дерево проектов остаётся (где код); контур и роль — метками у сервиса и
  фильтром в палитре (`r:bff`, `f:imu-sphere`).

## 5. Вопросы к проверке

1. Набор ролей: 6 главных + 4 боковых. Лишнее или не хватает?
2. Контуры Сферы: `ble-panels` / `imu-sphere` / `core`; `nn-mapmatch` — куда.
3. Контуры Кипера: оставить как группы проектов (`analytics`, `x-factory`) + новые `service`, `sim`?
4. Строки с `?` в таблицах ролей.
5. `external` в Кипере распустить по вызывающим — да/нет.
