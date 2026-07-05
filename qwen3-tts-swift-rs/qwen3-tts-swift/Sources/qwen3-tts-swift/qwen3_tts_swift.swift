import Foundation
import SwiftRs
import Qwen3TTS

private final class TTSState {
    static var pipeline: Qwen3TTSPipeline?
}

/**
 * Loads a Qwen3-TTS model from `modelPath` (a directory containing config.json,
 * model.safetensors, tokenizer files, etc. -- same layout as swift-only-poc/.models/).
 * Must be called once before `synthesize_swift`.
 */
@_cdecl("load_model_swift")
public func loadModelSwift(modelPath: SRString) -> Bool {
    do {
        let url = URL(fileURLWithPath: modelPath.toString())
        TTSState.pipeline = try Qwen3TTSPipeline(modelPath: url)
        return true
    } catch {
        print("qwen3-tts-swift: failed to load model: \(error)")
        return false
    }
}

/**
 * Returns the model's built-in speaker names, joined with "\n", or nil if no
 * model is loaded yet.
 */
@_cdecl("available_speakers_swift")
public func availableSpeakersSwift() -> SRString? {
    guard let pipeline = TTSState.pipeline else {
        return nil
    }
    return SRString(pipeline.availableSpeakers.joined(separator: "\n"))
}

/**
 * Synthesizes `text` with `speaker` and returns a complete WAV file as bytes,
 * or nil if no model is loaded or generation/encoding failed.
 */
@_cdecl("synthesize_swift")
public func synthesizeSwift(text: SRString, speaker: SRString) -> SRData? {
    guard let pipeline = TTSState.pipeline else {
        print("qwen3-tts-swift: synthesize_swift called before load_model_swift")
        return nil
    }

    let samples = pipeline.generate(text: text.toString(), speaker: speaker.toString())

    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")

    do {
        try AudioSampleWriter.write(samples: samples, to: tmpURL)
        let data = try Data(contentsOf: tmpURL)
        try? FileManager.default.removeItem(at: tmpURL)
        return SRData([UInt8](data))
    } catch {
        print("qwen3-tts-swift: failed to write/read WAV: \(error)")
        return nil
    }
}
