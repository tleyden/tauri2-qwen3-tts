# hamptus-mlx-swift-qwen3-tts

Tauri 2 (React + Rust) desktop app that calls [hamptus/mlx-swift-qwen3-tts](https://github.com/hamptus/mlx-swift-qwen3-tts)
via a Rust <-> Swift bridge crate ([`../qwen3-tts-swift-rs`](../qwen3-tts-swift-rs)) built on
[swift-rs](https://github.com/Brendonovich/swift-rs). See
[`../docs/2026-07-05-rust-swift-bridge-plan.md`](../docs/2026-07-05-rust-swift-bridge-plan.md) for
how the bridge works and what's been verified so far.

**macOS only.** The bridge's `build.rs` unconditionally shells out to `swift`/`xcodebuild`, so this
can't build on Linux/Windows or in a non-macOS CI runner.

## Prerequisites

- macOS on Apple Silicon
- Xcode (not just the Command Line Tools) with the Metal Toolchain installed:
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
- [`git-lfs`](https://git-lfs.com) (for downloading the model)
- [`bun`](https://bun.sh) (or `npm`, adjusting commands below accordingly)

## One-time setup: download a model

The app expects a model directory under the repo root's `.models/`, e.g.
`.models/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`. If you haven't already downloaded one, use the
script in the sibling Swift-only proof of concept:

```bash
cd ../hamptus-mlx-swift-qwen3-tts/swift-only-poc
scripts/download-model.sh
```

Pick a `CustomVoice` variant when prompted (it needs named built-in speakers). If you use a
different model directory name, update `default_model_path()` in `src-tauri/src/lib.rs`
accordingly.

## Install frontend dependencies

```bash
bun install
```

## Run in development mode

```bash
bun run tauri dev
```

This will:
1. Start the Vite dev server for the React frontend.
2. Build `src-tauri`, which transitively builds `../qwen3-tts-swift-rs`'s Swift package via
   `swift build`, plus a one-time `xcodebuild` invocation to extract MLX's compiled Metal shader
   library (see the plan doc for why both are needed).
3. Launch the app window, loading the model from `.models/` at startup. Watch the terminal for
   `Qwen3-TTS: model loaded from ...` — if you instead see a `failed to load model` message, the
   model download step above hasn't been completed.

**First build is slow** (multiple minutes) since it compiles MLX's C++ core twice — once via
`swift build` for linking, once via `xcodebuild` for the Metal shader library. Subsequent builds
reuse both caches and are fast unless you change the Swift package or its dependencies.

Once the window opens, the test harness lets you pick a speaker, type text, and click
**Synthesize** to hear the generated audio played back via an `<audio>` element.

## Build a release bundle

```bash
bun run tauri build
```

Note: the packaged `.app`'s handling of the Metal shader library resource (currently written next
to the running executable at first launch) hasn't been validated against a signed/installed
bundle yet — see the "packaging" open question in the plan doc.

## Troubleshooting

- **`Library not loaded: @rpath/libswift_Concurrency.dylib`**: the app's own `build.rs` needs an
  explicit rpath for the Swift concurrency runtime (already present in
  `src-tauri/build.rs`) — this doesn't propagate automatically from the `qwen3-tts-swift-rs`
  dependency's build script, so if you copy this app's `build.rs` elsewhere, keep that line.
- **`MLX error: Failed to load the default metallib`**: the embedded metallib failed to write out,
  or you're running a binary that predates the fix — rerun `bun run tauri dev` to rebuild.
- **`xcodebuild failed ...`**: confirm `xcode-select -p` points at a full Xcode install (not just
  the Command Line Tools) and that the Metal Toolchain is installed (see Prerequisites).

## Recommended IDE Setup

- [VS Code](https://code.visualstudio.com/) + [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)
