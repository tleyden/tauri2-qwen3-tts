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
