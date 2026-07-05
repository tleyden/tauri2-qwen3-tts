# Qwen3 TTS Interactive CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an interactive Swift CLI in `hamptus-mlx-swift-qwen3-tts/swift-only-poc` that lets the user pick a downloaded model from the repo-root `.models/` directory, pick a built-in voice, type text, and generate a WAV in `.generated/`.

**Architecture:** Keep `Qwen3TTSPoc` as the single SwiftPM executable, but split pure CLI/path helpers away from `main.swift` so they can be tested without loading MLX or a multi-GB model. The default command becomes interactive; existing `--help` and `--stream` behavior can remain available for smoke testing.

**Tech Stack:** SwiftPM, Swift 6-compatible source, `Qwen3TTS`, `Foundation`, `XCTest`.

---

## File Structure

- Modify `hamptus-mlx-swift-qwen3-tts/swift-only-poc/Package.swift`
  Add a test target for CLI helper tests.
- Modify `hamptus-mlx-swift-qwen3-tts/swift-only-poc/.gitignore`
  Add `.generated/`.
- Modify `.gitignore`
  Ignore the repo-root `.models/` shared model cache.
- Create `hamptus-mlx-swift-qwen3-tts/swift-only-poc/Sources/Qwen3TTSPoc/InteractiveCLI.swift`
  Pure helpers for model discovery, numbered prompts, text prompt, and generated WAV filename creation.
- Modify `hamptus-mlx-swift-qwen3-tts/swift-only-poc/Sources/Qwen3TTSPoc/main.swift`
  Use the helpers in the default interactive path, load the selected model, list `pipeline.availableSpeakers`, generate speech, write `.generated/<timestamp>.wav`, and print the file path.
- Create `hamptus-mlx-swift-qwen3-tts/swift-only-poc/Tests/Qwen3TTSPocTests/InteractiveCLITests.swift`
  Tests for model discovery, selection parsing, text validation, and output filename behavior.

## Task 1: Add Test Target

**Files:**
- Modify: `hamptus-mlx-swift-qwen3-tts/swift-only-poc/Package.swift`
- Create: `hamptus-mlx-swift-qwen3-tts/swift-only-poc/Tests/Qwen3TTSPocTests/InteractiveCLITests.swift`

- [ ] **Step 1: Add the failing test file**

Create `Tests/Qwen3TTSPocTests/InteractiveCLITests.swift`:

```swift
import XCTest
@testable import Qwen3TTSPoc

final class InteractiveCLITests: XCTestCase {
    func testPlaceholderFailsUntilHelpersExist() throws {
        XCTAssertEqual(InteractiveCLI.placeholder, "ready")
    }
}
```

- [ ] **Step 2: Add the test target to `Package.swift`**

Add a test target after the executable target:

```swift
.testTarget(
    name: "Qwen3TTSPocTests",
    dependencies: ["Qwen3TTSPoc"]
),
```

- [ ] **Step 3: Run test to verify it fails**

Run:

```bash
cd hamptus-mlx-swift-qwen3-tts/swift-only-poc
swift test --filter InteractiveCLITests
```

Expected: FAIL because `InteractiveCLI` does not exist.

- [ ] **Step 4: Add minimal helper shell**

Create `Sources/Qwen3TTSPoc/InteractiveCLI.swift`:

```swift
import Foundation

enum InteractiveCLI {
    static let placeholder = "ready"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run:

```bash
swift test --filter InteractiveCLITests
```

Expected: PASS.

## Task 2: Discover Models In Repo-Root `.models`

**Files:**
- Modify: `Sources/Qwen3TTSPoc/InteractiveCLI.swift`
- Modify: `Tests/Qwen3TTSPocTests/InteractiveCLITests.swift`

- [ ] **Step 1: Replace placeholder test with model discovery tests**

Use temporary directories so no real model download is required:

```swift
func testDiscoverModelsReturnsSortedDirectoriesOnly() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let models = root.appendingPathComponent(".models", isDirectory: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: models.appendingPathComponent("z-model", isDirectory: true), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: models.appendingPathComponent("a-model", isDirectory: true), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: models.appendingPathComponent("README.md").path, contents: Data())

    let discovered = try InteractiveCLI.discoverModels(packageRoot: root)

    XCTAssertEqual(discovered.map(\.name), ["a-model", "z-model"])
    XCTAssertEqual(discovered.map { $0.url.lastPathComponent }, ["a-model", "z-model"])
}

func testDiscoverModelsReturnsEmptyArrayWhenModelsDirIsMissing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let discovered = try InteractiveCLI.discoverModels(packageRoot: root)

    XCTAssertEqual(discovered, [])
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter InteractiveCLITests
```

Expected: FAIL because `DownloadedModel` and `discoverModels` do not exist.

- [ ] **Step 3: Implement model discovery**

Replace `InteractiveCLI.swift` with:

```swift
import Foundation

