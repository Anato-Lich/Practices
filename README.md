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
./install.sh                              # Release app into /Applications, CLI into $PRACTICES_HOME/bin
tools/build-dev.sh                        # Command Line Tools only, when xcodebuild is unavailable
cd PracticesCore && swift run practicesctl spaces
```

`./install.sh` **replaces the installed app and CLI**: it quits a running Practices, puts the
new build into `/Applications/Practices.app` and starts it, and overwrites
`$PRACTICES_HOME/bin/practicesctl` (default `~/.practices/bin`, linked from
`~/.local/bin/practicesctl`). It prints what it replaces first; the catalogue, secrets and
`local.yaml` are not touched.

Screens render offscreen for checking the layout — **Debug builds only** (a Release build
prints an error and exits): `Practices --render-window out.png [--welcome | --settings |
--space <id> | --project <id> | --doctor | --pending | --palette …]`. With `PRACTICES_HOME`
and `PRACTICES_AGENT_HOME` pointed at a scratch folder neither the catalogue nor the agents'
files of the real home are read or written; the CLI and MCP honour both variables too.

Tests (Swift Testing). With full Xcode selected: `swift test`. With the Command Line
Tools only, point the compiler at the Testing framework:

```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

## `practicesctl`

The output of `practicesctl --help` (copy it again when commands change):

```
usage: practicesctl <command> [--json]

catalogue (~/.practices/spaces/<space>, one git repository per space):
  spaces                        spaces: path, branch, uncommitted (the catalogue is personal:
                                each space is a local git repository, never shared)
  space add <id> [--name N] [--hosting host/owner …]
  projects [space]              the tree of projects with their repositories and services
  project <id>                  one project: repositories (role, local clone), services, chains
  project add <space>/<id> [--parent <project>] [--name N] [--description D]
  project hosts <id> [<condition>…]   the servers it is deployed on: conditions of its space
                                (none given — clears the list)
  conventions <space> [--templates]   the owner's rules for repositories (conventions.md) and
                                the paths of templates/ (--templates: with their contents)
  repos [--all]                 not assigned to any project: from gh / glab by the spaces'
                                hosting, plus local clones (--all: ignored ones too)
  assign <repo> <project> [--role r]     repo = a remote address in any form
  unassign <repo>
  remove-project <id> [--keep-repos]   delete a project and its services; its repositories go to the
                                space's ignore list unless --keep-repos (refused while it has child projects)
  ignore <repo> [--space id]    keep a repository out of `repos` (the space is the one whose
  unignore <repo> [--space id]  hosting lists it, unless given)
  services [project]            services, their environments and key status
  service <id>                  one service: endpoints, conditions, links, keys, notes, docs
  service add <id> --project <p> [--name N] [--kind k] [--description D] [--repo r]
                                [--alias a …] [--env e …] [--key K …]
  links [service]               who calls whom (of one service: both directions)
  link add <from> <to> [--endpoint e] [--env e] [--via http|topic|db|network|build]
                                [--what w] [--access read|write] [--why w] [--practice ref]
                                [--file f] [--as VAR=KEY …] [--origin o] [--no-commit]
                                --origin: manual (default), code:<file> where the call is seen
                                (what agents pass); --no-commit leaves it for `accept`
  link reject <from> <to> [--via v] [--what topic] --why "…" [--origin o] [--no-commit]
                                the link was checked and is false: it leaves links.yaml, goes to
                                rejected.yaml, and `scan` no longer offers it (origin: manual,
                                code:<file>, audit:<report>)
  link unreject <from> <to> [--via v] [--what topic] [--no-commit]
  conditions [space]            named conditions and who requires them
  condition add <space>/<id> --name N [--hint H] [--reachable TEMPLATE]
                                TEMPLATE = host:port over the service's keys, e.g. '${PG_HOST}:${PG_PORT}'
  scan [project | repo]… [--write] [--all]   services and links the clones' compose files and
                                example env files give, against the catalogue (default: every
                                assigned clone); --write leaves the new ones uncommitted for
                                `accept`; links refused before are counted, --all lists them
  pending                       uncommitted changes in the spaces (an agent's edits)
  accept [space [path…]] [--message m]   commit them: all, one space's, or the given files
  discard <space> <path…>       drop them: a new file is deleted, an edited one restored

values and checks:
  check [ref…]                  endpoints and conditions of services (all by default)
  secrets set <id> <KEY> [--env e]    value read from stdin, never from arguments
  secrets unset <id> <KEY> [--env e]
  secrets import <id>@<env> [--from <.env>] KEY=THEIR_KEY | KEY:=value | KEY=env:<other env> …
                                fill an environment (adding it if new); values are never printed
  env <ref…>                    names of the variables `run` would set (no values)
  run <ref…> -- <command…>      run a command with the services' values in its environment
  doctor                        .env files and plain text under the search roots against the registry
  connect <ref…> --to <file> [--project dir] [--as VAR=KEY…] [--only KEY,KEY]
                                write services' values into a project's env file, once;
                                refuses files git would commit (--force)

  ref = <service>[@<env>]

practices:
  practices [service]           practices and chains
  sig <practice>                parameters of a practice's run()
  try <practice> [k=v…] [--env service=env…] [--rows N]
                                run it and print the result (a table, a tree or text)
  runs <practice>               its run history: version, time, rows
  search <text>                 services (id, name, kind, alias, description), fields, practices
                                whose result has it, docs, code
  copies [practice]             copies under the search roots found by their marker: current / outdated / modified

this machine (~/.practices/local.yaml, agents' settings; never in git):
  roots                         folders where clones are looked for, with the clones found
  roots add <path>… | roots remove <path>
  setup status [--json]         roots, spaces, agents: MCP registered,
                                instruction block absent / current / outdated, project clones with it
  setup roots <path>…           = roots add, for the first run
  setup agents --global | --projects [--tools claude,codex,cursor] [--no-mcp] [--no-instructions]
                                register the MCP server for the tools found (~/.claude, ~/.codex,
                                ~/.cursor) and write the instruction block: --global into
                                ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md, --projects into CLAUDE.md
                                and AGENTS.md of every clone of the catalogue's projects;
                                with neither, asks (in a terminal)
  setup agents --project <id>   the block into CLAUDE.md and AGENTS.md of the project's clones

agent:
  mcp                           MCP server on stdin/stdout

  practice = <service>/<name> | chains/<name>
```

