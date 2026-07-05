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

    static func generatedWavURL(packageRoot: URL, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        return packageRoot
            .appendingPathComponent(".generated", isDirectory: true)
            .appendingPathComponent("qwen3tts-\(formatter.string(from: date)).wav")
    }

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
}
