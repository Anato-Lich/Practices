import Foundation

/// First records of the registry: the six sources of `~/Projects/Connectors`, their keys
/// (from its `.env`), and what its README and SOURCES.md say about them. Values go straight
/// into the secret store; the summary carries counts and names only.
public enum ConnectorsImport {

    public struct Summary: Sendable {
        public var sources: [String] = []
        public var valuesImported = 0
        /// Keys in `.env` that no source claims.
        public var unassigned: [String] = []
    }

    /// Parses a dotenv file: `KEY=value`, optional `export `, quotes stripped, `#` comments.
    public static func parseDotenv(_ text: String) -> [(key: String, value: String)] {
        var result: [(String, String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, (q == "\"" || q == "'"), value.last == q {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { continue }
            result.append((key, value))
        }
        return result
    }

    /// Which source a Connectors key belongs to.
    static func owner(of key: String) -> String? {
        let rules: [(String, [String])] = [
            ("xkeeper-pg", ["XK_PG_", "ARM_PG_"]),
            ("xkdb", ["XKDB_", "DEVICE_BATCH_SIZE", "BACKFILL_MAX_DAYS"]),
            ("system-api", ["XK_SYS_", "X_AUTH_", "AUTH_DISABLED", "FALLBACK_X_"]),
            ("kafka", ["KAFKA_"]),
            ("clickhouse", ["CH_"]),
            ("wifi-db", ["WIFI_DB"]),
        ]
        return rules.first { _, prefixes in prefixes.contains { key.hasPrefix($0) } }?.0
    }

    static func sources(keys: [String: [String]]) -> [Source] {
        func k(_ id: String) -> [Source.Key] { (keys[id] ?? []).map { Source.Key(name: $0) } }
        return [
            Source(
                id: "xkeeper-pg", name: "X-Keeper Postgres", kind: "postgres",
                description: "Пять баз X-Keeper, одна учётная запись на чтение для всех. Никогда не писать.",
                tags: ["read-only", "prod-data", "shared"], keys: k("xkeeper-pg"),
                targets: [
                    .init(id: "logistic", label: "web_admin", address: "${XK_PG_HOST}:${XK_PG_PORT_LOGISTIC}"),
                    .init(id: "panel", label: "api_panel", address: "${XK_PG_HOST}:${XK_PG_PORT_PANEL}"),
                    .init(id: "accounts", label: "accounts", address: "${XK_PG_HOST}:${XK_PG_PORT_ACCOUNTS}"),
                    .init(id: "devices", label: "x-keeper_devices", address: "${XK_PG_HOST}:${XK_PG_PORT_DEVICES}"),
                    .init(id: "arm", label: "invitest · отдельный хост", address: "${ARM_PG_HOST}:${ARM_PG_PORT}"),
                ],
                requires: [.init(reachable: "${XK_PG_HOST}:${XK_PG_PORT_LOGISTIC}",
                                 hint: "X-Keeper Postgres недоступен: он ходит через WireGuard-туннель — включён ли он?")],
                guards: [
                    "Каждое соединение: default_transaction_read_only = on",
                    "Запрос с глаголом записи падает до соединения (ReadOnlyViolation)",
                ]),
            Source(
                id: "xkdb", name: "XKDB · телеметрия", kind: "socket",
                description: "Сырая телеметрия: TCP + JSON, кадры разделены \\r\\n\\r\\n.",
                tags: ["prod-data"], keys: k("xkdb"),
                targets: [
                    .init(id: "server0", label: "server_id = 0", address: "${XKDB_HOST_SERVER0}:${XKDB_PORT}"),
                    .init(id: "default", label: "остальные server_id", address: "${XKDB_HOST_DEFAULT}:${XKDB_PORT}"),
                ],
                guards: [
                    "Все хэши одного get_chunk должны делить server_id — он выбирает хост",
                    "Ответ ограничен 100 МБ; длинные периоды — get_chunk_windowed",
                ]),
            Source(
                id: "clickhouse", name: "ClickHouse · hyper_imu", kind: "clickhouse",
                description: "База hyper_imu. По умолчанию учётная запись readonly.",
                tags: [], keys: k("clickhouse"),
                targets: [.init(id: "http", label: "HTTP-интерфейс", url: "${CH_URL}/ping")]),
            Source(
                id: "kafka", name: "Kafka", kind: "kafka",
                description: "SASL_PLAINTEXT / SCRAM-SHA-256.",
                tags: [], keys: k("kafka"),
                targets: [.init(id: "bootstrap", label: "bootstrap", address: "${KAFKA_BOOTSTRAP}")],
                requires: [.init(reachable: "${KAFKA_BOOTSTRAP}")],
                guards: ["Живые consumer group не использовать: заберут офсеты у работающего потребителя"]),
            Source(
                id: "wifi-db", name: "WiFi DB · локатор", kind: "http",
                description: "HyperIMU_DB / локатор.",
                tags: [], keys: k("wifi-db"),
                targets: [.init(id: "api", label: "API", url: "${WIFI_DB_URL}")],
                guards: ["post_scans: не больше 2000 наблюдений за запрос — как на сервере"]),
            Source(
                id: "system-api", name: "System API", kind: "http",
                description: "X-Keeper System API. Вход по cookie X-SID и X-REFRESH-TOKEN, без логина и пароля.",
                tags: ["rotating-tokens"], keys: k("system-api"),
                targets: [.init(id: "api", label: "API", url: "${XK_SYS_BASE_URL}")],
                guards: ["Токены меняются при каждом refresh: новые значения нужно сохранять"]),
        ]
    }

    static let notes: [String: String] = [
        "xkeeper-pg": """
            - `create_dt` в `devices` — начало бэкфилла устройства.
            - `server_id` выбирает хост XKDB: `group_hashes_by_server` перед XKDB.
            - У части устройств сбиты часы: `data_processed.device_dt` в 2030–2042. `ORDER BY device_dt DESC` поднимает их наверх, телеметрии у них нет — ограничивать сверху `now()`.
            - Хост ходит через WireGuard (`utun5`). Если в песочнице маршрут по умолчанию через другой `utun`, будет таймаут — это маршрутизация, не креды.
            """,
        "xkdb": """
            - Хэши в одном `get_chunk` должны делить `server_id`: `get_chunk_multi` группирует сам.
            - `create_dt` из `devices` — начало бэкфилла; раньше него данных нет.
            """,
        "clickhouse": "- По умолчанию учётная запись `readonly`; admin — только явно.\n",
        "kafka": """
            - Девять живых consumer group запрещены коннектором без явного `allow_shared_group=True`.
            - `HyperIMU_infra` по умолчанию `PLAIN` и полагается на `.env` для `SCRAM-SHA-256`.
            - Локальный брокер `hyper-imu/infra/kafka` — `PLAINTEXT` без SASL.
            - `partitions_for_topic()` возвращает `None` у consumer с `group_id=None`, пока не выполнен `fetch_all_metadata()`.
            - Топики `frames.norm_v2`, `live_updates`, `finished_routes`, `point_status` задокументированы, но отсутствуют на брокере.
            """,
        "wifi-db": """
            - `get_mac`: 404 = неизвестный MAC, не ошибка.
            - Политики (TTL, пороги спуфинга, приоритет источников) — в таблице `config` сервиса; env только затеняет их.
            """,
        "system-api": """
            - `search_device` принимает SIM сегментом пути `{base_url}/{sim}`; как query-параметр — 404, легко принять за плохой токен.
            - Токены: `X-SID` (JWT, ~15 мин) и `X-REFRESH-TOKEN`, обновляются через `update-session`. Без сохранения повёрнутый refresh теряется при выходе.
            - Начальные значения — `FALLBACK_X_TOKEN` / `FALLBACK_X_REFRESH_TOKEN`.
            """,
    ]

    /// Section of SOURCES.md each source is described in.
    static let sections: [String: String] = [
        "xkeeper-pg": "1. X-Keeper Postgres (read-only)", "xkdb": "2. XKDB raw telemetry socket",
        "clickhouse": "3. ClickHouse — `hyper_imu`", "kafka": "4. Kafka",
        "wifi-db": "5. HyperIMU_DB / WiFi locator", "system-api": "6. X-Keeper System API",
    ]

    public static func run(connectors: URL, registry: Registry = Registry(), store: SecretStore = SecretStore()) async throws -> Summary {
        let env = try String(contentsOf: connectors.appendingPathComponent(".env"), encoding: .utf8)
        let pairs = parseDotenv(env)
        var keys: [String: [String]] = [:]
        var values: [String: [String: String]] = [:]
        var summary = Summary()
        for (key, value) in pairs {
            guard let id = owner(of: key) else { summary.unassigned.append(key); continue }
            if !(keys[id] ?? []).contains(key) { keys[id, default: []].append(key) }
            values[id, default: [:]][key] = value
        }
        try await registry.ensureRepository()
        for source in sources(keys: keys) {
            try registry.save(source)
            try registry.saveNotes(notes[source.id] ?? "", of: source.id)
            var docs = [SourceDoc(title: "Контракт · SOURCES.md", kind: .generated,
                                  path: connectors.appendingPathComponent("SOURCES.md").path, section: sections[source.id])]
            docs.append(SourceDoc(title: "Connectors · README", kind: .collected,
                                  path: connectors.appendingPathComponent("README.md").path))
            try registry.saveDocs(docs, of: source.id)
            if registry.fields(of: source.id).isEmpty { try registry.saveFields(seedFields[source.id] ?? [], of: source.id) }
            let own = values[source.id] ?? [:]
            if !own.isEmpty { try store.setAll(own, source: source.id, env: source.defaultEnv) }
            summary.valuesImported += own.count
            summary.sources.append(source.id)
        }
        try await registry.commit("Import six sources from Connectors")
        return summary
    }

    /// What is already known about fields, with where it was learned.
    static let seedFields: [String: [FieldDoc]] = [
        "xkdb": [
            FieldDoc(path: "device_hash", type: "bigint", meaning: "ключ ответа: result.<device_hash>; общий с Postgres devices", from: ["SOURCES.md"]),
            FieldDoc(path: "device_dt", type: "str", meaning: "время события на устройстве; у части устройств сбиты часы — даты 2030–2042", from: ["SOURCES.md", "Connectors README"]),
            FieldDoc(path: "create_dt", type: "str"),
            FieldDoc(path: "extra", type: "dict", meaning: "все показания устройства", from: ["SOURCES.md"]),
            FieldDoc(path: "extra.acc_motion", type: "int",
                     meaning: "состояние акселерометра; движение считается по переходам, а не по GPS",
                     values: ["2|3": "начало движения", "0": "остановка", "иное": "не переход — пропускать"],
                     from: ["X-Keeper/cabinet-analysis/backend/src/analysis/track.py",
                            "X-Keeper/device-analysis/device_analysis-api/source/logic/analysis/movement.py"]),
            FieldDoc(path: "extra.nn", type: "int", meaning: "счётчик извещений", from: ["X-Keeper/cabinet-analysis/README.md"]),
            FieldDoc(path: "extra.nin", type: "int", meaning: "счётчик извещений", from: ["X-Keeper/cabinet-analysis/README.md"]),
        ],
        "xkeeper-pg": [
            FieldDoc(path: "create_dt", type: "timestamptz", meaning: "начало бэкфилла устройства", from: ["Connectors README"]),
            FieldDoc(path: "server_id", type: "int", meaning: "выбирает хост XKDB: 0 — первый, иначе второй", from: ["SOURCES.md"]),
        ],
    ]
}
