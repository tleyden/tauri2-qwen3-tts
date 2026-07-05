import XCTest
@testable import Qwen3TTSPoc

final class GenerationRequestTests: XCTestCase {
    func testParsesBatchGenerationArguments() throws {
        let request = try GenerationRequest.parse(arguments: [
            "--model", "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
            "--speaker", "Aiden",
            "--text-file", "examples/podcast1.txt",
            "--output", ".generated/podcast1.wav",
        ])

        XCTAssertEqual(request.modelName, "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit")
        XCTAssertEqual(request.speaker, "Aiden")
        XCTAssertEqual(request.textFilePath, "examples/podcast1.txt")
        XCTAssertEqual(request.outputPath, ".generated/podcast1.wav")
    }

    func testLoadsMultilineScriptTextFromFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("podcast.txt")
        let script = """
        Host 1: Welcome to the show!

        Host 2: This is a longer script with multiple turns.
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let request = GenerationRequest(
            modelName: "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
            speaker: "Aiden",
            textFilePath: scriptURL.path,
            outputPath: ".generated/podcast1.wav"
        )

        XCTAssertEqual(try request.loadText(relativeTo: directory), script)
    }
}
