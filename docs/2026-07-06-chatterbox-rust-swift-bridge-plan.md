# Chatterbox-TTS plan: swift-only POC → Rust↔Swift bridge → Tauri2 app

## Decision

Copy the same three-layer shape already proven for Qwen3-TTS
([2026-07-05-swift-only-poc-plan.md](2026-07-05-swift-only-poc-plan.md) →
[2026-07-05-rust-swift-bridge-plan.md](2026-07-05-rust-swift-bridge-plan.md)) and for Kokoro
([2026-07-05-kokoro-rust-swift-bridge-plan.md](2026-07-05-kokoro-rust-swift-bridge-plan.md)),
adapted for [Chatterbox TTS](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioTTS/Models/Chatterbox/README.md)
via [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift):

1. **`chatterbox-tts-swift/`** (top-level, currently an empty stub dir) — Swift-only POC, no
   Rust/Tauri, proves the model loads and generates audible speech from `mlx-audio-swift` directly.
2. **`chatterbox-tts-swift-rs/`** (top-level, currently an empty stub dir) — the Rust↔Swift bridge
   crate, structurally identical to `qwen3-tts-swift-rs`/`kokoro-tts-swift-rs`.
3. **`tauri2-chatterbox/`** (top-level, currently an empty stub dir — **not** a `create-tauri-app`
   scaffold yet, unlike `kokoro-mlx-swift-tts`) — the real Tauri2 app, consuming crate #2 the way
   `hamptus-mlx-swift-qwen3-tts/src-tauri` consumes `qwen3-tts-swift-rs`.

Default model: **`mlx-community/Chatterbox-TTS-fp16`** (the "Regular" variant — verified exact
repo ID against the HuggingFace API; note the casing/`-TTS-` differs from the shorthand
`mlx-community/chatterbox-fp16` used in the request).

## What's different from Qwen3/Kokoro (verified directly against upstream source, 2026-07-06)

