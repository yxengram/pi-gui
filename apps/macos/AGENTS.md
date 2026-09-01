# macOS App Guidelines

Apply these rules for changes under `apps/macos/`.

- This is the native Swift rewrite of the Electron app in `apps/desktop/`. Same
  product — a Codex-style shell for `pi` — with the same delegation boundary: `pi`
  does the agent work, this app is the surface.
- The app drives `pi --mode rpc` as a subprocess and speaks pi's documented JSONL
  protocol. Do not reimplement agent behavior, session persistence, provider auth or
  model configuration locally; ask `pi` to do it.
- `pi`'s JSONL session files stay the source of truth for transcripts. Rebuild the
  timeline from pi's entries rather than assembling a local copy that can drift.
- Keep `PiCore` free of AppKit and SwiftUI. It is the layer that can be tested
  headlessly, so protocol, session, git and terminal parsing logic belongs there and
  view code does not.
- Payload shapes owned by pi (agent messages, model descriptors, tool arguments) are
  carried as `JSONValue`. Turning them into local structs forks upstream's schema and
  breaks on pi releases.
- Tests must run against fixtures captured from the real `pi` and real `git`, not
  hand-written approximations. When you add a protocol path, capture its output.
- Unknown RPC events and unknown session entry types must degrade to "not displayed",
  never to a dropped connection or a failed parse.
