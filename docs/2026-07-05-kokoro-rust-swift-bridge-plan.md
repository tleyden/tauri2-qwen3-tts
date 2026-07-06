# Kokoro-TTS Rust <-> Swift bridge plan: copy the proven Qwen3-TTS playbook

## Decision

Copy the exact toolchain shape that already works for `qwen3-tts-swift-rs` (documented in
[2026-07-05-rust-swift-bridge-plan.md](2026-07-05-rust-swift-bridge-plan.md), and itself copied
from the in-production `screen-ocr-swift-rs`) into a **new sibling crate `kokoro-tts-swift-rs/`**,
wired into the already-scaffolded (but untouched, `create-tauri-app`-stub) `kokoro-mlx-swift-tts/`
app the same way `qwen3-tts-swift-rs` is wired into `hamptus-mlx-swift-qwen3-tts/src-tauri`.

**New crate, not shared code.** Kokoro's upstream Swift package (`mlalma/kokoro-ios`, product name
`KokoroSwift`) differs from `mlx-swift-qwen3-tts` in several load-bearing ways (library product
type, model file layout, no built-in speaker enum — see "What's different from Qwen3" below). A
separate crate keeps every one of those differences isolated behind its own `build.rs`/`Package.swift`,
so nothing about it can break the working Qwen3 crate. The two crates will share no code; they'll
just look structurally identical, the same way `qwen3-tts-swift-rs` and `screen-ocr-swift-rs` do.

## What's different from Qwen3 (verified directly against upstream source, 2026-07-05)

I fetched `mlalma/kokoro-ios`'s current `Package.swift` and `Sources/KokoroSwift/TTSEngine/KokoroTTS.swift`,
and `mlalma/KokoroTestApp`'s `TestAppModel.swift` (the reference consumer), not just the wiki
summary in the request. The wiki's code samples (`KokoroTTS.generateAudio(voice: .afHeart, text:)`,
an `ESpeakNG.xcframework`, MLX package products added directly to an Xcode project) describe an
**older** shape of this project. The current released package is materially simpler in one way
(no xcframework needed) and different in a few others:

