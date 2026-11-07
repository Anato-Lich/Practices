# Practices

**One place that describes all of a developer's projects: what belongs where, which services
talk to which, where the credentials, the documentation and the ready query code are.** A
personal macOS app (a window plus a menu-bar agent), the `practicesctl` CLI and an MCP server;
the first reader is the agent working in a project.

- **Catalogue** — a *space* (an organisation) holds *projects*, which nest; a project holds
  *repositories*, known by their remote address, and *services*: a compose service of a
  repository or an external system (a database, an API, Kafka). A service has endpoints, names
  of its keys, named *conditions* ("needs the corporate network"), notes, a dictionary of
  result fields and *links* to the services it calls. Each space is a git repository under
  `~/.practices/spaces/`; values of secrets stay outside git in `~/.practices/secrets.json`.
- **Practices** — under each service live *practices*: named cells of code ("fetch device
  data") with a Run button, a readable result (table, JSON tree, text), timings and version
  history; *chains* combine them. Practices are copied into projects; through MCP the agent
  reads the catalogue and sends practices and links back as uncommitted changes the user
  accepts.

Plan and stages: [`PLAN.md`](PLAN.md). Choices and their alternatives:
[`DECISIONS.md`](DECISIONS.md).

## Layout

| Path | What |
|---|---|
| `PracticesCore/` | Swift package: the core, no UI, plus the `practicesctl` CLI |
| `PracticesApp/` | SwiftUI app, generated with `xcodegen` from `project.yml` |
| `tools/` | build helpers |

## Build

```sh
./run.sh                                  # xcodegen + xcodebuild + open (Debug)
./install.sh                              # Release build into /Applications
tools/build-dev.sh                        # Command Line Tools only, when xcodebuild is unavailable
cd PracticesCore && swift run practicesctl spaces
```

Tests (Swift Testing). With full Xcode selected: `swift test`. With the Command Line
Tools only, point the compiler at the Testing framework:

```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

## `practicesctl`

Catalogue (`~/.practices/spaces/<space>`):

```
practicesctl spaces | space add <id> [--hosting host/owner …]
practicesctl projects [space] | project <id> | project add <space>/<id> [--parent p]
practicesctl repos [--all] | assign <repo> <project> [--role r] | unassign <repo> | ignore <repo>
practicesctl services [project] | service <id> | service add <id> --project <p> …
practicesctl links [service] | link add <from> <to> [--via db] [--why …]
practicesctl conditions [space] | condition add <space>/<id> --name N [--hint H]
practicesctl scan [project | repo]… [--write]      # services and links from compose and example env files
practicesctl pending | accept [space [path…]]      # an agent's edits wait here
```

Values and checks (`ref` = `<service>[@<env>]`):

```
practicesctl check [ref…]
practicesctl secrets set <id> <KEY> [--env e]      # value from stdin
practicesctl env <ref…>                            # variable names, never values
practicesctl run <ref…> -- <command…>
practicesctl connect <ref…> --to <file> [--project dir] [--as VAR=KEY]   # write a project's env file
practicesctl doctor
```

Practices and the agent:

```
practicesctl practices [service] | sig <ref> | try <ref> [k=v…] | runs <ref>
practicesctl search <text> | copies [ref]
practicesctl mcp                                   # MCP server (stdio)
claude mcp add --scope user practices -- ~/.practices/bin/practicesctl mcp
```

`--json` on the listing commands prints machine-readable output.

## Передача другому человеку

Передаётся только приложение (DECISIONS 36). Каталог личный: пространства под `~/.practices/spaces`
— локальные git-репозитории (история, приёмка правок агентов) без remote, из них ничего не
копируется. `~/.practices/local.yaml`, секреты, регистрация MCP и блоки инструкций агентам тоже у
каждого свои. Новый человек клонирует репозиторий приложения:

```sh
git clone <этот репозиторий> && cd Practices && ./install.sh   # ставит xcodegen и uv через brew, если их нет
```

При первом запуске он создаёт своё пространство и добавляет папки со своими клонами — на экране
«Начало» или командами (их же может выполнить агент в диалоге). Каталог наполняют `scan` и агенты:

```
practicesctl setup status                          # что уже настроено
practicesctl setup roots ~/Projects/…              # где лежат клоны
practicesctl space add <id> [--name N] [--hosting host/owner]   # своё пространство
practicesctl scan <project> --write                # сервисы и связи из клонов, ждут `accept`
practicesctl setup agents                          # MCP и блок инструкций для Claude Code, Codex, Cursor
```
