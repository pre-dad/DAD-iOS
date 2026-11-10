# Agent guide — DAD-iOS

SwiftUI donor app built against a vendored snapshot of DAD-Main's API contract. Start with
these; this file only adds what they do not say.

- **[README.md](README.md)** — build/test (`bash scripts/check-ios.sh`), the shared
  contract and native boundaries, contract updates, release readiness.
- Cross-repo system docs (topology, the mobile contract, re-vendor model) live in the
  separate **DAD-Docs** repo. Read the mobile contract before any contract change.
- **[Shared agent workflow](https://github.com/pre-dad/DAD-Docs/blob/dev/conventions/agent-workflow.md)** —
  read DAD-Docs for skill setup, routing, and independent-review boundaries. Keep
  shared procedures there; this guide owns repo-local commands and constraints.

## Build and test

- `node scripts/prepare-client.mjs` then the Xcode/CI path in the README.
- Unit tests alone: `swift test`. **The App target only compiles under `xcodebuild` on
  CI** — `swift test` cannot catch an App-target or UITest compile break. CI is the gate.

## Branch and push discipline

- Work on `dev`; ship via `dev` → PR → `main`. Never push to `main` directly.
- Run `git commit` and `git push` as two separate commands.

## Code comments

- Comments explain **why** (a constraint, a trade-off, a non-obvious behavior), not what the
  code already says.
- No commented-out code (git keeps history). A `TODO` names a tracked issue.

## Gotchas not written in the docs

- **`App/DADApp.swift` is a large hand-structured file — inserts are brace-error-prone.**
  An insert landing one brace early swallows the previous declaration's closing `}`;
  over-correcting flips "unexpected `}`" to "expected `}` at EOF". After **any** insert,
  verify brace balance of each affected struct region (strip comments/strings, count `{}`
  delta == 0 per region and across the inserted span) **before** pushing. `swift test`
  will not catch this.
- **`DAD.xcodeproj/project.pbxproj` is hand-written with fixed 24-char hex IDs** (not
  synchronized groups). A new source/UITest file is NOT compiled unless you add **four**
  entries: a `PBXFileReference` (next free hex id), a `PBXBuildFile` referencing it, the
  file-ref id into `mainGroup` children, and the build-file id into the correct target's
  Sources phase (DADUITests sources phase is `000000000000000000000015`). Validate with
  `plutil -lint DAD.xcodeproj/project.pbxproj` (expect `OK`).
- **Vendored contract is hash-locked.** `foundation.lock.json` pins version + 40-char
  source revision + manifest sha256; `scripts/check-foundation.mjs` verifies every file.
  Re-vendoring requires an **actual tagged** DAD-Main mobile-foundation release — bump the
  version+rev+hash triple, copy the files, widen the generator allow-list for new ops,
  regenerate, run check-foundation + build. Never fetch a moving branch at build time.
- **Generator chokes to expect:** Swift generator trips on `anyOf` + `type: null` and
  enforces `additionalProperties: false`; handled by the per-app null adapter
  (`DADNullValue.swift`) + generator override. New nullable shapes may need the same.
- **The synthetic preview session is DEBUG-gated** (`#if DEBUG` … `#else throw
  AccountError.invalidConfiguration`) so a release build with an unconfigured origin never
  serves synthetic data as real. Keep that guard on any new session fallback.
- **Never track working documents.** Plans/findings/notes go in git-ignored `docs/`.
