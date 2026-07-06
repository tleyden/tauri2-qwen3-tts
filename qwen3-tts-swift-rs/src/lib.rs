use std::path::PathBuf;

use swift_rs::{swift, SRData, SRString};

pub const DEFAULT_CHUNK_SIZE: usize = 500;

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
    synthesize_with_chunk_size(text, speaker, DEFAULT_CHUNK_SIZE)
}

/// Synthesizes `text` with character-based chunking. `chunk_size == 0` preserves the
/// old behavior and sends the full text to Qwen3 in a single call.
pub fn synthesize_with_chunk_size(text: &str, speaker: &str, chunk_size: usize) -> Option<Vec<u8>> {
    let chunks = split_text_for_qwen3(text, chunk_size);
    if chunks.len() == 1 {
        return synthesize_one(&chunks[0], speaker);
    }

    let wavs = chunks
        .iter()
        .map(|chunk| synthesize_one(chunk, speaker))
        .collect::<Option<Vec<_>>>()?;
    merge_wav_chunks(wavs)
}

fn synthesize_one(text: &str, speaker: &str) -> Option<Vec<u8>> {
    let text: SRString = text.into();
    let speaker: SRString = speaker.into();
    let result = unsafe { synthesize_swift(&text, &speaker) };
    result.map(|data| data.to_vec())
}

fn split_text_for_qwen3(text: &str, chunk_size: usize) -> Vec<String> {
    if chunk_size == 0 || text.is_empty() || text.chars().count() <= chunk_size {
        return vec![text.to_string()];
    }

    let hard_limit = chunk_size.saturating_add(50);
    let mut chunks = Vec::new();
    let mut remaining = text.trim();

    while remaining.chars().count() > chunk_size {
        let split_at = choose_split_index(remaining, chunk_size, hard_limit);
        let (chunk, rest) = remaining.split_at(split_at);
        let chunk = chunk.trim();
        if !chunk.is_empty() {
            chunks.push(chunk.to_string());
        }
        remaining = rest.trim_start();
        if remaining.is_empty() {
            break;
        }
    }

    if !remaining.is_empty() {
        chunks.push(remaining.to_string());
    }
    chunks
}

fn choose_split_index(text: &str, soft_limit: usize, hard_limit: usize) -> usize {
    let soft_index = byte_index_at_char_limit(text, soft_limit);
    let hard_index = byte_index_at_char_limit(text, hard_limit);

    last_boundary_before(text, soft_index, is_sentence_boundary)
        .or_else(|| first_boundary_after(text, soft_index, hard_index, is_sentence_boundary))
        .or_else(|| last_boundary_before(text, soft_index, char::is_whitespace))
        .or_else(|| first_boundary_after(text, soft_index, hard_index, char::is_whitespace))
        .unwrap_or(hard_index)
}

fn byte_index_at_char_limit(text: &str, char_limit: usize) -> usize {
    text.char_indices()
        .nth(char_limit)
        .map(|(idx, _)| idx)
        .unwrap_or(text.len())
}

fn last_boundary_before<F>(text: &str, limit: usize, predicate: F) -> Option<usize>
where
    F: Fn(char) -> bool,
{
    text[..limit]
        .char_indices()
        .filter_map(|(idx, ch)| predicate(ch).then_some(idx + ch.len_utf8()))
        .last()
        .filter(|idx| *idx > 0)
}

fn first_boundary_after<F>(text: &str, start: usize, end: usize, predicate: F) -> Option<usize>
where
    F: Fn(char) -> bool,
{
    text[start..end]
        .char_indices()
        .find_map(|(idx, ch)| predicate(ch).then_some(start + idx + ch.len_utf8()))
}

fn is_sentence_boundary(ch: char) -> bool {
    matches!(ch, '.' | '!' | '?' | ';' | ':' | '\n')
}

