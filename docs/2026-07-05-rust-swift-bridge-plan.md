# Rust <-> Swift bridge plan: start from the working swift-rs toolchain

## Decision (revised)

We already have a **working, in-production** Rust <-> Swift bridge built on `swift-rs`, at
`../makertime/screen-ocr-swift-rs` (consumed by `../makertime/screentap-app/src-tauri`). It's not
a prototype — it ships `screen_capture_swift`, `perform_ocr_swift`, `resize_image_swift`, etc.,
across the exact same kind of boundary we need (primitives, strings, and raw byte buffers in/out
of Swift, calling into system frameworks including Metal-adjacent ones like Accelerate/vImage).

**Plan: copy this toolchain wholesale for Qwen3-TTS, adapt it to call MLX instead of
Vision/ScreenCaptureKit, and defer `swift-bridge` entirely.** The earlier plan
([2026-07-05-rust-swift-bridge-plan.md] draft, since superseded by this revision) was written
before we had a proven reference to copy from; re-deriving a `swift-bridge` pipeline from scratch
is strictly more work and more risk than adapting one that already builds and ships. `swift-bridge`
stays on the table as a later migration, only if `swift-rs`'s type constraints (no NSObject-free
structs, no callbacks) become a real blocker — see "When to revisit swift-bridge" below.

## The toolchain, concretely (already proven in this repo family)

```
cargo build (in screentap-app/src-tauri)
    │
Cargo dependency: screen-ocr-swift-rs = { path = "../../screen-ocr-swift-rs" }
    │
screen-ocr-swift-rs/build.rs
    │  SwiftLinker::new("10.15").with_package("vision-swift", "./vision-swift/").link()
    │
shells out to `swift build` on vision-swift/ (a plain SwiftPM package, no Xcode project)
    │
static library + required Apple framework links emitted via cargo:rustc-link-*
    │
screen-ocr-swift-rs/src/lib.rs: swift!(fn ... ) declarations wrap the @_cdecl exports,
    return SRString / SRData / Option<SRData> / Bool / Int / Float / Double
    │
consumers (screentap-app/src-tauri/src/*.rs) just do
    `extern crate screen_ocr_swift_rs;` and call the plain Rust functions
```

Concrete files to use as the copy source:
- `screen-ocr-swift-rs/Cargo.toml` — `swift-rs = "1.0.6"` as both a normal and `[build-dependencies]`
  (with `features = ["build"]`) entry.
- `screen-ocr-swift-rs/build.rs` — three-line `SwiftLinker` call, nothing else.
- `screen-ocr-swift-rs/vision-swift/Package.swift` — `.macOS(.v10_15)` platform, `.library(type:
  .static)` product, depends on `SwiftRs` package product.
- `screen-ocr-swift-rs/vision-swift/Sources/vision-swift/vision_swift.swift` — the `@_cdecl(...)`
  function pattern, including the `Option<SRData>` / `Option<SRString>` return pattern we need for
  optional audio output.
- `screen-ocr-swift-rs/src/lib.rs` — the `swift!(fn ...)` declarations and thin safe wrappers
  (e.g. `resize_image` converts `&[u8]` → `SRData::from(png_data)` → call → `.to_vec()`, which is
  exactly the shape a `synthesize(text) -> Vec<u8>` WAV function needs).
- `screentap-app/src-tauri/Cargo.toml` + call sites (`screenshot.rs`, `compaction.rs`, `db.rs`,
  `focusguard/mod.rs`) — the pattern for a Tauri app consuming a local-path Swift-bridge crate.

## Risk ranking (revised — most of the old unknowns are now resolved by precedent)

