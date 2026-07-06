# qwen3-tts-swift-rs

Rust <-> Swift bridge crate that calls [hamptus/mlx-swift-qwen3-tts](https://github.com/hamptus/mlx-swift-qwen3-tts)
(MLX + Metal) from Rust, using [swift-rs](https://github.com/Brendonovich/swift-rs) for the FFI
plumbing. Consumed by [`../hamptus-mlx-swift-qwen3-tts`](../hamptus-mlx-swift-qwen3-tts) (the Tauri
app) — **see that app's README for how to run the actual desktop app.** This README covers the
bridge crate on its own.

Design/history: [`../docs/2026-07-05-rust-swift-bridge-plan.md`](../docs/2026-07-05-rust-swift-bridge-plan.md).

**macOS only.** `build.rs` unconditionally shells out to `swift`/`xcodebuild`.

## What this crate exposes

- `load_model(model_path: &str) -> bool`
- `available_speakers() -> Option<Vec<String>>`
- `synthesize(text: &str, speaker: &str) -> Option<Vec<u8>>` — returns a complete WAV file,
  using the default 200-character chunk size
- `synthesize_with_chunk_size(text: &str, speaker: &str, chunk_size: usize) -> Option<Vec<u8>>` —
  uses character-based chunking; pass `0` to preserve the old single-call behavior
- `ensure_metallib_installed() -> std::io::Result<PathBuf>` — must be called once before
  `load_model`; writes the embedded MLX Metal shader library next to the current executable (see
  "Why build.rs looks like this" below)

## Prerequisites

- macOS on Apple Silicon
- Xcode (not just Command Line Tools) with the Metal Toolchain installed:
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
- A downloaded model under the repo root's `.models/`, e.g.
  `.models/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`. If you don't have one yet:
  ```bash
  cd ../hamptus-mlx-swift-qwen3-tts/swift-only-poc
  scripts/download-model.sh
  ```

## Standalone smoke test

```bash
cargo run --example synthesize
```

This loads the model, prints available speakers, synthesizes a default sentence, and writes the
result to a temp `.wav` file. Override defaults with env vars:

```bash
MODEL_PATH=/path/to/model SPEAKER=Dylan TEXT="Testing one two three" CHUNK_SIZE=200 PLAY=1 cargo run --example synthesize
```

(`PLAY=1` plays the result with `afplay`.)

**First build is slow** (a few minutes): it compiles MLX's C++ core twice, once via `swift build`
for linking and once via `xcodebuild` to extract the compiled Metal shader library (see below).
Subsequent builds reuse both caches unless the Swift package or its dependencies change.

## Why build.rs looks like this

Three gotchas were found empirically while building this crate, none of which show up in the
`vision-swift`/`screen-ocr-swift-rs` reference this crate's shape was copied from (that reference
is Swift/ObjC-only and synchronous — no C++, no async):

1. **Plain `swift build` never produces MLX's `default.metallib`.** `mlx-swift`'s `Cmlx` target
   declares no SwiftPM `resources:` and relies on Xcode's Metal-compiler build phase to compile its
   `.metal` kernel sources. `swift build` compiles everything else fine but silently skips that
   step, and the binary crashes at runtime with `MLX error: Failed to load the default metallib.`
   Fix: keep `swift build` for compiling/linking (it works), and separately run `xcodebuild` _only_
   to extract `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` (xcodebuild itself can't
   replace `swift build` for linking — it emits per-target `.o` files, not a consolidated `.a`, for
   headless SwiftPM library builds). The metallib gets embedded into this crate via
   `include_bytes!`, and `ensure_metallib_installed()` writes it out next to the running executable
   at startup, matching MLX's colocated-with-binary lookup.
2. **`libc++` must be linked explicitly.** MLX's core is C++ (exceptions, RTTI); without
   `cargo:rustc-link-lib=c++`, the final link fails with undefined symbols like `__cxa_throw`.
3. **The Swift concurrency runtime needs an explicit rpath.** Qwen3TTS uses `async`/`AsyncStream`,
   which pulls in `libswift_Concurrency.dylib`; without
   `cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift`, the binary fails to _launch_ with
   `Library not loaded: @rpath/libswift_Concurrency.dylib`.
   **This does not propagate to consumers** — `cargo:rustc-link-arg` (unlike `rustc-link-lib`/
   `rustc-link-search`) only applies to the emitting package's own targets. Any binary crate that
   depends on this one (e.g. a Tauri app's `src-tauri`) must repeat that exact rpath line in its
   own `build.rs`, or it will hit the same dyld error. `hamptus-mlx-swift-qwen3-tts/src-tauri/build.rs`
   already does this — copy that pattern if you add another consumer.

## Known limitation

`ensure_metallib_installed()` writes into the directory containing the current executable, which
works for `cargo run`/dev builds but may not work for a signed, installed `.app` bundle (its
directory may not be writable at runtime). Not yet solved — tracked in the plan doc.
