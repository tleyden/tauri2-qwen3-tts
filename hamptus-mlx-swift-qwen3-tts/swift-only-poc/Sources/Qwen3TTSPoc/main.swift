import Foundation
import Qwen3TTS

private enum PocError: Error, CustomStringConvertible {
    case missingModel(URL)
    case processLaunchFailed(String, Int32)

    var description: String {
        switch self {
        case let .missingModel(url):
            return """
            Model not found at:
              \(url.path)

            Download it first:
              scripts/download-model.sh
            """
        case let .processLaunchFailed(command, status):
            return "\(command) exited with status \(status)"
        }
    }
}

private struct Stopwatch {
    private let start = Date()

    var elapsed: TimeInterval {
        Date().timeIntervalSince(start)
    }
}

private let sampleRate = Qwen3TTSPipeline.sampleRate
private let samplesPerAcousticFrame = 1_920
private let defaultText = "Hello from the Swift only Qwen three T T S proof of concept."
private let defaultSpeaker = "Aiden"
private let modelDirectoryName = "Qwen3-TTS-12Hz-1.7B-Base-8bit"

@main
private struct Qwen3TTSPoc {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())

            if arguments.contains("--help") || arguments.contains("-h") {
                printUsage()
                return
            }

            let rootURL = packageRootURL()
            let outputURL = rootURL.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

            let modelURL = rootURL
                .appendingPathComponent(".models", isDirectory: true)
                .appendingPathComponent(modelDirectoryName, isDirectory: true)
            try validateModel(at: modelURL)

            let loadTimer = Stopwatch()
            print("Loading model: \(modelURL.path)")
            let pipeline = try Qwen3TTSPipeline(modelPath: modelURL)
            let loadSeconds = loadTimer.elapsed
            print("Model loaded in \(formatSeconds(loadSeconds))")
            print("Available speakers: \(pipeline.availableSpeakers.joined(separator: ", "))")
            print("Selected speaker: \(defaultSpeaker)")
            print("Text: \(defaultText)")

            if arguments.contains("--stream") {
                try await runStreamingSmokeTest(
                    pipeline: pipeline,
                    outputURL: outputURL.appendingPathComponent("streaming.wav")
                )
            } else {
                try runBaselineSmokeTest(
                    pipeline: pipeline,
                    outputURL: outputURL.appendingPathComponent("baseline.wav")
                )
            }
        } catch {
            fputs("Qwen3TTSPoc failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print("""
        Qwen3TTSPoc

        Usage:
          swift run Qwen3TTSPoc             Run baseline non-streaming generation
          swift run Qwen3TTSPoc --stream    Run streaming generation

        One-time setup:
          scripts/download-model.sh
        """)
    }

    private static func runBaselineSmokeTest(
        pipeline: Qwen3TTSPipeline,
        outputURL: URL
    ) throws {
        let generationTimer = Stopwatch()
        let samples = pipeline.generate(text: defaultText, speaker: defaultSpeaker)
        let generationSeconds = generationTimer.elapsed

        try AudioSampleWriter.write(samples: samples, to: outputURL)

        printMetrics(
            mode: "baseline",
            samples: samples,
            generationSeconds: generationSeconds,
            firstAudioSeconds: nil,
            outputURL: outputURL
        )

        try playAudio(at: outputURL)
    }

    private static func runStreamingSmokeTest(
        pipeline: Qwen3TTSPipeline,
        outputURL: URL
    ) async throws {
        let generationTimer = Stopwatch()
        var firstAudioSeconds: TimeInterval?
        var samples: [Float] = []
        var chunkCount = 0

        for try await chunk in pipeline.generateStream(text: defaultText, speaker: defaultSpeaker) {
            chunkCount += 1

            if !chunk.samples.isEmpty {
                if firstAudioSeconds == nil {
                    firstAudioSeconds = generationTimer.elapsed
                }
                samples.append(contentsOf: chunk.samples)
            }

            if chunk.isFinal {
                break
            }
        }

        let generationSeconds = generationTimer.elapsed
        try AudioSampleWriter.write(samples: samples, to: outputURL)

        print("Streaming chunks: \(chunkCount)")
        printMetrics(
            mode: "streaming",
            samples: samples,
            generationSeconds: generationSeconds,
            firstAudioSeconds: firstAudioSeconds,
            outputURL: outputURL
        )

        try playAudio(at: outputURL)
    }

    private static func validateModel(at modelURL: URL) throws {
        let requiredPaths = [
            modelURL.appendingPathComponent("config.json"),
            modelURL.appendingPathComponent("tokenizer.json"),
            modelURL.appendingPathComponent("speech_tokenizer", isDirectory: true),
        ]

        let missingPath = requiredPaths.first {
            !FileManager.default.fileExists(atPath: $0.path)
        }

        if missingPath != nil {
            throw PocError.missingModel(modelURL)
        }

        let modelFiles = try FileManager.default.contentsOfDirectory(
            at: modelURL,
            includingPropertiesForKeys: nil
        )
        let hasSafetensors = modelFiles.contains {
            $0.pathExtension == "safetensors"
        }

        if !hasSafetensors {
            throw PocError.missingModel(modelURL)
        }
    }

    private static func packageRootURL() -> URL {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        if FileManager.default.fileExists(atPath: currentDirectory.appendingPathComponent("Package.swift").path) {
            return currentDirectory
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let ancestors = sequence(first: executableURL.deletingLastPathComponent()) { url in
            let parent = url.deletingLastPathComponent()
            return parent.path == url.path ? nil : parent
        }

        if let packageRoot = ancestors.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path)
        }) {
            return packageRoot
        }

        return currentDirectory
    }

    private static func printMetrics(
        mode: String,
        samples: [Float],
        generationSeconds: TimeInterval,
        firstAudioSeconds: TimeInterval?,
        outputURL: URL
    ) {
        let audioSeconds = Double(samples.count) / Double(sampleRate)
        let acousticFrames = Double(samples.count) / Double(samplesPerAcousticFrame)
        let acousticFramesPerSecond = generationSeconds > 0 ? acousticFrames / generationSeconds : 0
        let realTimeFactor = audioSeconds > 0 ? generationSeconds / audioSeconds : 0

        print("")
        print("Mode: \(mode)")
        if let firstAudioSeconds {
            print("Time to first audio chunk: \(formatSeconds(firstAudioSeconds))")
        }
        print("Generation wall time: \(formatSeconds(generationSeconds))")
        print("Generated audio duration: \(formatSeconds(audioSeconds))")
        print("Generated samples: \(samples.count)")
        print("Approx acoustic frames/sec: \(formatDouble(acousticFramesPerSecond))")
        print("Real-time factor: \(formatDouble(realTimeFactor))x")
        print("Wrote: \(outputURL.path)")
    }

    private static func playAudio(at url: URL) throws {
        print("Playing with afplay...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw PocError.processLaunchFailed("afplay", process.terminationStatus)
        }
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        "\(formatDouble(seconds))s"
    }

    private static func formatDouble(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
