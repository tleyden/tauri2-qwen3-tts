use base64::Engine;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SynthesisResponse {
    base64_wav: String,
    file_path: String,
}

fn generated_audio_dir() -> PathBuf {
    std::env::temp_dir().join("qwen3-tts-generated")
}

fn current_timestamp_millis() -> Result<u128, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .map_err(|err| format!("system clock is before UNIX_EPOCH: {err}"))
}

fn write_generated_wav(
    output_dir: &Path,
    timestamp_millis: u128,
    wav_bytes: &[u8],
) -> Result<PathBuf, String> {
    std::fs::create_dir_all(output_dir)
        .map_err(|err| format!("failed to create generated audio directory: {err}"))?;

    let path = output_dir.join(format!("qwen3tts-{timestamp_millis}.wav"));
    std::fs::write(&path, wav_bytes).map_err(|err| {
        format!(
            "failed to write generated audio to {}: {err}",
            path.display()
        )
    })?;
    Ok(path)
}

// Repo-root .models/ layout, same as hamptus-mlx-swift-qwen3-tts/swift-only-poc and
// qwen3-tts-swift-rs/examples/synthesize.rs.
#[cfg(target_os = "macos")]
fn default_model_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../.models/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit")
}

#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

#[cfg(target_os = "macos")]
#[tauri::command]
fn available_speakers() -> Result<Vec<String>, String> {
    qwen3_tts_swift_rs::available_speakers().ok_or_else(|| "no model loaded".to_string())
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn available_speakers() -> Result<Vec<String>, String> {
    Err("Qwen3-TTS bridge is only available on macOS".to_string())
}

/// Synthesizes `text` with `speaker` and returns a base64-encoded WAV file, so the
/// frontend can play it directly via a `data:audio/wav;base64,...` URL.
#[cfg(target_os = "macos")]
#[tauri::command]
fn synthesize_speech(
    text: String,
    speaker: String,
    chunk_size: Option<usize>,
) -> Result<SynthesisResponse, String> {
    let chunk_size = chunk_size.unwrap_or(qwen3_tts_swift_rs::DEFAULT_CHUNK_SIZE);
    let wav_bytes = qwen3_tts_swift_rs::synthesize_with_chunk_size(&text, &speaker, chunk_size)
        .ok_or_else(|| "synthesis failed -- see stderr for details".to_string())?;
    let path = write_generated_wav(
        &generated_audio_dir(),
        current_timestamp_millis()?,
        &wav_bytes,
    )?;

    Ok(SynthesisResponse {
        base64_wav: base64::engine::general_purpose::STANDARD.encode(wav_bytes),
        file_path: path.to_string_lossy().into_owned(),
    })
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn synthesize_speech(
    _text: String,
    _speaker: String,
    _chunk_size: Option<usize>,
) -> Result<SynthesisResponse, String> {
    Err("Qwen3-TTS bridge is only available on macOS".to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|_app| {
            #[cfg(target_os = "macos")]
            {
                qwen3_tts_swift_rs::ensure_metallib_installed()
                    .expect("failed to write mlx.metallib next to the app binary");

                let model_path = default_model_path();
                let model_path = model_path
                    .to_str()
                    .expect("model path must be valid UTF-8")
                    .to_string();
                if qwen3_tts_swift_rs::load_model(&model_path) {
                    println!("Qwen3-TTS: model loaded from {model_path}");
                } else {
                    eprintln!(
                        "Qwen3-TTS: failed to load model from {model_path} -- \
                         run hamptus-mlx-swift-qwen3-tts/swift-only-poc/scripts/download-model.sh first"
                    );
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            greet,
            available_speakers,
            synthesize_speech
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_generated_wav_to_named_file() {
        let dir =
            std::env::temp_dir().join(format!("qwen3-tts-generated-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let path = write_generated_wav(&dir, 12345, b"RIFFdata").expect("wav should be written");

        assert_eq!(path.file_name().unwrap(), "qwen3tts-12345.wav");
        assert_eq!(std::fs::read(&path).unwrap(), b"RIFFdata");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
