//! Decisive end-to-end test for the plan's Step 3: load a real Qwen3-TTS model and
//! synthesize speech entirely through the swift-rs bridge, built with plain `swift build`
//! (no xcodebuild). Run with:
//!
//!   cargo run --example synthesize
//!
//! Optionally set PLAY=1 to play the result with afplay, and MODEL_PATH/SPEAKER/TEXT to
//! override the defaults.

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn default_model_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join(".models")
        .join("Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit")
}

fn main() {
    let model_path = env::var("MODEL_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| default_model_path());
    let speaker = env::var("SPEAKER").unwrap_or_else(|_| "Aiden".to_string());
    let text = env::var("TEXT")
        .unwrap_or_else(|_| "Hello from the Rust side of the Qwen three T T S bridge.".to_string());
    let chunk_size = env::var("CHUNK_SIZE")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(qwen3_tts_swift_rs::DEFAULT_CHUNK_SIZE);

    let metallib_path = qwen3_tts_swift_rs::ensure_metallib_installed()
        .expect("failed to write mlx.metallib next to the current executable");
    println!("Installed metallib at: {}", metallib_path.display());

    println!("Loading model: {}", model_path.display());
    let load_start = std::time::Instant::now();
    let loaded = qwen3_tts_swift_rs::load_model(
        model_path.to_str().expect("model path must be valid UTF-8"),
    );
    if !loaded {
        eprintln!("load_model failed -- see Swift stderr output above");
        std::process::exit(1);
    }
    println!("Model loaded in {:.3}s", load_start.elapsed().as_secs_f64());

    if let Some(speakers) = qwen3_tts_swift_rs::available_speakers() {
        println!("Available speakers: {}", speakers.join(", "));
    }

    println!("Speaker: {speaker}");
    println!("Chunk size: {chunk_size}");
    println!("Text: {text}");

    let gen_start = std::time::Instant::now();
    let wav_bytes = qwen3_tts_swift_rs::synthesize_with_chunk_size(&text, &speaker, chunk_size);
    let gen_seconds = gen_start.elapsed().as_secs_f64();

    let Some(wav_bytes) = wav_bytes else {
        eprintln!("synthesize returned None -- generation or WAV encoding failed");
        std::process::exit(1);
    };

    println!(
        "Generated {} WAV bytes in {:.3}s",
        wav_bytes.len(),
        gen_seconds
    );

    let out_path = env::temp_dir().join("qwen3-tts-swift-rs-example.wav");
    std::fs::write(&out_path, &wav_bytes).expect("failed to write WAV file");
    println!("Wrote: {}", out_path.display());

    if env::var("PLAY").as_deref() == Ok("1") {
        println!("Playing with afplay...");
        let status = Command::new("/usr/bin/afplay")
            .arg(&out_path)
            .status()
            .expect("failed to launch afplay");
        if !status.success() {
            eprintln!("afplay exited with status {status}");
        }
    }
}
