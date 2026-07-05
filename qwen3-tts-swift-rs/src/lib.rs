use std::path::PathBuf;

use swift_rs::{swift, SRData, SRString};

/// The default.metallib produced by xcodebuild's Metal-compiler build phase (see build.rs --
/// plain `swift build` never produces this, since mlx-swift's Cmlx target relies on Xcode
/// to compile its .metal sources and declares no SwiftPM `resources:`). Embedded directly
/// in the crate so callers don't need a separate resource-packaging step.
static METALLIB_BYTES: &[u8] = include_bytes!(env!("QWEN3_TTS_METALLIB_PATH"));

/// Writes the embedded MLX metallib next to the current executable, where MLX's runtime
/// looks for it first (`current_binary_dir()/mlx.metallib` -- see mlx/backend/metal/device.cpp).
/// Must be called once before `load_model`.
///
/// Note: this only works when the executable's directory is writable, which holds for
/// `cargo run`/dev builds but not necessarily for a notarized, installed .app bundle -- that
/// case needs a different (Application Support / SwiftPM-bundle) strategy, tracked as a
/// packaging open question in docs/2026-07-05-rust-swift-bridge-plan.md.
pub fn ensure_metallib_installed() -> std::io::Result<PathBuf> {
    let exe = std::env::current_exe()?;
    let dest = exe
        .parent()
        .expect("current_exe() always has a parent directory")
        .join("mlx.metallib");
    if !dest.exists() {
        std::fs::write(&dest, METALLIB_BYTES)?;
    }
    Ok(dest)
}

swift!(fn load_model_swift(model_path: &SRString) -> bool);
swift!(fn available_speakers_swift() -> Option<SRString>);
swift!(fn synthesize_swift(text: &SRString, speaker: &SRString) -> Option<SRData>);

/// Loads a Qwen3-TTS model from `model_path` (a directory containing config.json,
/// model.safetensors, tokenizer files, etc.). Must be called once before `synthesize`.
pub fn load_model(model_path: &str) -> bool {
    let model_path: SRString = model_path.into();
    unsafe { load_model_swift(&model_path) }
}

/// Returns the loaded model's built-in speaker names, or `None` if no model is loaded.
pub fn available_speakers() -> Option<Vec<String>> {
    let result = unsafe { available_speakers_swift() };
    result.map(|s| s.as_str().split('\n').map(String::from).collect())
}

/// Synthesizes `text` with `speaker` and returns a complete WAV file as bytes,
/// or `None` if no model is loaded or generation failed.
pub fn synthesize(text: &str, speaker: &str) -> Option<Vec<u8>> {
    let text: SRString = text.into();
    let speaker: SRString = speaker.into();
    let result = unsafe { synthesize_swift(&text, &speaker) };
    result.map(|data| data.to_vec())
}
