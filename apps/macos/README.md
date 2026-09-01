# pi-gui for macOS (Swift)

A native macOS app for [`pi`](https://github.com/earendil-works/pi), written in Swift
and SwiftUI. It is the same product as the Electron app in [`apps/desktop`](../desktop):
a Codex-style desktop shell for `pi`, with a threaded timeline, git worktrees per
thread, an inline diff viewer and an integrated terminal.

## How it relates to `pi`

This app is a **shell over the `pi` CLI**. It does not embed an agent runtime.

Each thread spawns `pi --mode rpc` in the thread's working directory and talks to it
over pi's documented JSONL protocol on stdin/stdout. Prompts, model changes, session
navigation and shell execution are all commands on that pipe.

```
┌────────────┐   JSONL over stdin/stdout   ┌──────────────────┐
│  pi-gui    │ ──────────────────────────► │ pi --mode rpc    │
│ (SwiftUI)  │ ◄────────────────────────── │ (one per thread) │
└────────────┘   responses + events        └──────────────────┘
       │                                            │
       │ reads                                      │ writes
       └──────────► ~/.pi/agent/sessions/*.jsonl ◄──┘
```

Consequences that are features, not accidents:

- **Your `pi` setup carries over.** Providers, API keys, models, skills and extensions
  are configured with `pi` itself and shared with the `pi` command in your terminal.
  This app deliberately stores no credentials.
- **Sessions are interchangeable.** A thread started here is an ordinary pi session
  file; open it later with `pi --session`. A session started in the terminal shows up
  in the sidebar.
- **pi's files are the source of truth.** The transcript is rebuilt from pi's own
  entries rather than from a private copy that could drift.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/PiCore` | Foundation-only core: RPC client, session parsing, git plumbing, terminal screen. No AppKit/SwiftUI, so it is testable headlessly. |
| `Sources/PiGUI` | The SwiftUI app: sidebar, timeline, composer, diff panel, terminal, settings. |
| `Tests/PiCoreTests` | XCTest suite. Fixtures are captured from a real `pi` and a real `git`. |
| `Scripts/make-app.sh` | Builds and assembles a launchable `.app` bundle. |

## Requirements

- macOS 14 or later
- Swift 5.9+ (Xcode 15+)
- `pi` on your `PATH` (`npm i -g @earendil-works/pi-coding-agent`), or set an explicit
  path in **Settings → pi**

> An app launched from Finder or the Dock does not inherit your login shell's `PATH`,
> so pi-gui searches the usual install roots (Homebrew, mise, volta, asdf, bun, npm)
> as well. If `pi` still isn't found, point at it in Settings.

## Build and run

```bash
cd apps/macos
swift build                 # build
swift test                  # run the PiCore test suite
swift run PiGUI             # run without bundling (no Dock icon or menu bar)
./Scripts/make-app.sh       # assemble build/pi-gui.app
open build/pi-gui.app
```

Run a single test or one suite:

```bash
swift test --filter JSONLFramerTests
swift test --filter TimelineBuilderTests/testToolCallIsJoinedWithItsResult
```

## Notes and current limits

- **The integrated terminal is line-oriented.** It runs a login shell on a real PTY
  and handles newlines, carriage returns, backspaces and colour codes, which covers
  builds, tests, git and package managers. It is not a full VT emulator, so
  full-screen programs (`vim`, `top`) will not render correctly.
- **Multi-agent orchestration** (a thread supervising child threads) is present in the
  Electron app and not yet ported here.
- **Notifications, theme presets and the skills/extensions manager** are not yet
  ported; skills and extensions are still configured through `pi`.

## Regenerating test fixtures

Fixtures under `Tests/PiCoreTests/Fixtures` are real output, captured rather than
written by hand:

- `get_*.json`, `bash.json`, `event_*.json` — responses and events from a live
  `pi --mode rpc` process.
- `status-porcelain-z.bin`, `kept.diff`, `worktree-list.porcelain.txt` — output from a
  real `git` in a repo with a rename, a delete, a staged add, an untracked path
  containing spaces, and a linked worktree.
- `session-branching.jsonl` — a session file whose bookkeeping and `bashExecution`
  entries are verbatim from a real run, extended with a branching conversation in the
  documented v3 format so branch selection and tool-result joining are exercised.

When pi's protocol changes, recapture rather than editing the JSON by hand — the point
of these files is that they are ground truth.
