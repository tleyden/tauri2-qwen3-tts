import Foundation
import Qwen3TTS

private enum PocError: Error, CustomStringConvertible {
    case missingModel(URL)
    case missingModelsDirectory(URL)
    case noSpeakers(String)
    case unknownSpeaker(String, available: [String])
    case cancelledInput
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
        case let .missingModelsDirectory(url):
            return """
            No models found in:
              \(url.path)

            Download a model first:
              scripts/download-model.sh
            """
        case let .noSpeakers(modelName):
            return "Model \(modelName) did not report any built-in speakers."
        case let .unknownSpeaker(speaker, available):
            return """
            Speaker \(speaker) was not reported by the loaded model.
            Available speakers:
              \(available.joined(separator: ", "))
            """
        case .cancelledInput:
            return "Input cancelled."
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

private struct Qwen3TTSPoc {
    private static let sampleRate = Qwen3TTSPipeline.sampleRate
    private static let samplesPerAcousticFrame = 1_920
    private static let defaultText = "Hello from the Swift only Qwen three T T S proof of concept."
    private static let defaultSpeaker = "Aiden"
    private static let modelDirectoryName = "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())

            if arguments.contains("--help") || arguments.contains("-h") {
                printUsage()
                return
            }

            let rootURL = packageRootURL()

            if arguments.contains("--stream") {
                let repositoryRoot = InteractiveCLI.repositoryRoot(packageRoot: rootURL)
                let outputURL = rootURL.appendingPathComponent("output", isDirectory: true)
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

                let modelURL = repositoryRoot
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

                try await runStreamingSmokeTest(
                    pipeline: pipeline,
                    outputURL: outputURL.appendingPathComponent("streaming.wav")
                )
            } else if arguments.contains("--text-file") {
                let request = try GenerationRequest.parse(arguments: arguments)
                try runBatchGeneration(request: request, rootURL: rootURL)
            } else {
                try runInteractiveGeneration(rootURL: rootURL)
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
          swift run Qwen3TTSPoc             Pick a model and voice, then generate a WAV
          swift run Qwen3TTSPoc --stream    Run streaming generation
          swift run Qwen3TTSPoc --model MODEL --speaker SPEAKER --text-file PATH --output PATH
                                            Generate a WAV from a text file

        One-time setup:
          scripts/download-model.sh
        """)
    }

    private static func runInteractiveGeneration(rootURL: URL) throws {
        let models = try InteractiveCLI.discoverModels(packageRoot: rootURL)
        guard !models.isEmpty else {
            let repositoryRoot = InteractiveCLI.repositoryRoot(packageRoot: rootURL)
            throw PocError.missingModelsDirectory(
                repositoryRoot.appendingPathComponent(".models", isDirectory: true)
            )
        }

        guard let model = InteractiveCLI.promptForChoice(
            title: "Which model?",
            options: models,
            label: { $0.name }
        ) else {
            throw PocError.cancelledInput
        }

        try validateModel(at: model.url)

        let loadTimer = Stopwatch()
        print("Loading model: \(model.url.path)")
        let pipeline = try Qwen3TTSPipeline(modelPath: model.url)
        print("Model loaded in \(formatSeconds(loadTimer.elapsed))")

        let speakers = pipeline.availableSpeakers
        guard !speakers.isEmpty else {
            throw PocError.noSpeakers(model.name)
        }

        guard let speaker = InteractiveCLI.promptForChoice(
            title: "Which voice?",
            options: speakers,
            label: { $0 }
        ) else {
            throw PocError.cancelledInput
        }

        guard let text = InteractiveCLI.promptForText(title: "What do you want to say?") else {
            throw PocError.cancelledInput
        }

        let generatedDirectory = rootURL.appendingPathComponent(".generated", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        let outputURL = InteractiveCLI.generatedWavURL(packageRoot: rootURL)

        let generationTimer = Stopwatch()
        let samples = pipeline.generate(text: text, speaker: speaker)
        try AudioSampleWriter.write(samples: samples, to: outputURL)

        printMetrics(
            mode: "interactive",
            samples: samples,
            generationSeconds: generationTimer.elapsed,
            firstAudioSeconds: nil,
            outputURL: outputURL
        )
        print("Generated WAV: \(outputURL.path)")
    }

    private static func runBatchGeneration(request: GenerationRequest, rootURL: URL) throws {
        let repositoryRoot = InteractiveCLI.repositoryRoot(packageRoot: rootURL)
        let modelURL = repositoryRoot
            .appendingPathComponent(".models", isDirectory: true)
            .appendingPathComponent(request.modelName, isDirectory: true)
        try validateModel(at: modelURL)

        let loadTimer = Stopwatch()
        print("Loading model: \(modelURL.path)")
        let pipeline = try Qwen3TTSPipeline(modelPath: modelURL)
        print("Model loaded in \(formatSeconds(loadTimer.elapsed))")

        let speakers = pipeline.availableSpeakers
        guard speakers.contains(request.speaker) else {
            throw PocError.unknownSpeaker(request.speaker, available: speakers)
        }

        let text = try request.loadText(relativeTo: rootURL)
        let outputURL = request.outputURL(relativeTo: rootURL)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        print("Selected speaker: \(request.speaker)")
        print("Text file: \(request.textFilePath)")
        print("Characters: \(text.count)")

        let generationTimer = Stopwatch()
        let samples = pipeline.generate(text: text, speaker: request.speaker)
        try AudioSampleWriter.write(samples: samples, to: outputURL)

        printMetrics(
            mode: "batch",
            samples: samples,
            generationSeconds: generationTimer.elapsed,
            firstAudioSeconds: nil,
            outputURL: outputURL
        )
        print("Generated WAV: \(outputURL.path)")
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

        let hasTokenizerJSON = FileManager.default.fileExists(
            atPath: modelURL.appendingPathComponent("tokenizer.json").path
        )
        let hasTokenizerPair = FileManager.default.fileExists(
            atPath: modelURL.appendingPathComponent("vocab.json").path
        ) && FileManager.default.fileExists(
            atPath: modelURL.appendingPathComponent("merges.txt").path
        )

        if !hasTokenizerJSON && !hasTokenizerPair {
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

await Qwen3TTSPoc.main()