struct DownloadedModel: Equatable {
    let name: String
    let url: URL
}

enum InteractiveCLI {
    static func discoverModels(packageRoot: URL) throws -> [DownloadedModel] {
        let modelsURL = repositoryRoot(packageRoot: packageRoot)
            .appendingPathComponent(".models", isDirectory: true)
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: modelsURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return []
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: modelsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        return children.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                return nil
            }
            return DownloadedModel(name: url.lastPathComponent, url: url)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func repositoryRoot(packageRoot: URL) -> URL {
        let ancestors = sequence(first: packageRoot) { url in
            let parent = url.deletingLastPathComponent()
            return parent.path == url.path ? nil : parent
        }

        return ancestors.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path)
        }) ?? packageRoot
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
swift test --filter InteractiveCLITests
```

Expected: PASS.

## Task 3: Add Prompt Parsing Helpers

**Files:**
- Modify: `Sources/Qwen3TTSPoc/InteractiveCLI.swift`
- Modify: `Tests/Qwen3TTSPocTests/InteractiveCLITests.swift`

- [ ] **Step 1: Add tests for numbered choice and text validation**

Append:

```swift
func testChoiceIndexParsesOneBasedInput() throws {
    XCTAssertEqual(InteractiveCLI.choiceIndex(from: "1", optionCount: 3), 0)
    XCTAssertEqual(InteractiveCLI.choiceIndex(from: "3", optionCount: 3), 2)
}

func testChoiceIndexRejectsOutOfRangeAndInvalidInput() throws {
    XCTAssertNil(InteractiveCLI.choiceIndex(from: "0", optionCount: 3))
    XCTAssertNil(InteractiveCLI.choiceIndex(from: "4", optionCount: 3))
    XCTAssertNil(InteractiveCLI.choiceIndex(from: "Aiden", optionCount: 3))
    XCTAssertNil(InteractiveCLI.choiceIndex(from: "", optionCount: 3))
}

func testNormalizePromptTextTrimsWhitespaceAndRejectsEmptyInput() throws {
    XCTAssertEqual(InteractiveCLI.normalizedPromptText("  Hello world!  "), "Hello world!")
    XCTAssertNil(InteractiveCLI.normalizedPromptText("   "))
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter InteractiveCLITests
```

Expected: FAIL because `choiceIndex` and `normalizedPromptText` do not exist.

- [ ] **Step 3: Implement parsing helpers**

Add inside `InteractiveCLI`:

```swift
static func choiceIndex(from input: String, optionCount: Int) -> Int? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let number = Int(trimmed), (1...optionCount).contains(number) else {
        return nil
    }
    return number - 1
}

static func normalizedPromptText(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
swift test --filter InteractiveCLITests
```

Expected: PASS.

## Task 4: Add Generated WAV Path Helper And Gitignore

**Files:**
- Modify: `Sources/Qwen3TTSPoc/InteractiveCLI.swift`
- Modify: `Tests/Qwen3TTSPocTests/InteractiveCLITests.swift`
- Modify: `.gitignore`

- [ ] **Step 1: Add tests for `.generated` output path**

Append:

```swift
func testGeneratedWavURLUsesGeneratedDirectoryAndWavExtension() throws {
    let root = URL(fileURLWithPath: "/tmp/qwen3-poc", isDirectory: true)
    let date = Date(timeIntervalSince1970: 1_788_544_800)

    let url = InteractiveCLI.generatedWavURL(packageRoot: root, date: date)

    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".generated")
    XCTAssertEqual(url.pathExtension, "wav")
    XCTAssertTrue(url.lastPathComponent.hasPrefix("qwen3tts-"))
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter InteractiveCLITests
```

Expected: FAIL because `generatedWavURL` does not exist.

- [ ] **Step 3: Implement generated path helper**

Add inside `InteractiveCLI`:

```swift
static func generatedWavURL(packageRoot: URL, date: Date = Date()) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"

    return packageRoot
        .appendingPathComponent(".generated", isDirectory: true)
        .appendingPathComponent("qwen3tts-\(formatter.string(from: date)).wav")
}
```

- [ ] **Step 4: Add `.generated/` to gitignore**

Change `hamptus-mlx-swift-qwen3-tts/swift-only-poc/.gitignore` to include:

```gitignore
.generated/
```

- [ ] **Step 5: Run tests to verify pass**

Run:

```bash
swift test --filter InteractiveCLITests
```

Expected: PASS.

## Task 5: Wire Interactive Default Flow

**Files:**
- Modify: `Sources/Qwen3TTSPoc/main.swift`
- Modify: `Sources/Qwen3TTSPoc/InteractiveCLI.swift`

- [ ] **Step 1: Add console prompt helpers**

Add to `InteractiveCLI`:

```swift
static func promptForChoice<T>(
    title: String,
    options: [T],
    label: (T) -> String
) -> T? {
    guard !options.isEmpty else {
        return nil
    }

    print(title)
    for (index, option) in options.enumerated() {
        print("  \(index + 1). \(label(option))")
    }

    while true {
        print("> ", terminator: "")
        guard let line = readLine() else {
            return nil
        }
        if let index = choiceIndex(from: line, optionCount: options.count) {
            return options[index]
        }
        print("Enter a number from 1 to \(options.count).")
    }
}

