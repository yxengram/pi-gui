# Repo Guidelines

These rules apply for the full session.

## Workflow
- Define success criteria before coding; if unclear, stop and clarify.
- For non-trivial work, plan verification up front with the `self-test` skill.
- Do not create or switch to new branches to start work unless the user explicitly asks; respect the current branch or worktree as intentional.
- Commit in small focused checkpoints; don’t batch unrelated changes.
- Run `simplify` before closing non-trivial implementation work.

## Product
- This repo is building a Codex-style desktop app for `pi`; preserve that product direction.
- Desktop work is not done until it is verified on the real Electron surface, not only by unit tests.
- Transcript/timeline behavior, session correctness, and Codex-style UX are product features, not polish.
- Prefer clean reimplementation over patching around local complexity.

## Safety
- Never delete user session history, cached transcripts, screenshots, or temp artifacts without approval.
- Treat files you didn’t edit as read-only when multiple agents may be working.
- Ask before destructive commands or history rewrites.

## Structure
- Prefer path-scoped guidance in nested `AGENTS.md` files over growing this file.
- Keep the desktop renderer/main/preload boundary tight; avoid broad Node exposure to the renderer.
- Keep `pi-sdk-driver` thin over `pi-mono`; don’t fork or reimplement `pi` runtime behavior unless necessary.

## Commands

Node 20+ with pnpm via `corepack enable`. `.npmrc` pins `node-linker=hoisted` for Electron native modules (`node-pty`), so don't switch linker modes casually.

- `pnpm dev` — desktop app through electron-vite; the launcher (`apps/desktop/scripts/dev.mjs`) builds `session-driver`, `catalogs`, and `pi-sdk-driver` first, then keeps them in watch mode.
- `pnpm typecheck` — builds `session-driver` → `catalogs` → `pi-sdk-driver` *before* recursing, because each package consumes the others' emitted `dist/`. A bare `tsc` in one package fails until those builds exist.
- `pnpm lint` currently resolves to nothing: no workspace defines a `lint` script and the repo has no ESLint config. Don't report it as a passing gate.
- `pnpm test` recurses; the desktop's `test` is the Electron `core` E2E lane, which builds the app first.

Testing:

- Desktop lanes and every targeted spec script live in `apps/desktop/package.json`; lane selection rules are in `apps/desktop/tests/AGENTS.md`.
- One spec ad hoc: `pnpm --filter @pi-gui/desktop run test:e2e:runner -- apps/desktop/tests/core/<name>.spec.ts`.
- Driver unit tests: `pnpm --filter @pi-gui/pi-sdk-driver test` (`node --test` over `test/**/*.test.mts`).
- CI (`.github/workflows/ci.yml`) runs typecheck, driver tests, changed-file adapter tests, and release-verify scripts on Linux; the `core` E2E lane runs **only** on macOS; the Linux and Windows jobs only package and verify runtime deps.

## Architecture

`README.md` has the product overview. The parts that need several files to see:

- **The main process owns all state.** `DesktopAppStore` (`apps/desktop/electron/app-store.ts`, split across `app-store-*.ts` modules behind the `AppStoreInternals` interface in `app-store-internals.ts`) is the single source of truth and publishes `DesktopAppState` snapshots. The renderer is a projection; it holds no authoritative session state.
- **Two publish paths, and both are per-window.** App state rides `state-changed`; the selected session's transcript is published separately over `selected-transcript-changed`, so timeline payloads don't ride on every state emit. Each window keeps its own view (`windowViews`, keyed by `webContents.id`) and receives a projection of the shared store, so multi-window selection stays independent — never assume one global selected session in main.
- **The IPC contract is one shared file.** `apps/desktop/src/ipc.ts` holds the channel names (`desktopIpc`) and the `PiDesktopApi` type, imported by renderer, preload, and main. `electron/preload.ts` exposes exactly that surface as `window.piApp`. New renderer capability means a new typed channel there — not broader Node access.
- **Driver layering.** `packages/session-driver` is pure contract (`SessionDriver`, the event union, snapshot types). `packages/pi-sdk-driver` is the only place that drives `@earendil-works/pi-coding-agent`: `SessionSupervisor` manages live sessions, `PiSdkDriver` implements the contract. `packages/catalogs` holds workspace/session catalog types. The desktop's own direct imports from the `pi` SDK are limited to extension/tool authoring types (`orchestration-runtime.ts`, `main.ts`).
- **`pi`'s JSONL session files are the transcript source of truth.** Closed sessions are read back from `pi`'s file rather than a divergent cache; the supervisor tracks its mtime and reconciles, and the store re-publishes a transcript only when the file actually changed. Advisory `.lease` files (`session-lease.ts`) keep two surfaces from binding the same session — dead or self-owned leases never block.
- **Desktop-owned state** lives under Electron `userData` (override with `PI_APP_USER_DATA_DIR`): `catalogs.json`, `ui-state.json` (versioned, atomic writes with `.bak` recovery), `attachments/`, and `worktrees/` — the root for per-thread git worktrees created by `GitWorktreeManager`.
- **Multi-agent orchestration** is an extension registered into the runtime (`orchestration-runtime.ts`) whose tools are handled in `app-store-orchestration.ts`; child threads are real sessions, supervised on a timer.
- **Test seams.** `PI_APP_TEST_MODE` (`background` | `foreground`) selects windowing behavior, and with it set the main process installs `globalThis.__PI_APP_TEST_HOOKS` for the Playwright harness. Shared harness helpers are in `apps/desktop/tests/helpers/electron-app.ts` — extend them rather than adding a second harness.

## Source Of Truth
- Root `AGENTS.md` is the repo instruction source of truth.
- Root `CLAUDE.md` should remain a symlink to `AGENTS.md`.
