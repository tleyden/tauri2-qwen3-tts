<p align="center">
  <a href="https://deepwiki.com/tleyden/tauri2-qwen3-tts"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a>
</p>

<p align="center">
  <img src="./AppScreenshot.png" alt="Screenshot of the Qwen3-TTS Tauri prototype app" width="900">
</p>

This is part of a series of prototyping repos:

1. [Local model speech-to-text transcription library running from a Tauri2 desktop app](https://github.com/tleyden/tauri2-stt)
2. (this repo) [Text-to-speech local model from Tauri/rust](https://github.com/tleyden/tauri2-qwen3-tts)
3. [Gemma4-12b from Tauri/rust](https://github.com/tleyden/tauri2-local-llm)

These were created as part of prototyping the different options for use in a few apps I'm building: [Fluensy](https://fluensy.app) (foreign language learning app for professionals) and [brain3](https://github.com/tleyden/brain3) (MCP server for markdown vaults)

## P0 Requirements

1. Supports Qwen3-TTS
2. Runs on macOS

## Design notes - best integration strategy?

### Option 1: llama.cpp native integration via FFI

This is the approach used for Gemma 4 in a sibling prototype ([tauri2-local-llm](https://github.com/tleyden/tauri2-local-llm)), and it's been working well there.

#### Risks

1. llama.cpp does not yet support Qwen3-TTS — there's an open issue tracking support. Until that lands, this option is blocked for this project AFAIK.  See [llama.cpp #21956](https://github.com/ggml-org/llama.cpp/issues/21956)

### Option 2: mlx-swift-qwen3-tts (hamptus) - implemented via Swift/MLX bridge, ⚠️ but getting garbled audio

Repo: [hamptus/mlx-swift-qwen3-tts](https://github.com/hamptus/mlx-swift-qwen3-tts)

Local implementation:

- [hamptus-mlx-swift-qwen3-tts](./hamptus-mlx-swift-qwen3-tts): Tauri 2 desktop app with the React UI, Rust backend, and Swift-only proof of concept.
- [qwen3-tts-swift-rs](./qwen3-tts-swift-rs): Rust <-> Swift bridge crate consumed by the Tauri app.

To run the Tauri app after downloading the model from `hamptus-mlx-swift-qwen3-tts/swift-only-poc`:

```bash
cd hamptus-mlx-swift-qwen3-tts
bun run tauri dev
```

#### Strengths

1. Actually streams PCM audio chunks (not just streamed tokens followed by one final audio blob)
2. Good SDK ergonomics: `generateToFile()`, `AudioSampleWriter`, `StreamingWAVWriter`
3. Solves long-form generation: chunking, crossfade, long-form text

#### Risks

1. More complicated toolchain than a pure Rust/FFI approach (Swift + MLX)
2. Would need a Rust <-> Swift bridge to call from a Tauri2 (Rust) backend
3. I am getting completely garbled audio: https://github.com/tleyden/tauri2-qwen3-tts/issues/3

### Option 3: swift-qwen3-tts (AtomGradient)

Repo: [AtomGradient/swift-qwen3-tts](https://github.com/AtomGradient/swift-qwen3-tts)

#### Risks


#### Strengths

1. Architecture is explicitly documented: Tokenizer → Talker → Code Predictor → Speech Tokenizer → Audio, which suggests the author understands the model rather than just wrapping it
2. Published a paper covering compression work: vocabulary pruning, tokenizer pruning, quantization
3. API (`Qwen3TTSModel`) feels closer to raw MLX than a `Pipeline`-style wrapper, which usually means less framework overhead
4. Exposes generation controls directly: top-k, top-p, repetition penalty, language, temperature

#### Risks

1. Docs seemed a bit crytpic
2. No real streaming yet — the README says final audio is still delivered as a single `MLXArray`, i.e. token-by-token generation followed by one final audio blob, not streamed audio chunks. That's a significant limitation for Fluensy.
3. Requires manually copying `default.metallib` — unclear why, whether it's temporary, or whether it complicates packaging inside a Tauri app
4. Same toolchain and Rust <-> Swift bridging concerns as Option 2

### Option 4: mlx-rs

#### Risks

1. Would need to confirm Qwen3-TTS model support directly in mlx-rs rather than going through a Swift wrapper


### Option 5: Supertonic via supertonic-rs  (implemented)

Repo: https://github.com/TheoSlater/supertonic-rs

#### Strengths

1. No GPU required
2. Small/fast model
3. Multi-lingual 

#### Risks

1. License requires attribution in commercial apps


## Conclusion

I ended up going with Supertonic via supertonic-rs due to https://github.com/tleyden/tauri2-qwen3-tts/issues/3.  There's no code example in this repo, because https://github.com/TheoSlater/supertonic-rs just works out of the box.
