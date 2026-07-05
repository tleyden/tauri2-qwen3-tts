import Foundation

struct GenerationRequest: Equatable {
    let modelName: String
    let speaker: String
    let textFilePath: String
    let outputPath: String

    func loadText(relativeTo rootURL: URL) throws -> String {
        let url = resolvedURL(path: textFilePath, relativeTo: rootURL)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func outputURL(relativeTo rootURL: URL) -> URL {
        resolvedURL(path: outputPath, relativeTo: rootURL)
    }

    static func parse(arguments: [String]) throws -> GenerationRequest {
        var values: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw GenerationRequestError.unexpectedArgument(argument)
            }

            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw GenerationRequestError.missingValue(argument)
            }

            values[argument] = arguments[valueIndex]
            index += 2
        }

        return GenerationRequest(
            modelName: try requiredValue("--model", values: values),
            speaker: try requiredValue("--speaker", values: values),
            textFilePath: try requiredValue("--text-file", values: values),
            outputPath: try requiredValue("--output", values: values)
        )
    }

    private static func requiredValue(_ name: String, values: [String: String]) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw GenerationRequestError.missingValue(name)
        }
        return value
    }

    private func resolvedURL(path: String, relativeTo rootURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return rootURL.appendingPathComponent(path)
    }
}

enum GenerationRequestError: Error, Equatable, CustomStringConvertible {
    case missingValue(String)
    case unexpectedArgument(String)

    var description: String {
        switch self {
        case let .missingValue(argument):
            return "Missing value for \(argument)."
        case let .unexpectedArgument(argument):
            return "Unexpected argument: \(argument)"
        }
    }
}