I cloned `Blaizzy/mlx-audio-swift` (`main`, current HEAD) and read `Package.swift`,
`Sources/MLXAudioTTS/Models/Chatterbox/ChatterboxModel.swift` (1371 lines, in full),
`Sources/MLXAudioTTS/Generation.swift`, `Sources/MLXAudioCore/AudioUtils.swift`,
`Sources/MLXAudioCore/Generation/GenerationTypes.swift`, and the reference CLI at
`Sources/Tools/mlx-audio-swift-tts/App.swift` — not just the README sample in the request, which
(like Kokoro's wiki) turns out to omit several load-bearing details.

| Aspect | Qwen3 / Kokoro (both plans) | Chatterbox (`mlx-audio-swift`), as of today |
| --- | --- | --- |
| Voice selection | Built-in named speakers (Qwen3: `availableSpeakers: [String]`; Kokoro: `voices.npz` lookup) | **No named voices at all.** `generate(voice: String?, ...)` accepts the parameter (shared `SpeechGenerationModel` protocol signature) but Chatterbox's own implementation **never reads it** — grep confirms zero references to `voice` inside the function body. The only way to select a voice is `refAudio: MLXArray?` (voice cloning from a reference clip). |
| Default-model fallback | Always available (Qwen3 built-in speakers; Kokoro `voices.npz`) | **Not available for our default model.** `ChatterboxModel.fromModelDirectory` only populates `defaultConditioning` if the model dir contains `conds.safetensors`. I checked the HF API for both repos: `mlx-community/Chatterbox-TTS-fp16` (Regular, our default) ships only `config.json` + `model.safetensors` + `tokenizer.json` — **no `conds.safetensors`**. `mlx-community/chatterbox-turbo-fp16` **does** ship one. Concretely: **`generate()` unconditionally throws `AudioGenerationError.invalidInput("Chatterbox requires reference audio for voice cloning...")` for our default model unless `refAudio` is supplied.** This eliminates the whole "available_speakers" bridge function this plan family has had twice before — there is nothing to enumerate. |
| `language` parameter | Kokoro: real, drives a 2-case enum (`.enUS`/`.enGB`) | Same as `voice` — accepted by the protocol, **never read** inside Chatterbox's `generate()`. The README's "23 languages" claim is a training-data/tokenizer property, not something this Swift port exposes a runtime switch for. Pass `nil`; don't build a language enum. |
| Model loading | Directory-path init (`Qwen3TTSPipeline(modelPath:)`, `KokoroTTS(modelPath:)`) — synchronous | `ChatterboxModel.fromModelDirectory(_ modelDir: URL, hfToken: String?) async throws -> ChatterboxModel` (also `.fromPretrained(_ modelRepo: String)` for direct HF downloads, and a generic dispatcher `TTS.loadModel(modelRepo:)` that auto-detects a local directory vs. a HF repo ID string by checking for `config.json`). **This is `async`, unlike both prior pipelines' synchronous inits** — see the new concurrency-bridging risk below. |
| **Hidden extra network dependency** | None — fully offline once the model dir is populated | **New, load-bearing risk.** `fromModelDirectory` *unconditionally* also calls `S3TokenizerV2.fromPretrained("mlx-community/S3TokenizerV2", hfToken:)` — a **separate ~495MB HF repo** — regardless of whether the main model came from a local directory. This tokenizer is what extracts speech-token conditioning from the reference-audio clip during voice cloning. If it fails to load, the code prints a warning and **silently falls back to `defaultConditioning`'s tokens** — which, for our default model (no `conds.safetensors`), means *empty* prompt-speech-tokens, i.e. badly degraded/unconditioned voice cloning with no error surfaced. **Practical implication: this bridge needs network access at least once**, even though the primary model is bootstrapped locally under `.models/`, matching this repo's usual offline-after-bootstrap convention only partially. |
| Generation API is `async` | No (both prior pipelines' `generate`/`generateAudio` are synchronous calls) | Yes — `ChatterboxModel.generate(...) async throws -> MLXArray`. Our `@_cdecl` exports (which must be synchronous, non-`async`, C-callable) will need a **block-on-async bridge** (e.g. `Task { ... }` + `DispatchSemaphore.wait()`) inside `load_model_swift`/`synthesize_swift`. Neither `qwen3-tts-swift`/`kokoro-tts-swift`'s wrapper needed this pattern — genuinely new, and the one real *implementation* risk in Phase 2 (see below); not expected to be a *design* risk since the blocking happens on a plain native thread (the Rust FFI call-in thread), not on Swift's own cooperative pool. |
| `GenerateParameters` location | N/A | Lives in `MLXLMCommon`, a product of the **separate** `ml-explore/mlx-swift-lm` package (`import MLXLMCommon`) — re-used across `mlx-audio-swift`'s TTS/STT models for temperature/topP/maxTokens. Not exported by `MLXAudioTTS` or `MLXAudioCore` themselves. Our wrapper's `Package.swift` needs an **explicit** dependency on `mlx-swift-lm`'s `MLXLMCommon` product (confirmed by grepping `ChatterboxModel.swift`'s own imports: `@preconcurrency import MLXLMCommon`). |
| WAV encoding | Kokoro: had to hand-roll a ~40-line encoder (no library support) | **Already provided.** `MLXAudioCore.AudioUtils.writeWavFile(samples: [Float], sampleRate:, fileURL:)` exists — no need to hand-roll one this time. **New wrinkle to verify early**: it writes 32-bit float PCM (`AVAudioFormat(commonFormat: .pcmFormatFloat32, ...)`), not the ubiquitous 16-bit int PCM Qwen3/Kokoro produced. Browsers/`<audio>` generally do decode float WAV, but this is unverified for Tauri's `data:audio/wav;base64,...` playback path specifically — test in Phase 1 before assuming it "just works"; if playback fails, convert to int16 PCM ourselves (cheap, same shape as Kokoro's from-scratch encoder, just as a fallback). |
| Reference-audio loading | N/A (no voice cloning in either prior plan) | `MLXAudioCore.loadAudioArray(from: URL, sampleRate: Int?) throws -> (Int, MLXArray)` — already resamples to the model's target sample rate. Directly reusable for `refAudio`. |
| Package tools-version | Both prior upstream packages declared `swift-tools-version: 5.9`, matching our own wrapper's `5.9` | `mlx-audio-swift`'s own `Package.swift` declares **`swift-tools-version: 6.2`** (needs Xcode 26 / Swift 6.2+ toolchain to parse — already satisfied per `swift-only-poc-plan.md`'s recorded environment: Xcode 26.5, Swift 6.3.2). SwiftPM generally allows a `5.9`-manifest package to depend on a `6.2`-manifest package (each manifest is parsed independently), but this specific version gap is **untested in this repo family** — confirm in Phase 1/2 Step 1, same spirit as Kokoro's `.dynamic`-product check. |
| G2P / phonemizer | Kokoro needed Misaki (pure Swift, no xcframework) | **Not needed at all.** Chatterbox tokenizes text via a standard HF `Tokenizers`-based BPE/GPT2 tokenizer loaded straight from `tokenizer.json` (Regular) or synthesized from `vocab.json`+`merges.txt` (Turbo) — both handled automatically inside `fromModelDirectory`. No extra dependency. |
| Metal shader (`.metallib`) issue | Present in both prior plans, fixed via `xcodebuild`-for-metallib-only + `include_bytes!` | **Also present, same fix applies verbatim** — `mlx-audio-swift` depends on the same `ml-explore/mlx-swift` (`Cmlx` target, no `resources:` declaration, relies on Xcode's Metal-compiler build phase that plain `swift build`/`swift run` doesn't replicate). |
| Min platform | Qwen3: `.macOS(.v14)`; Kokoro: `.macOS(.v15)` | `mlx-audio-swift` declares `platforms: [.macOS(.v14), .iOS(.v17)]` — **`.macOS(.v14)` is enough**, matching Qwen3's `SwiftLinker::new("14.0")`, not Kokoro's `"15.0"`. |
| Streaming | Qwen3: real chunk streaming (design deferred); Kokoro: N/A (not attempted) | Chatterbox's own `generateStream` override runs the **entire** non-streaming `generate()` to completion, then yields exactly one `.audio(...)` event followed by one `.info(...)` event — **not actually incremental**, despite the protocol supporting a chunked-event shape. Confirmed by reading the override at `ChatterboxModel.swift:857-903`. Treat this model as non-streaming; don't design a chunk-polling loop for it (unlike the Qwen3 plan's Step 5, which is moot here). |

## Model files (bootstrap source)

Everything Chatterbox needs ships as plain HF repos, no Git-LFS side-channel like Kokoro needed.
Verified file listings via the HF API directly:

- **`mlx-community/Chatterbox-TTS-fp16`** (default/Regular, ~2.7GB): `config.json` (52B),
  `model.safetensors` (2,696,712,404B), `tokenizer.json` (25,470B). **No `conds.safetensors`** —
  confirmed above, this model has no default voice.
- **`mlx-community/S3TokenizerV2`** (~495MB): `config.json`, `model.safetensors`
  (494,868,984B) — downloaded automatically by the library itself at model-load time (not something
  we place under `.models/`); needs network on first run, standard HF-client caching afterward.
- A **reference audio clip** (a few seconds of clean speech, 16-24kHz+, any common format
  `AVAudioFile` can read) is *required* to exercise voice cloning at all, since there's no default
  voice — this repo doesn't have one yet. Cheapest bootstrap: record one with `say -o ref.aiff
  "..." && afconvert -f WAVE -d LEI16 ref.aiff ref.wav`, or use any existing short clip.

Place the main model under `.models/Chatterbox-TTS-fp16/`, matching the existing `.models/`
convention (sibling to `.models/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit/`).

Optional, for the first trivial smoke test only (Phase 1, before touching the real
voice-cloning path): **`mlx-community/chatterbox-turbo-fp16`** *does* ship `conds.safetensors`,
so `generate(refAudio: nil, ...)` works immediately with zero extra setup — useful to prove the
toolchain end-to-end before adding reference-audio handling. Not needed beyond that first check;
the app's actual default model is Regular fp16 per the request.

## Risk ranking

| Risk | Concern | Status |
| --- | --- | --- |
| 🟢 | Overall `cargo build` → `swift build` → static lib → `swift!()` toolchain shape; `SRString`/`SRData`/`Option<SRData>`; `libc++` link; Swift-concurrency rpath (incl. repeating it in the Tauri app's own `build.rs`) | Already proven twice over (Qwen3, Kokoro plans) |
| 🟢 | `mlx-swift` Cmlx metallib missing under plain `swift build`, fixed via `xcodebuild`-only-for-the-metallib + `include_bytes!` + write-next-to-exe-at-startup | Already proven; `mlx-audio-swift` pulls in the same `mlx-swift` dependency, same fix applies verbatim |
| 🟢 | No G2P/xcframework needed | Simpler than Kokoro here — standard HF tokenizer, fully handled by the library |
| 🟡 | **No default voice for the default model** — `refAudio` is mandatory, not optional, for every call. This isn't a toolchain risk so much as an API-shape one: our bridge's `synthesize_swift` signature must take a ref-audio path (+ optional ref text) from day one, and the UI needs a file picker, not a speaker dropdown | New, but well-understood from reading the source — not a build/link unknown, just a design constraint to get right in Step 2/6 below |
| 🟡 | **Hidden `S3TokenizerV2` network dependency** inside `fromModelDirectory`, silently degrading (not erroring) if unavailable | Needs verification: confirm it downloads successfully once, confirm subsequent loads are offline/cached, and make failures *visible* in our bridge (log a clear warning) rather than silently producing degraded audio |
| 🟡 | **`async` model load / generation needs a block-on-async bridge** inside `@_cdecl` exports (`Task` + `DispatchSemaphore`) — neither prior plan's wrapper needed this, since both upstream APIs were synchronous | Not yet proven in this repo family — resolve in Phase 2 Step 1/2 with a trivial async round-trip before wiring real Chatterbox calls |
| 🟡 | `swift-tools-version` gap: our wrapper package (`5.9`, matching precedent) depending on `mlx-audio-swift`'s `6.2`-declared manifest | Should just work per SwiftPM's per-manifest parsing model, but untested in this repo family — confirm in Phase 1 Step 1 (trivial `import MLXAudioTTS` compiles) before Phase 2 |
| 🟡 | `AudioUtils.writeWavFile` emits 32-bit float PCM, not 16-bit int PCM — untested whether Tauri's `<audio src="data:audio/wav;base64,...">` playback path handles this | Verify in Phase 1's local playback test and again in Phase 3's browser `<audio>` test; fallback is a small int16 conversion pass, same shape as Kokoro's from-scratch encoder |
| ⚪ | Explicit `MLXLMCommon` (from `mlx-swift-lm`) dependency needed in our own `Package.swift` for `GenerateParameters` | Not a risk, just a manifest detail to get right (see table above) |

## Phase 1 — `chatterbox-tts-swift/`: Swift-only POC (no Rust, no Tauri)

Mirrors [2026-07-05-swift-only-poc-plan.md](2026-07-05-swift-only-poc-plan.md)'s approach exactly:
a SwiftPM executable opened directly in Xcode (not `swift run`), so Xcode's own Metal-compiler
build phase produces the `.metallib` for free — sidestepping the `xcodebuild`-for-metallib
workaround entirely for this phase (that workaround is only needed once we're building headlessly
via `cargo build` in Phase 2).

### Directory layout
```
chatterbox-tts-swift/
  Package.swift
  Sources/
    ChatterboxPoc/
      main.swift
  scripts/
    download-model.sh      # pulls mlx-community/Chatterbox-TTS-fp16 into models/
  models/                  # git-ignored
  test_data/
    ref_audio.wav           # a short reference clip for voice cloning (see bootstrap note above)
  output/                  # git-ignored; generated .wav files land here
  .gitignore
```

### Steps

1. **Scaffold the package.** `Package.swift`: `swift-tools-version: 5.9` (test the tools-version
   gap immediately — if `6.2`-manifest resolution fails against a `5.9` consumer, bump ours and
   note it), `platforms: [.macOS(.v14)]`, dependencies on
   `.package(url: "https://github.com/Blaizzy/mlx-audio-swift", branch: "main")` (no tagged
   release confirmed yet — pin to a specific commit SHA once resolved, don't float on `main`
   long-term) and `.package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3")`
   for `GenerateParameters`. One executable target depending on products `MLXAudioTTS`,
   `MLXAudioCore`, `MLXLMCommon`.

2. **Model + reference-clip bootstrap.** `scripts/download-model.sh` clones
   `mlx-community/Chatterbox-TTS-fp16` (git-lfs, ~2.7GB) into `models/`. Separately obtain a short
   reference WAV under `test_data/ref_audio.wav` (record via `say`/`afconvert` or supply one
   manually — flag this explicitly since, unlike Qwen3/Kokoro, there is no built-in voice to fall
   back to).

3. **Trivial smoke test first (optional but cheap): Turbo, no ref audio.** Before touching
   voice-cloning code, do one throwaway run against `mlx-community/chatterbox-turbo-fp16`
   (has `conds.safetensors`) calling `ChatterboxModel.fromPretrained(...)` then
   `model.generate(text:, voice: nil, refAudio: nil, refText: nil, language: nil,
   generationParameters: GenerateParameters(temperature: 0.8))` — this proves the whole
   MLX/Metal/tokenizer chain end-to-end with the least code, before adding reference-audio
   handling. Delete or gate this behind a flag once step 4 works; it's a diagnostic, not a
   permanent code path.

4. **Real target: Regular fp16 + voice cloning.**
   ```swift
   let model = try await ChatterboxModel.fromModelDirectory(
       URL(fileURLWithPath: "models/Chatterbox-TTS-fp16"), hfToken: nil
   )
   let (_, refAudio) = try loadAudioArray(from: URL(fileURLWithPath: "test_data/ref_audio.wav"),
                                          sampleRate: model.sampleRate)
   let audio = try await model.generate(
       text: "Hello, this is a test of the Chatterbox model.",
       voice: nil, refAudio: refAudio, refText: nil, language: nil,
       generationParameters: GenerateParameters(temperature: 0.8)
   )
   try AudioUtils.writeWavFile(samples: audio.asArray(Float.self), sampleRate: model.sampleRate,
                               fileURL: URL(fileURLWithPath: "output/baseline.wav"))
   ```
   Shell out to `afplay` afterward so running the target in Xcode ends with audible output.
   Print timing (model load, S3TokenizerV2 load, generation wall time) the same way
   `swift-only-poc-plan.md` did, so there's a number to compare against Qwen3/Kokoro later.
   **Confirm the `S3TokenizerV2` download succeeds** (watch console for the
   `"Loaded S3TokenizerV2 from mlx-community/S3TokenizerV2"` line vs. the silent-fallback warning)
   — this is the one failure mode that degrades output without erroring.

5. **Open in Xcode and run.** `open Package.swift`, select the `ChatterboxPoc` scheme, target
   "My Mac", Cmd+R. Confirm: builds, loads without crashing, S3TokenizerV2 loads successfully,
   and you hear intelligible cloned-voice speech.

### Success criteria
- Package builds and runs from Xcode with no manual `.metallib`/pbxproj surgery.
- Regular fp16 + a reference clip produces intelligible speech resembling that reference voice.
- `S3TokenizerV2` loads successfully (not the degraded fallback path).
- Output WAV plays back correctly via `afplay` (confirms the float32-PCM format is sound before
  it becomes a cross-process/browser concern in Phase 3).

## Phase 2 — `chatterbox-tts-swift-rs/`: Rust↔Swift bridge crate

Structurally identical to `qwen3-tts-swift-rs`/`kokoro-tts-swift-rs` — same `Cargo.toml`,
`build.rs` shape, `swift-rs` version (`1.0.6`). Only the wrapped package's contents and the
`@_cdecl` surface differ, per the table above.

### Step 1 — Scaffold + resolve the two new unknowns (async bridging, tools-version gap) first
Create `chatterbox-tts-swift-rs/chatterbox-swift/Package.swift`:
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "chatterbox-swift",
    platforms: [.macOS(.v14)],
    products: [.library(name: "chatterbox-swift", type: .static, targets: ["chatterbox-swift"])],
    dependencies: [
        .package(name: "SwiftRs", url: "https://github.com/Brendonovich/swift-rs", from: "1.0.6"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", /* pin to Phase 1's resolved commit/tag */),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
    ],
    targets: [
        .target(name: "chatterbox-swift", dependencies: [
            .product(name: "SwiftRs", package: "SwiftRs"),
            .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
    ]
)
```
`Cargo.toml`/`build.rs`: copy `qwen3-tts-swift-rs`'s verbatim (`SwiftLinker::new("14.0")`,
`cargo:rustc-link-lib=c++`, the Swift-concurrency rpath line, metallib-via-`xcodebuild` — same
`mlx-swift` pin, same fix applies unchanged).

First prove a trivial **synchronous** `@_cdecl("ping_swift") -> Bool { true }` builds and links
(decisive test for the tools-version gap — if `swift build` can't resolve a `5.9` package against
`mlx-audio-swift`'s `6.2` manifest, this is where it surfaces, before any real logic exists).

Then, still in Step 1, prove the **async-bridging** pattern in isolation with a fake async call
(e.g. `try? await Task.sleep(for: .seconds(1))`) wrapped in the semaphore pattern below, called
from a `cargo run --example ping` — confirms blocking a native FFI-call-in thread on a
`DispatchSemaphore` while a `Task` runs on Swift's cooperative pool doesn't deadlock, before
wiring it to real (slow, GPU-bound) Chatterbox calls.

### Step 2 — `load_model_swift`
```swift
import Foundation
import SwiftRs
import MLXAudioTTS
import MLXAudioCore

private final class TTSState {
    static var model: ChatterboxModel?
}

@_cdecl("load_model_swift")
public func loadModelSwift(modelPath: SRString) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    Task {
        do {
            let modelDir = URL(fileURLWithPath: modelPath.toString())
            TTSState.model = try await ChatterboxModel.fromModelDirectory(modelDir, hfToken: nil)
            success = true
        } catch {
            print("chatterbox-swift: failed to load model: \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    return success
}
```
Rust wrapper: `pub fn load_model(model_path: &str) -> bool` (same shape as Qwen3/Kokoro).
No `available_speakers_swift` this time — deliberately omitted, per the table above; there is
nothing for it to return for the default model.

### Step 3 — `synthesize_swift` (reference-audio path is mandatory, not optional)
```swift
@_cdecl("synthesize_swift")
public func synthesizeSwift(text: SRString, refAudioPath: SRString, refText: SRString) -> SRData? {
    guard let model = TTSState.model else {
        print("chatterbox-swift: synthesize_swift called before load_model_swift")
        return nil
    }
    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    Task {
        do {
            let refURL = URL(fileURLWithPath: refAudioPath.toString())
            let (_, refAudio) = try loadAudioArray(from: refURL, sampleRate: model.sampleRate)
            let refTextStr = refText.toString()
            let audio = try await model.generate(
                text: text.toString(),
                voice: nil,
                refAudio: refAudio,
                refText: refTextStr.isEmpty ? nil : refTextStr,
                language: nil,
                generationParameters: GenerateParameters(temperature: 0.8)
            )
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            try AudioUtils.writeWavFile(samples: audio.asArray(Float.self),
                                        sampleRate: model.sampleRate, fileURL: tmpURL)
            resultData = try Data(contentsOf: tmpURL)
            try? FileManager.default.removeItem(at: tmpURL)
        } catch {
            print("chatterbox-swift: synthesis failed: \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    return resultData.map { SRData([UInt8]($0)) }
}
```
Rust wrapper: `pub fn synthesize(text: &str, ref_audio_path: &str, ref_text: &str) -> Option<Vec<u8>>`
— note the **three**-string signature (text, ref-audio path, ref-text), diverging from
Qwen3/Kokoro's `(text, speaker)` shape; don't try to force-fit the old signature.

### Step 4 — Metallib (copy verbatim, expect it to just work)
Same as both prior plans — `xcodebuild -scheme chatterbox-swift` for the `mlx-swift_Cmlx.bundle`
only, `include_bytes!`, write next to the executable at startup via
`ensure_metallib_installed()`.

### Step 5 — Verify
`cargo run --example synthesize` (env-overridable model dir / text / ref-audio path / ref-text,
optional `PLAY=1` via `afplay`), decisive and Tauri-free, same as both prior plans' Step 7-style
verification. Confirm the produced WAV is valid (`file`, Python's `wave` module) and audibly
resembles the reference voice.

## Phase 3 — `tauri2-chatterbox/`: the real Tauri2 app

Unlike Kokoro (which reused an already-scaffolded `create-tauri-app` stub), **`tauri2-chatterbox/`
is currently a genuinely empty directory** — Phase 3 starts with actually scaffolding it.

### Step 1 — Scaffold
```bash
cd tauri2-chatterbox  # or scaffold into repo root and move contents in, whichever bun's CLI allows
bun create tauri-app@latest .
```
Match `hamptus-mlx-swift-qwen3-tts`'s stack choices (React + TypeScript + Vite, same
`productName`/`identifier` naming convention: `com.tleyden.tauri2-chatterbox`). Verify the default
`greet` scaffold runs via `bun run tauri dev` before touching anything Chatterbox-specific — same
"prove the shell first" discipline the other two plans implicitly relied on (their stubs already
had this proven).

### Step 2 — Wire in the bridge crate
- `src-tauri/Cargo.toml`: `[target.'cfg(target_os = "macos")'.dependencies]
  chatterbox-tts-swift-rs = { path = "../../chatterbox-tts-swift-rs" }`, plus `base64`.
- `src-tauri/build.rs`: repeat `cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift` under
  `#[cfg(target_os = "macos")]` (doesn't propagate transitively — documented gotcha from both
  prior plans).
- `src-tauri/src/lib.rs`: `setup()` calls `ensure_metallib_installed()` then `load_model(...)`
  against `.models/Chatterbox-TTS-fp16` (repo-root-relative, matching the existing convention).
  Two commands:
  - `synthesize_speech(text: String, ref_audio_path: String, ref_text: String) -> Result<String, String>`
    — base64-encodes the WAV bytes for `data:audio/wav;base64,...` playback, same pattern as
    Qwen3/Kokoro's `synthesize_speech`.
  - No `available_speakers` command — there's nothing to list.
  - Add a `pick_reference_audio` command (or just a plain HTML `<input type="file">` reading via
    Tauri's file APIs / drag-and-drop) so the user can supply a reference clip from the UI rather
    than hardcoding a path — this is new relative to both prior apps, which never needed a
    file-picker since voice selection was a dropdown of built-in names.

### Step 3 — UI (`src/App.tsx`)
Base shape on `hamptus-mlx-swift-qwen3-tts/src/App.tsx` (textarea + sample-content button +
status line + `<audio controls autoPlay>`), but replace the speaker `<select>` with:
- A reference-audio file picker (drag-and-drop or `<input type="file" accept="audio/*">`),
  showing the currently-selected clip's filename.
- An optional ref-text `<input>` (Chatterbox's `refText` param — can be left empty; the model
  doesn't strictly require it based on the source, but providing it is expected to improve
  cloning quality per how it's threaded through `generate()`).
- Disable the "Synthesize" button until a reference clip is selected, since (unlike Qwen3/Kokoro)
  there is no usable default — this is the one UI-level guard rail worth adding proactively given
  the API throws outright without it.

### Step 4 — Verify end-to-end
`bun run tauri dev`: app launches, model loads (watch for the `S3TokenizerV2` load-success log
line specifically, per the Phase 1 caveat), no dyld errors. Manually: pick a reference clip, type
text, click synthesize, confirm audio plays and audibly resembles the reference voice. Also
confirm the float32-PCM WAV (see risk table) actually plays in the Tauri webview's `<audio>` tag —
if it doesn't, that's the trigger for the int16-conversion fallback noted above.

## Explicitly out of scope

- Chatterbox's emotion-control parameter (`emotionAdv` / `cfgWeightOverride`) — mentioned in the
  README ("emotion control") but not exposed through the `SpeechGenerationModel` protocol's
  `generate()` signature at all (it's set via internal model properties, not a per-call param);
  leave at the library's defaults.
- The Turbo variant and its quantized (8-bit/4-bit) siblings — used only for the optional Phase 1
  Step 3 smoke test, not part of the shipped app.
- Streaming — Chatterbox's own `generateStream` isn't actually incremental (see table above), so
  there's no chunk-polling design to build, unlike the still-open item in the Qwen3 plan.
- Any language beyond whatever the tokenizer implicitly handles — no runtime language switch
  exists to wire up.
- Unit tests — prototyping, per the convention already established in this repo.
- Packaged/signed `.app` concerns beyond `cargo tauri dev` — same caveat both prior plans carried
  and left unresolved.

## Success criteria

- `chatterbox-tts-swift/`: runs from Xcode, loads `mlx-community/Chatterbox-TTS-fp16` plus a
  local reference clip, and produces audible, recognizably-cloned speech — with `S3TokenizerV2`
  confirmed loaded (not the degraded fallback).
- `chatterbox-tts-swift-rs/`: `cargo build` alone (no manual `xcodebuild` step) produces a static
  library; `cargo run --example synthesize` produces a real, valid 24kHz WAV end-to-end given a
  text string and a reference-audio path.
- `tauri2-chatterbox/`: scaffolded from scratch, depends on `chatterbox-tts-swift-rs` exactly as
  `hamptus-mlx-swift-qwen3-tts/src-tauri` depends on `qwen3-tts-swift-rs`, launches via
  `bun run tauri dev` with no dyld errors, and the reference-clip-picker + textarea UI produces
  audible cloned speech end-to-end (manually verified in the running app, not just via logs).
- Qwen3's and Kokoro's crates/apps are untouched — `git diff` outside `chatterbox-tts-swift/`,
  `chatterbox-tts-swift-rs/`, and `tauri2-chatterbox/` is empty.
