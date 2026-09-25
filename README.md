# Practices

**One place for the data sources a developer works with, and a watch on the containers
and ports of every local project.** A personal macOS app: a menu-bar agent plus a window.

- **Sources and practices** *(stages 2–4, not built yet)* — every database and API is a
  source with its credentials, documentation and notes. Under each source live
  *practices*: named cells of code ("fetch device data") with a Run button, a readable
  result (table, JSON tree, text), timings and version history. Practices are copied into
  projects; an MCP server lets the agent working in a project read them and send
  improvements back.
- **Monitor** *(stage 1)* — who holds which port, which container quietly
  died, and stop / kill / logs for the ones a terminal will not stop. Works with OrbStack
  or Docker Desktop through the `docker` CLI and its active context.

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
cd PracticesCore && swift run practicesctl ports
```

Tests (Swift Testing). With full Xcode selected: `swift test`. With the Command Line
Tools only, point the compiler at the Testing framework:

```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

## `practicesctl`

```
practicesctl ports          occupied TCP ports and who holds them
practicesctl containers     containers, failed ones first
practicesctl conflicts      ports compose files in ~/Projects want that something holds
practicesctl watch          container incidents as they happen
practicesctl logs <name>    last 200 log lines
```

`--json` on any of them prints machine-readable output.