| Risk | Concern | Status |
| --- | --- | --- |
| 🟢 | Calling Metal-adjacent Apple frameworks from a plain SwiftPM package built via `swift build` | Already proven (`vision-swift` uses Accelerate/vImage; MLX is a similarly plain SwiftPM dependency) |
| 🟢 | `cargo build` transitively triggering `swift build` with no manual step | Already proven end-to-end in `screentap-app` |
| 🟢 | Passing text in / raw byte buffers out (`SRString`, `SRData`, `Option<SRData>`) | Already proven (`perform_ocr_swift`, `resize_image_swift`, `screen_capture_swift`) |
| 🟡 | Whether `mlx-swift-qwen3-tts` specifically bundles any *pre-compiled* `.metal` resource file requiring SwiftPM resource-bundling (as opposed to Apple-framework calls, which `vision-swift` already proves work) | **Not yet proven** — this is the one real unknown carried over from the earlier analysis, and the only reason `swift-only-poc` needed `xcodebuild` instead of `swift build` |
| 🟡 | Streaming audio chunk delivery (no precedent in `vision-swift` — its functions are all single call-in/call-out, no callbacks) | Needs new design |
| ⚪ | `swift-bridge` maintenance/complexity | Deferred — not in scope unless we hit a real `swift-rs` limitation |

## Step-by-step plan

