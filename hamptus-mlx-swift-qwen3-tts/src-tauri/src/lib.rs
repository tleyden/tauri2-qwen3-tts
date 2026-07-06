use base64::Engine;

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
) -> Result<String, String> {
    let chunk_size = chunk_size.unwrap_or(qwen3_tts_swift_rs::DEFAULT_CHUNK_SIZE);
    qwen3_tts_swift_rs::synthesize_with_chunk_size(&text, &speaker, chunk_size)
        .map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes))
        .ok_or_else(|| "synthesis failed -- see stderr for details".to_string())
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn synthesize_speech(
    _text: String,
    _speaker: String,
    _chunk_size: Option<usize>,
) -> Result<String, String> {
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
