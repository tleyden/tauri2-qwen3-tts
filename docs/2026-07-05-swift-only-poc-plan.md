# Swift-only POC plan: validate hamptus/mlx-swift-qwen3-tts before touching Rust

## Goal

Before wiring `hamptus-mlx-swift-qwen3-tts` up as a Tauri sidecar/bridge, prove out the
library on its own: load a Qwen3-TTS model, generate speech, hear it, and get a rough
sense of latency and quality. If it's not good enough (quality, speed, streaming
behavior), we want to find that out now, in a few hours of Swift-only iteration, rather
than after building a Rust <-> Swift bridge.

This lives entirely in `hamptus-mlx-swift-qwen3-tts/swift-only-poc/` and has zero
dependency on Tauri, Rust, or the existing empty React/Vite app next to it.

## Approach: SwiftPM executable opened as an Xcode project

Rather than hand-crafting a `.xcodeproj` (fragile to generate outside the Xcode GUI),
the POC will be a Swift Package with an executable target. Xcode opens `Package.swift`
directly as a first-class project — full build/run/breakpoints/console — with no
`.xcodeproj` file needed. This also sidesteps app-sandbox/entitlement questions (no mic
access needed, just file I/O + Metal), since a plain executable isn't sandboxed by
default.

Environment already verified on this machine: Xcode 26.5, Swift 6.3.2, macOS 26.2,
Apple Silicon — meets the library's macOS 14+ / Swift 5.9+ requirement.

## Directory layout

```
hamptus-mlx-swift-qwen3-tts/swift-only-poc/
  Package.swift
  Sources/
    Qwen3TTSPoc/
      main.swift
  scripts/
    download-model.sh      # one-time model fetch, not run automatically
  models/                  # git-ignored; model gets cloned here
  .gitignore               # ignore models/ and .build/
  output/                  # git-ignored; generated .wav files land here
```

## Step-by-step plan

1. **Scaffold the package**
   - `Package.swift`: macOS(.v14) platform, one dependency on
     `https://github.com/hamptus/mlx-swift-qwen3-tts` (pinned `from: "0.2.0"` per its
     README), one executable target `Qwen3TTSPoc` depending on product `Qwen3TTS`.
   - `.gitignore` for `.build/`, `models/`, `output/`.

2. **Model download script** (`scripts/download-model.sh`)
   - Clones the smallest model via git-lfs into `models/`:
     `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit` (~1.7GB) — picked for fast
     iteration, not final quality.
   - This is a multi-GB network operation, so it will be run explicitly (with your
     go-ahead) rather than silently as part of scaffolding.

3. **Baseline non-streaming smoke test** (`main.swift`, default mode)
   - Load `Qwen3TTSPipeline(modelPath:)` from `models/...`.
   - Generate speech for a short hardcoded sentence using a built-in speaker (e.g.
     `Aiden`).
   - Write output to `output/baseline.wav` via `AudioSampleWriter`.
   - Immediately shell out to `afplay` (via `Process`) to play it back — so running the
     target in Xcode ends with you hearing the result.
   - Print timing: model load time, generation wall time, generated audio duration,
     and tokens/sec or real-time-factor, in the same spirit as the benchmark table in
     the top-level README, so we have a number to compare against llama.cpp/Gemma4
     later.

4. **Streaming smoke test** (`main.swift --stream` flag)
   - Call `generateStream(text:speaker:)` and measure wall-clock time to the *first*
     chunk vs. time to the *last* chunk.
   - This directly tests the reason we picked hamptus over AtomGradient (real PCM
     streaming vs. one final blob) — if time-to-first-chunk isn't meaningfully better
     than baseline, that's important to know before building anything else.
   - Play chunks back-to-back with `afplay` or accumulate + write a
     `output/streaming.wav` for comparison; whichever is simpler to get working first.

5. **Open in Xcode and run**
   - `open Package.swift` from `swift-only-poc/`.
   - Select the `Qwen3TTSPoc` scheme, target "My Mac", Cmd+R.
   - Confirm: it builds, it loads the model without crashing, and you hear speech.

## Success criteria

- Package builds and runs from Xcode without manual pbxproj surgery.
- Non-streaming generation produces intelligible speech.
- Reported real-time-factor is in the same ballpark as (ideally faster than) the
  16.48 tokens/sec Gemma4/llama.cpp number already in the top-level README, or at
  least fast enough to feel usable for Fluensy.
- Streaming demonstrably reduces time-to-first-audio vs. baseline.
- No crashes, no manual `.metallib` copying or other packaging surprises (that risk
  was specific to the AtomGradient option we didn't choose, but worth confirming
  hamptus doesn't have an equivalent gotcha).

## Explicitly out of scope for this POC

- Any Rust code, Tauri commands, or the existing `src-tauri` / `src` app.
- Voice cloning, ICL, VoiceDesign, CustomVoice — those are 1.7B-only or secondary
  features; first goal is just "does base TTS work and is it fast enough."
- Packaging/distribution concerns (how the Swift lib ships inside a Tauri app bundle).

## Next steps after this POC passes

Only after we've heard it work and are happy with latency/quality: figure out the
Rust <-> Swift bridge (likely a small Swift dylib exposing a C ABI, called from
`src-tauri` via FFI, mirroring the pattern already validated in the sibling
`llama-cpp-ffi` project) and wire it into the actual Tauri app skeleton in
`hamptus-mlx-swift-qwen3-tts/`.