fn merge_wav_chunks(wavs: Vec<Vec<u8>>) -> Option<Vec<u8>> {
    let mut iter = wavs.into_iter();
    let mut merged = iter.next()?;
    let first_layout = wav_layout(&merged)?;
    let header_signature = merged[12..first_layout.data_size_offset].to_vec();
    let mut audio_data = merged[first_layout.data_start..first_layout.data_end].to_vec();

    for wav in iter {
        let layout = wav_layout(&wav)?;
        if wav[12..layout.data_size_offset] != header_signature {
            return None;
        }
        audio_data.extend_from_slice(&wav[layout.data_start..layout.data_end]);
    }

    let data_len = u32::try_from(audio_data.len()).ok()?;
    let riff_len = u32::try_from(first_layout.data_start + audio_data.len() - 8).ok()?;

    merged.truncate(first_layout.data_start);
    merged.extend_from_slice(&audio_data);
    merged[4..8].copy_from_slice(&riff_len.to_le_bytes());
    merged[first_layout.data_size_offset..first_layout.data_size_offset + 4]
        .copy_from_slice(&data_len.to_le_bytes());
    Some(merged)
}

struct WavLayout {
    data_size_offset: usize,
    data_start: usize,
    data_end: usize,
}

fn wav_layout(wav: &[u8]) -> Option<WavLayout> {
    if wav.len() < 12 || &wav[0..4] != b"RIFF" || &wav[8..12] != b"WAVE" {
        return None;
    }

    let mut offset = 12;
    while offset + 8 <= wav.len() {
        let chunk_id = &wav[offset..offset + 4];
        let chunk_size = u32::from_le_bytes(wav[offset + 4..offset + 8].try_into().ok()?) as usize;
        let data_start = offset + 8;
        let data_end = data_start.checked_add(chunk_size)?;
        if data_end > wav.len() {
            return None;
        }
        if chunk_id == b"data" {
            return Some(WavLayout {
                data_size_offset: offset + 4,
                data_start,
                data_end,
            });
        }
        offset = data_end + (chunk_size % 2);
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_chunk_size_keeps_text_as_one_chunk() {
        let text = "one two three four five";

        assert_eq!(split_text_for_qwen3(text, 0), vec![text.to_string()]);
    }

    #[test]
    fn chunks_text_by_characters_without_splitting_words_when_possible() {
        let chunks = split_text_for_qwen3("alpha beta gamma delta epsilon", 12);

        assert_eq!(
            chunks,
            vec![
                "alpha beta".to_string(),
                "gamma delta".to_string(),
                "epsilon".to_string()
            ]
        );
    }

    #[test]
    fn allows_sentence_completion_past_soft_limit_until_hard_limit() {
        let chunks = split_text_for_qwen3("First sentence. Second sentence.", 20);

        assert_eq!(
            chunks,
            vec![
                "First sentence.".to_string(),
                "Second sentence.".to_string()
            ]
        );
    }

    #[test]
    fn hard_splits_long_unbroken_text_on_character_boundaries() {
        let chunks = split_text_for_qwen3(&"a".repeat(56), 3);

        assert_eq!(chunks, vec!["a".repeat(53), "aaa".to_string()]);
    }

    #[test]
    fn merges_pcm_wav_data_chunks_and_updates_header_lengths() {
        let first = test_wav(&[1, 2, 3, 4]);
        let second = test_wav(&[5, 6, 7, 8, 9, 10]);

        let merged = merge_wav_chunks(vec![first, second]).expect("merge should succeed");

        assert_eq!(&merged[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(merged[4..8].try_into().unwrap()), 46);
        assert_eq!(&merged[8..12], b"WAVE");
        assert_eq!(u32::from_le_bytes(merged[40..44].try_into().unwrap()), 10);
        assert_eq!(&merged[44..54], &[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    }

    fn test_wav(data: &[u8]) -> Vec<u8> {
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
        wav.extend_from_slice(b"WAVE");
        wav.extend_from_slice(b"fmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&24_000u32.to_le_bytes());
        wav.extend_from_slice(&48_000u32.to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(data.len() as u32).to_le_bytes());
        wav.extend_from_slice(data);
        wav
    }
}