### Step 1 — Copy the toolchain shape into a new crate
Create `qwen3-tts-swift-rs/` (sibling to `hamptus-mlx-swift-qwen3-tts/`, mirroring
`screen-ocr-swift-rs`'s position next to `screentap-app`) by copying:
- `Cargo.toml`, `build.rs` verbatim (just rename the package path in `with_package`).
- An empty-ish `vision-swift`-shaped SwiftPM package (`qwen3-tts-swift/Package.swift`), same
  `.library(type: .static)` + `SwiftRs` dependency shape, but with a placeholder `@_cdecl` function
  (e.g. a version of `get_frontmost_app_swift`'s trivial string-return pattern) to first prove the
  copied toolchain builds and links before touching MLX at all.

### Step 2 — Add the MLX/Qwen3TTS dependency to the copied package
Add `mlx-swift-qwen3-tts` as a dependency of `qwen3-tts-swift`'s `Package.swift` (same
`.package(url:from:)` shape already used for `SwiftRs` itself). Expose a minimal
`@_cdecl("load_model_swift")` function that just loads `Qwen3TTSPipeline(modelPath:)` and returns
a `Bool`, built via the copied `build.rs` (plain `swift build`, no `xcodebuild`). This isolates
"does MLX link and run under the already-proven `swift-rs` pipeline" before adding any audio
generation.

### Step 3 — The decisive test: non-streaming synthesize end-to-end
Add `@_cdecl("synthesize_swift")` returning `Option<SRData>` (mirroring `resize_image_swift`'s
`Option<SRData>` pattern exactly), wrapping the POC's already-validated non-streaming generation
path. Declare it in Rust with `swift!(fn synthesize_swift(text: &SRString) -> Option<SRData>)` and
a thin wrapper returning `Option<Vec<u8>>`, mirroring `resize_image`'s `.to_vec()` pattern. Build
with the copied `build.rs` (`swift build`, no `xcodebuild`).

If this produces valid audio bytes end-to-end via plain `cargo build`, the copied toolchain is
fully validated for Qwen3-TTS and the one open risk (Metal resource bundling under `swift build`)
is resolved in our favor.

### Step 4 — Fallback, only if Step 3 fails on resource bundling specifically
If (and only if) Step 3 fails at *runtime* with a missing-shader/metallib error (not a compile
error):
1. Check `mlx-swift-qwen3-tts`'s own `Package.swift` for how it declares Metal resources; a missing
   `resources: [.process(...)]` declaration may be fixable upstream-side without touching our build.
2. If not fixable there, replace only the `Command::new("swift").arg("build")` step inside a forked
   copy of `SwiftLinker` (or a custom `build.rs` step) with `xcodebuild`, keeping everything else
   from the proven toolchain unchanged. Scope this narrowly — don't introduce `xcodebuild` for the
   whole project if only this one package needs it.

### Step 5 — Design streaming (no precedent to copy — new design work)
`vision-swift` has no callback pattern to borrow from, since every one of its `@_cdecl` functions
is a single call-in/call-out. For chunked audio we need Swift to push chunks as they're generated.
Options to evaluate, cheapest first:
1. **Polling**: Swift accumulates chunks into an internal buffer; Rust calls a
   `@_cdecl("next_chunk_swift") -> Option<SRData>` in a loop from a background thread/tokio task,
   same `Option<SRData>` shape as Step 3, just called repeatedly. No new swift-rs capability needed
   — this is just Step 3's pattern called in a loop, which is why it should be tried first.
2. **Callback via raw function pointer**: pass a C function pointer into a hand-written (non-macro)
   `@_cdecl` function that invokes it per chunk. This bypasses `swift-rs`'s `swift!` macro (which
   doesn't model callbacks) but doesn't require abandoning `swift-rs` for everything else — the
   macro and hand-written `extern "C"` declarations can coexist in the same crate.
Prefer option 1 unless it can't hit acceptable latency, since it requires zero new FFI surface
beyond what Step 3 already proves.

### Step 6 — Wire into the real Tauri app
Mirror `screentap-app`'s consumption pattern exactly: add
`qwen3-tts-swift-rs = { path = "../../qwen3-tts-swift-rs" }` to
`hamptus-mlx-swift-qwen3-tts/src-tauri/Cargo.toml`, `extern crate qwen3_tts_swift_rs;` in the
relevant module, call the plain Rust wrapper functions from Tauri commands.

### Step 7 — Verify against a packaged app, not just `cargo run`
Run both a dev build and a signed release `.app` bundle. If Step 4's fallback ladder was needed,
this is where a resource-bundling gap not caught by `swift build` locally would most likely surface
(same class of issue `swift-only-poc` hit, needing `DYLD_FRAMEWORK_PATH` when running outside
Xcode's own run mechanism).

## When to revisit swift-bridge

Only reconsider `swift-bridge` if we hit something `swift-rs`'s type system genuinely can't
express even with workarounds — e.g. if the callback-based streaming design in Step 5 proves
unworkable, or if we need to pass richer structured data (enums, nested structs without an
`NSObject` wrapper) across the boundary in volume. Given the proven toolchain covers our actual
surface area (text in, bytes out, optionally polled in a loop), we don't expect to need this.

## Explicitly out of scope for this plan

- Voice cloning, ICL, VoiceDesign, CustomVoice features.
- Any UI beyond a minimal test harness for the bridge itself.
- Migrating `screen-ocr-swift-rs`/`screentap-app` to anything — they're a reference only, not
  touched by this work.

## Success criteria

- `cargo build` alone (no `xcodebuild`) in the new `qwen3-tts-swift-rs` crate produces a static
  library that loads the model and returns synthesized WAV bytes to Rust.
- The same crate, consumed by `hamptus-mlx-swift-qwen3-tts/src-tauri` exactly as
  `screen-ocr-swift-rs` is consumed by `screentap-app/src-tauri`, works end-to-end via
  `cargo tauri build`/`cargo tauri dev` with no manual build steps.
- Streaming (via polling `next_chunk_swift` first, callback only if needed) delivers a first chunk
  meaningfully faster than waiting for the full buffer, consistent with what `swift-only-poc`
  already measured.
- The packaged, signed `.app` runs standalone (double-click), not only from a terminal with
  hand-set environment variables.

## Open questions to resolve during execution

1. Does `mlx-swift-qwen3-tts` bundle any raw `.metal` source requiring SwiftPM resource processing,
   or does it compile shaders from embedded strings / ship a precompiled `metallib` as an
   already-correctly-declared package resource? (Determines whether Step 4 is ever needed.)
2. Is polling latency (Step 5, option 1) low enough for acceptable time-to-first-audio, or is the
   callback/function-pointer approach (option 2) required?
3. Minimum macOS version to target in `SwiftLinker::new(...)` and `Package.swift` — `vision-swift`
   uses `10.15`; MLX likely requires a materially newer minimum (`swift-only-poc` targets
   `.macOS(.v14)`), which changes the `SwiftLinker::new(...)` argument and `Package.swift`
   `platforms:` entry accordingly.