`--json` on the listing commands prints machine-readable output.

**MCP.** `practicesctl setup agents` registers the server with Claude Code, Codex and Cursor;
the command it registers is `$PRACTICES_HOME/bin/practicesctl mcp` (`~/.practices/bin/…` by
default), where `./install.sh` puts the binary. After a manual `swift build -c release` the
binary is `PracticesCore/.build/release/practicesctl`, with
`PracticesCore_PracticesCore.bundle` beside it: copy both into `$PRACTICES_HOME/bin` (or run
`./install.sh`) before registering. Claude Code's `~/.claude.json` is read and written back
whole: its content is kept, but the file is re-serialised (pretty-printed, keys sorted).

**Python.** Practices run in their own environment, `$PRACTICES_HOME/runtime`: its files
come with the CLI and app, and `uv sync` builds the `.venv` there the first time a practice
runs (`try`, `run_practice`, the Run button) or when «Настройка → Окружение → Обновить» is
pressed; it is synced again when the bundled `pyproject.toml` changes. Until then «Настройка»
shows «python: не установлено». `uv` comes from Homebrew (`./install.sh` installs it).

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
practicesctl project add <space>/<project>         # проект в нём
practicesctl repos                                 # репозитории, ещё не разложенные по проектам
practicesctl assign <repo> <project>               # репозиторий — в проект
practicesctl scan <project> --write                # сервисы и связи из клонов, ждут `accept`
practicesctl setup agents --global | --projects    # MCP для Claude Code, Codex, Cursor; блок инструкций — Claude Code и Codex
```

Куда писать инструкции агентам — глобально (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`) или в
каждый проект (CLAUDE.md и AGENTS.md клонов) — решает пользователь; агент спрашивает, прежде чем
вызывать. Блок живёт в одном месте: запись глобально убирает его из клонов, запись в проекты — из
глобальных файлов. Новое пространство получает `conventions.md` и `templates/` по умолчанию — правила
ведения репозиториев, которые агенты читают через `get_conventions`; правьте их под себя.