| Aspect | Qwen3 (`mlx-swift-qwen3-tts`) | Kokoro (`kokoro-ios` / `KokoroSwift`), as of today |
| --- | --- | --- |
| SPM product type | `.static` (we controlled this — it's our own `qwen3-tts-swift` wrapper's declared type) | Upstream `KokoroSwift` product itself is declared `.dynamic` in its own `Package.swift` — not ours to change without forking. **New risk**, see below. |
| Min platform | `.macOS(.v14)` | Upstream declares `.iOS(.v18), .macOS(.v15)` — our wrapper's `SwiftLinker::new(...)` must say `"15.0"`, not `"14.0"`. |
| G2P / phonemizer | N/A | Default is `MisakiSwift` (pure Swift, pulled in as a normal SPM dependency — **no `ESpeakNG.xcframework` needed** for the default path; `eSpeakNGG2PProcessor.swift` exists in the source tree but its dependency is commented out in `Package.swift`, so it isn't compiled in unless we explicitly add it back). This resolves what the original analysis flagged as the main new risk (binary xcframework embedding) — turns out we don't need it. |
| Model loading | `Qwen3TTSPipeline(modelPath: URL)` where `modelPath` is a **directory** (config.json, safetensors, tokenizer files) | `KokoroTTS(modelPath: URL, g2p: G2P = .misaki)` where `modelPath` is the **safetensors file itself** (`kokoro-v1_0.safetensors`, ~600MB). Model hyperparameters (`config.json`) ship *inside* the `KokoroSwift` package's own bundled `Resources/`, not read from `modelPath`. |
| Voice/speaker selection | `Qwen3TTSPipeline.availableSpeakers: [String]`, built in | **Voices were deliberately moved out of the library in v1.0.5.** `KokoroTTS.generateAudio` takes a raw `voice: MLXArray` parameter — there is no enum, no `.afHeart` case, and no `availableSpeakers` API in the library itself. The reference app (`KokoroTestApp`) loads a separate `voices.npz` file via `MLXUtilsLibrary.NpyzReader.read(fileFromPath:) -> [String: MLXArray]` and picks a `Language` (`.enUS` if the voice name starts with `a`, else `.enGB` — only those two cases exist in the `Language` enum today) from the voice name's first letter. **We have to reimplement this same lookup ourselves** in the Swift wrapper. |
| Output | `pipeline.generate(text:speaker:) -> [Float]` samples, `AudioSampleWriter.write(...)` (WAV encoder) provided by the `Qwen3TTS` package itself | `generateAudio(voice:language:text:speed:) throws -> ([Float], [MToken]?)`. **No WAV writer is provided** — `Qwen3TTS`'s `AudioSampleWriter` is a Qwen3-specific utility, not something `KokoroSwift` or its dependencies ship. We must write a small (~40-line) mono 16-bit PCM WAV encoder ourselves inside the `kokoro-swift` wrapper package. |
| Sample rate | 24kHz mono (`Qwen3TTSPipeline`-defined) | 24kHz mono (`KokoroTTS.Constants.samplingRate == 24000`) — same shape, nothing to change downstream in Rust/Tauri/React. |
| Metal shader (`.metallib`) issue | Present (`mlx-swift`'s `Cmlx` target ships `.metal` sources with no SwiftPM `resources:` declaration; `swift build` never compiles them) | **Also present**, for the identical reason — `KokoroSwift` depends directly on the same `mlx-swift` (pinned to `0.30.2`), so the exact `xcodebuild`-for-metallib workaround in `qwen3-tts-swift-rs/build.rs` applies unchanged. |
| Non-Metal SwiftPM resource bundling | Not exercised — `qwen3-tts-swift`/`vision-swift` never declared their own `resources:` | **New, unproven risk.** `KokoroSwift`'s own target declares `resources: [.copy("../../Resources/")]` (this is where its bundled `config.json` lives), which compiles to a synthesized `Bundle.module` and a `KokoroSwift_KokoroSwift.bundle` directory. Unlike the Cmlx metallib, `swift build` *does* produce this bundle correctly (SwiftPM's own resource-copy step, no Xcode needed) — but whether `Bundle.module`'s runtime lookup succeeds when `KokoroSwift` is compiled into a static archive and linked into a plain Rust-built executable (not an app bundle) is untested. May need the same "copy the bundle next to the binary at startup" treatment as `mlx.metallib`. |
| Extra transitive dependency | — | `MLXUtilsLibrary` (used for `.npz` voice loading) pulls in `ZIPFoundation`. One more pure-Swift SPM dependency to resolve/build, no known risk, just noting it exists. |

## Model files (bootstrap source)

There's no ready-made "MLX-native Kokoro checkpoint" release the way Qwen3 shipped one. The
practical bootstrap path — already used by upstream's own reference app — is to pull the two files
`mlalma/KokoroTestApp` already ships (converted from `hexgrad/Kokoro-82M`'s PyTorch weights,
distributed via Git LFS in that repo):

- `Resources/kokoro-v1_0.safetensors` (~600MB)
- `Resources/voices.npz` (~14.6MB, an npz archive of per-voice style embeddings, e.g. `af_heart.npy`,
  `bm_george.npy`, keyed exactly like the original Kokoro-82M voice names)

Place both under `.models/Kokoro-82M-MLX/` at the repo root (sibling to the existing
`.models/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit/`), matching the existing `.models/` convention.

## Risk ranking

| Risk | Concern | Status |
| --- | --- | --- |
| 🟢 | Overall `cargo build` → `swift build` (via `SwiftLinker`) → static lib → `swift!()` macro toolchain shape | Already proven twice (`screen-ocr-swift-rs`, `qwen3-tts-swift-rs`) |
| 🟢 | `SRString`/`SRData`/`Option<SRData>` in/out, `libc++` link, `/usr/lib/swift` rpath (incl. needing to repeat the rpath line in the Tauri app's own `build.rs`) | Already proven and documented in `qwen3-tts-swift-rs` |
| 🟢 | `mlx-swift` Cmlx metallib missing under plain `swift build`, fixed via `xcodebuild`-only-for-the-metallib + `include_bytes!` + write-next-to-exe-at-startup | Already proven in `qwen3-tts-swift-rs/build.rs`; same fix applies verbatim since `KokoroSwift` pulls in the same `mlx-swift` |
| 🟡 | `KokoroSwift`'s own upstream product is `.dynamic`, not `.static`. Whether our wrapper package can still declare a `.static` product/target that statically links against it via plain `swift build` (matching `swift-rs`'s no-NSObject/no-callback but also implicitly static-lib-shaped model), or whether we end up needing to ship + rpath-link a `.dylib` alongside the Rust binary | **Not yet proven — the one real new unknown**, resolve in Step 1 before writing any TTS logic |
| 🟡 | `KokoroSwift`'s own `resources: [.copy(...)]` bundle (`config.json`) — does `Bundle.module` resolve correctly at runtime once statically linked into a non-SwiftPM host binary, same class of problem as the metallib | Not yet proven; likely needs the same "copy next to the executable" treatment, follow up only if a resource-not-found crash appears |
| 🟡 | Platform bump to `.macOS(.v15)` (Sequoia) — confirm the build machine's Xcode/SDK actually supports it | Should be a non-issue on current hardware/Xcode but worth a quick `sw_vers`/`xcodebuild -showsdks` check before diving in |
| ⚪ | Voice/`Language` lookup and WAV encoding are just app-level glue code we write ourselves (no library support) | Not a risk, just work — see Step 3/4 |

## Step-by-step plan

### Step 1 — Scaffold the crate and resolve the `.dynamic`-product risk first
Create `kokoro-tts-swift-rs/` (sibling to `qwen3-tts-swift-rs/`) by copying its shape:
- `Cargo.toml` verbatim (same `swift-rs = "1.0.6"` normal + `[build-dependencies]` entries).
- `build.rs`: same `SwiftLinker::new("15.0").with_package("kokoro-swift", "./kokoro-swift/").link()`,
  same `cargo:rustc-link-lib=c++` and `cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift` lines. Metallib
  handling deferred to Step 5 (get a trivial link working first, exactly like the Qwen3 plan did).
- `kokoro-swift/Package.swift`: `.library(name: "kokoro-swift", type: .static, targets: [...])`,
  depending on `.package(url: "https://github.com/mlalma/kokoro-ios", from: "1.0.0")` (product
  `KokoroSwift`) and `SwiftRs`, platforms `.macOS(.v15)`.
- A placeholder `@_cdecl("ping_swift") -> Bool { true }` function, no MLX/Kokoro code yet.

Build with plain `cargo build`. **This is the decisive test for the dynamic-product risk**: if
`swift build` fails to statically link our target against `KokoroSwift`'s `.dynamic` product, or
if the resulting artifact needs `KokoroSwift.dylib` present at runtime, resolve it here before
writing anything else — options in priority order: (a) it just works, `swift-rs`'s consumption
model tolerates a dynamic upstream dependency the same way any SwiftPM static target can depend on
a dynamic one; (b) if not, ship the resolved `.dylib` alongside the Rust binary and add its
directory to the rpath (same rpath mechanism already used for the Swift concurrency runtime); (c)
only as a last resort, fork `kokoro-ios`'s `Package.swift` to force `type: .static` the way we
already fully control `qwen3-tts-swift-rs`'s own wrapper package.

### Step 2 — Load the model and a `voices.npz` file
Add `@_cdecl("load_model_swift")` taking **two** paths (model safetensors file, voices npz file) —
this already diverges from Qwen3's single-path `load_model_swift`, so don't try to share the
signature:
```swift
@_cdecl("load_model_swift")
public func loadModelSwift(modelPath: SRString, voicesPath: SRString) -> Bool {
  TTSState.pipeline = KokoroTTS(modelPath: URL(fileURLWithPath: modelPath.toString()))
  TTSState.voices = NpyzReader.read(fileFromPath: URL(fileURLWithPath: voicesPath.toString()))
  return TTSState.pipeline != nil && TTSState.voices != nil
}
```
Rust wrapper: `pub fn load_model(model_path: &str, voices_path: &str) -> bool`.

### Step 3 — `available_speakers_swift`
No library API exists for this (see table above) — derive it ourselves from the loaded voices
dict, mirroring `TestAppModel.voiceNames`: strip the `.npy` suffix from each key, sort. Return
`\n`-joined `SRString`, same wire shape as Qwen3's `available_speakers_swift` even though the
Swift-side implementation is new.

### Step 4 — `synthesize_swift`
```swift
@_cdecl("synthesize_swift")
public func synthesizeSwift(text: SRString, speaker: SRString) -> SRData? {
  guard let pipeline = TTSState.pipeline,
        let voiceArray = TTSState.voices?[speaker.toString() + ".npy"] else { return nil }
  let language: Language = speaker.toString().first == "a" ? .enUS : .enGB
  guard let (samples, _) = try? pipeline.generateAudio(voice: voiceArray, language: language, text: text.toString()) else {
    return nil
  }
  return SRData([UInt8](wavData(samples: samples, sampleRate: 24000)))  // our own encoder, see below
}
```
Write a small `wavData(samples: [Float], sampleRate: Double) -> Data` helper directly in
`kokoro-swift`'s source (standard 44-byte-header mono 16-bit PCM WAV — a well-known, tiny format;
not copied from `Qwen3TTS`'s `AudioSampleWriter`, just the same well-known shape, since that file
belongs to a different upstream package we don't depend on here).
Rust wrapper: identical shape to Qwen3's `pub fn synthesize(text: &str, speaker: &str) -> Option<Vec<u8>>`.

### Step 5 — Metallib (copy verbatim, expect it to just work)
Copy `qwen3-tts-swift-rs/build.rs`'s `build_metallib()` unchanged except the bundle path component
(`mlx-swift_Cmlx.bundle` — same bundle name, since it comes from the same `mlx-swift` package, not
from `KokoroSwift`). If `KokoroSwift`'s own `resources: [.copy(...)]` bundle turns out to also be
needed at runtime (Step 1/6 will surface this as a missing-resource crash if so), extend
`ensure_metallib_installed()`-equivalent to also copy that bundle next to the executable — don't
pre-build this speculatively, only if the runtime error actually appears.

### Step 6 — Wire into `kokoro-mlx-swift-tts/src-tauri`
This app currently exists only as an untouched `create-tauri-app` stub (`greet` command, default
React template) — no prior Kokoro-specific code to preserve or work around. Mirror
`hamptus-mlx-swift-qwen3-tts/src-tauri` exactly:
- `Cargo.toml`: add `[target.'cfg(target_os = "macos")'.dependencies] kokoro-tts-swift-rs = { path = "../../kokoro-tts-swift-rs" }`, plus `base64` (for the same base64-WAV-over-Tauri-command pattern).
- `build.rs`: add the `#[cfg(target_os = "macos")] cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift` line (must be repeated here per the "doesn't propagate transitively" note already documented in the Qwen3 plan).
- `lib.rs`: `available_speakers`/`synthesize_speech` commands with the same macOS/non-macOS `#[cfg]` split as the Qwen3 version; `setup()` calls `ensure_metallib_installed()` then `load_model(model_path, voices_path)` against `.models/Kokoro-82M-MLX/{kokoro-v1_0.safetensors,voices.npz}`.
- `src/App.tsx`: copy `hamptus-mlx-swift-qwen3-tts/src/App.tsx`'s current shape (speaker picker +
  **textarea**, not a single-line input — match the `fe8ecb7` "long scripts" update already applied
  there, not the older single-line version) and its audio-playback wiring.