static func promptForText(title: String) -> String? {
    while true {
        print(title)
        print("> ", terminator: "")
        guard let line = readLine() else {
            return nil
        }
        if let text = normalizedPromptText(line) {
            return text
        }
        print("Enter at least one character.")
    }
}
```

- [ ] **Step 2: Replace default hardcoded model/text path in `main.swift`**

Create a new default method:

```swift
private static func runInteractiveGeneration(rootURL: URL) throws {
    let models = try InteractiveCLI.discoverModels(packageRoot: rootURL)
    guard let model = InteractiveCLI.promptForChoice(
        title: "Which model?",
        options: models,
        label: { $0.name }
    ) else {
        let repositoryRoot = InteractiveCLI.repositoryRoot(packageRoot: rootURL)
        throw PocError.missingModelsDirectory(repositoryRoot.appendingPathComponent(".models", isDirectory: true))
    }

    let loadTimer = Stopwatch()
    print("Loading model: \(model.url.path)")
    let pipeline = try Qwen3TTSPipeline(modelPath: model.url)
    print("Model loaded in \(formatSeconds(loadTimer.elapsed))")

    let speakers = pipeline.availableSpeakers
    guard let speaker = InteractiveCLI.promptForChoice(
        title: "Which voice?",
        options: speakers,
        label: { $0 }
    ) else {
        throw PocError.noSpeakers(model.name)
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
```

- [ ] **Step 3: Add explicit error cases**

Extend `PocError`:

```swift
case missingModelsDirectory(URL)
case noSpeakers(String)
case cancelledInput
```

Add descriptions:

```swift
case let .missingModelsDirectory(url):
    return """
    No models found in:
      \(url.path)

    Download a model first:
      scripts/download-model.sh
    """
case let .noSpeakers(modelName):
    return "Model \(modelName) did not report any built-in speakers."
case .cancelledInput:
    return "Input cancelled."
```

- [ ] **Step 4: Route default invocation to interactive mode**

In `main()`, keep `--help` and `--stream`. For no arguments, call:

```swift
try runInteractiveGeneration(rootURL: rootURL)
```

For `--stream`, keep the existing smoke-test code path using the downloaded 1.7B model if desired.

- [ ] **Step 5: Build**

Run:

```bash
swift build
```

Expected: build succeeds.

## Task 6: Manual Interactive Verification

**Files:**
- Runtime output only: `.generated/*.wav`

- [ ] **Step 1: Run the interactive CLI**

Run:

```bash
cd hamptus-mlx-swift-qwen3-tts/swift-only-poc
swift run Qwen3TTSPoc
```

Expected first prompt:

```text
Which model?
  1. Qwen3-TTS-12Hz-1.7B-Base-8bit
>
```

- [ ] **Step 2: Select model and verify voices prompt**

Type:

```text
1
```

Expected: model loads, then prints a numbered list from `pipeline.availableSpeakers`, including voices such as `Aiden`, `Dylan`, `Eric`, `Ono Anna`, `Ryan`, `Serena`, `Sohee`, `Uncle Fu`, and `Vivian` if the selected model exposes them.

- [ ] **Step 3: Select voice and enter text**

Type the number for `Aiden`, then:

```text
Hello world!
```

Expected: CLI generates a WAV and prints:

```text
Generated WAV: /Users/tleyden/Development/tauri2-qwen3-tts/hamptus-mlx-swift-qwen3-tts/swift-only-poc/.generated/qwen3tts-<timestamp>.wav
```

- [ ] **Step 4: Verify file exists and is ignored**

Run:

```bash
ls -lh .generated/*.wav
git status --short --untracked-files=all
```

Expected: at least one WAV exists; `.generated/` files do not appear in git status.

- [ ] **Step 5: Optional playback**

Run:

```bash
afplay .generated/*.wav
```

Expected: audible generated speech.

## Self-Review

- Spec coverage: The plan covers model selection from repo-root `.models`, voice selection from model-supported speakers, text input, WAV generation, `.generated/` creation, and `.generated/` gitignore.
- Placeholder scan: No implementation step depends on TBD behavior; all helper signatures and expected commands are explicit.
- Type consistency: `DownloadedModel`, `InteractiveCLI.discoverModels`, `choiceIndex`, `normalizedPromptText`, and `generatedWavURL` are introduced before use in `main.swift`.
