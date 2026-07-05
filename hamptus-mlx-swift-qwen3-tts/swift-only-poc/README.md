# Qwen3 TTS Swift-Only POC

Interactive Swift command-line proof of concept for `hamptus/mlx-swift-qwen3-tts`.

The CLI looks for downloaded models in the repository-root `.models/` directory and writes generated WAV files to this package's `.generated/` directory.

## Prerequisites

- macOS with Apple Silicon
- Xcode with the Metal Toolchain installed
- `git-lfs`

Install the Metal Toolchain once if Xcode reports that it is missing:

```bash
xcodebuild -downloadComponent MetalToolchain
```

## Download A Model

From `swift-only-poc`:

```bash
scripts/download-model.sh
```

That script stores the model under:

```text
/Users/tleyden/Development/tauri2-qwen3-tts/.models/
```

The script asks which model to download before it runs `git clone`. The recommended defaults are the CustomVoice variants because they include named speakers and support style/emotion instruct:

```bash
# 1.7B CustomVoice, named speakers + style/emotion instruct
git clone https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit
git clone https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit
```

You can also type a Hugging Face model name at the prompt, such as `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`. If you omit the namespace, the script assumes `mlx-community/`.

These are preferred over `Qwen3-TTS-12Hz-1.7B-Base-8bit` because the current interactive CLI expects the model to expose built-in speaker names through `pipeline.availableSpeakers`.

## Build

Use Xcode or `xcodebuild` for runtime builds. Plain `swift build` can compile the executable, but SwiftPM does not package the MLX Metal shader bundle needed at runtime.

```bash
cd /Users/tleyden/Development/tauri2-qwen3-tts/hamptus-mlx-swift-qwen3-tts/swift-only-poc
xcodebuild build -scheme Qwen3TTSPoc -destination 'platform=macOS' -skipPackagePluginValidation
```

The MLX package has a plugin named `CudaBuild`, but on macOS it prints `CUDA is disabled`; this POC is using Metal.

## Run From Xcode

1. Open `Package.swift` in Xcode.
2. Select the `Qwen3TTSPoc` scheme.
3. Set the scheme working directory to this directory:

```text
/Users/tleyden/Development/tauri2-qwen3-tts/hamptus-mlx-swift-qwen3-tts/swift-only-poc
```

4. Run the scheme.

## Run From The Shell

After a successful `xcodebuild`, run the Xcode-built binary with `DYLD_FRAMEWORK_PATH` pointing at Xcode's build products:

```bash
cd /Users/tleyden/Development/tauri2-qwen3-tts/hamptus-mlx-swift-qwen3-tts/swift-only-poc

BUILD_DIR="$HOME/Library/Developer/Xcode/DerivedData/swift-only-poc-fmhvmtkwonqmqoebsajlnhrblhhe/Build/Products/Debug"
DYLD_FRAMEWORK_PATH="$BUILD_DIR:$BUILD_DIR/PackageFrameworks" "$BUILD_DIR/Qwen3TTSPoc"
```

Expected first prompt:

```text
Which model?
  1. Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit
  2. Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit
>
```

## Known Current Limitation

The interactive CLI currently assumes `pipeline.availableSpeakers` is non-empty and asks the user to pick one of those built-in voices.

The `Qwen3-TTS-12Hz-1.7B-Base-8bit` model does not provide built-in speakers:

```json
"spk_id": {},
"tts_model_type": "base"
```

Because `mlx-swift-qwen3-tts` implements `availableSpeakers` as the sorted keys of `config.spk_id`, the Base model reports no speakers and the CLI exits after loading it.

Use `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` or `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit`, or update the CLI to support Base/VoiceDesign generation without a built-in speaker selection.