### Step 7 — Verify
Same two-tier verification as the Qwen3 plan: `cargo run --example synthesize` inside
`kokoro-tts-swift-rs/` first (decisive, no Tauri involved), text/speaker overridable via env vars,
optional `PLAY=1` via `afplay`. Only after that passes, verify `bun run tauri dev` in
`kokoro-mlx-swift-tts/` end-to-end (model load log lines, no dyld errors, then manually exercise
the UI — speaker picker populated, type text, click synthesize, audio plays).

## Explicitly out of scope

- `eSpeakNGG2PProcessor` / any xcframework — Misaki is the default G2P and needs no binary framework.
- Any language beyond `.enUS`/`.enGB` (the only two the `Language` enum defines today).
- Per-token timestamps (`[MToken]?`, the second element `generateAudio` returns) — discarded, same
  as Qwen3's plan discarded anything beyond raw samples.
- Streaming generation.
- Unit tests — this is prototyping, per explicit instruction.
- Packaged/signed `.app` concerns beyond `cargo tauri dev` — same caveat the Qwen3 plan carried
  into its own Step 7, unresolved there too.

## Success criteria

- `cargo build` alone (no manual `xcodebuild` step) in `kokoro-tts-swift-rs/` produces a static
  library; `cargo run --example synthesize` loads the model + voices and writes a real, valid 24kHz
  mono WAV file.
- `kokoro-mlx-swift-tts/src-tauri`, consuming it exactly as `hamptus-mlx-swift-qwen3-tts/src-tauri`
  consumes `qwen3-tts-swift-rs`, launches via `bun run tauri dev` with no dyld errors, model loads
  at startup, and the speaker-picker + textarea UI produces audible speech end-to-end.
- Qwen3's crate, app, and tests are untouched — `git diff` outside `kokoro-tts-swift-rs/` and
  `kokoro-mlx-swift-tts/` is empty.
