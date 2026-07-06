# supertonic-cli

Simple CLI for on-device TTS using the [supertonic-rs](https://github.com/TheoSlater/supertonic-rs) `st-tts` crate.

## Run

```bash
cargo run --release -- "Hello world, this is a test." -o output.wav
```

On first run this downloads and caches the Supertonic model (~400MB) from
HuggingFace to `~/Library/Application Support/supertonic` (macOS). Subsequent
runs reuse the cached model.

## Options

```
Usage: supertonic-cli [OPTIONS] <TEXT>

Arguments:
  <TEXT>  Text to synthesize

Options:
  -l, --lang <LANG>    Language code [default: en]
  -o, --out <OUT>      Output WAV file path [default: output.wav]
      --model <MODEL>  HuggingFace model id (downloaded and cached on first run) [default: Supertone/supertonic-3]
      --voice <VOICE>  Voice name [default: M1]
  -h, --help           Print help
```

Available voices for `Supertone/supertonic-3`: `M1`, `M2`, `F1`, `F2`, `F3`, `F4`, `F5`.

## Example

```bash
cargo run --release -- "The quick brown fox jumps over the lazy dog." --voice F1 -o fox.wav
afplay fox.wav
```

## Integration Details

This crate is a thin CLI wrapper around the `st-tts` crate published from
[TheoSlater/supertonic-rs](https://github.com/TheoSlater/supertonic-rs)
(pulled from crates.io, not vendored — see `Cargo.toml`). `st-tts` itself
wraps three lower-level crates from that repo: `supertonic-core` (engine
pipeline), `supertonic-ort-backend` (ONNX Runtime backend), and
`supertonic-model-store` (HuggingFace download/caching).

`src/main.rs` parses CLI args with `clap`, calls `st_tts::Tts::new(model_id,
voice_name)` to load/download the model, then `tts.synthesize_wav(text,
lang, None)` to get WAV bytes, which are written to the `-o/--out` path.

**Model**: `Supertone/supertonic-3` (Supertonic's 99M-parameter TTS model),
downloaded from HuggingFace on first run and cached under
`~/Library/Application Support/supertonic` (macOS). It includes ONNX weights
for the text encoder, duration predictor, vector estimator, and vocoder,
plus 7 voice style presets (`M1`, `M2`, `F1`-`F5`).

**Tests**: there are no automated tests in this crate. The integration was
verified manually by running the CLI end-to-end (triggering the model
download, generating `output.wav`, and confirming valid 16-bit PCM WAV
output with `afplay`).
