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

## Verified `pi` behaviors this app depends on

These were confirmed by driving a real `pi --mode rpc`, not read off the docs. They
are the assumptions most likely to break on a pi upgrade:

- **`--session <file>` resumes in RPC mode**, and `get_entries` returns the resumed
  session's full entry tree plus its `leafId`.
- **pi refuses to resume a session whose recorded `cwd` no longer exists**, exiting
  with an explanatory message on stderr. The app resumes each thread in the directory
  recorded in its session header for exactly this reason, and surfaces pi's stderr
  when startup fails.
- **The active leaf is the last entry in file order**, not the newest timestamp. A
  session whose final line is on an abandoned branch still reports that branch as
  active. The offline fallback in `SessionTree.defaultLeafID` matches this
  deliberately; a "smarter" rule would show a different conversation than pi does.
- **`messageCount` is branch-scoped.** A branched session holds every path ever
  explored; pi counts only the active one, and so does the sidebar.
- **A prompt can be accepted and still fail.** With no usable credentials pi rejects
  the command outright (`success: false`, with multi-line guidance that is shown
  verbatim). But when credentials exist and the *provider* rejects the call, the
  prompt is accepted and the failure arrives later on the event stream: `turn_end`
  carries an assistant message with `stopReason: "error"`, an `errorMessage`, and
  empty content. Both paths are handled; treating only the first as failure would
  make a failed run report as a normal finish.
- **Closing stdin does not always end the process**, so shutdown falls back to
  `SIGTERM` after a grace period.
- **`session_info_changed` is emitted but undocumented** in the RPC event table.

## Notes and current limits

- **The integrated terminal is line-oriented.** It runs a login shell on a real PTY
  and handles newlines, carriage returns, backspaces and colour codes, which covers
  builds, tests, git and package managers. It is not a full VT emulator, so
  full-screen programs (`vim`, `top`) will not render correctly.
- **Multi-agent orchestration** (a thread supervising child threads) is present in the
  Electron app and not yet ported here.
- **Theme presets and the skills/extensions manager** are not yet ported. The app
  follows the system appearance, and skills and extensions are configured through
  `pi` itself.
- **`@`-mention file completion in the composer** is not yet ported. Attaching images
  works by drag-and-drop or the paperclip button; pasting an image from the clipboard
  is not yet handled.
- **Run-finished notifications** fire only when the app is in the background, on
  `agent_settled` rather than `agent_end`, so a run that retries internally does not
  notify twice.

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
