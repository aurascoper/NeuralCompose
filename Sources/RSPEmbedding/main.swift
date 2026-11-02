import BCIClassifier
import BCICore
import Darwin
import Foundation

private struct Input: Decodable {
    let texts: [String]
}

private struct EncoderProvenance: Encodable {
    let id: String
    let version: String
    let dimension: Int
    let pooling: String
}

private struct Output: Encodable {
    let schemaVersion = "rsp-embedding-v0"
    let encoder: EncoderProvenance
    let embeddings: [[Float]]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case encoder
        case embeddings
    }
}

@main
private struct RSPEmbedding {
    static func main() async {
        do {
            let options = try parse(arguments: Array(CommandLine.arguments.dropFirst()))
            let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: options.input))
            let embedder = try CoreMLSentenceEmbedder(modelDirectory: options.modelDirectory)
            let embeddings = try await embedder.encode(input.texts)
            guard embeddings.count == input.texts.count else {
                throw CLIError.invalidOutput("embedding count differs from input text count")
            }
            let output = Output(
                encoder: EncoderProvenance(
                    id: embedder.modelID,
                    version: embedder.version,
                    dimension: embedder.dimension,
                    pooling: embedder.poolingDescription
                ),
                embeddings: embeddings.map(\.values)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(output).write(to: options.output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private struct Options {
        let modelDirectory: URL
        let input: URL
        let output: URL
    }

    private enum CLIError: LocalizedError {
        case usage
        case missingValue(String)
        case invalidOutput(String)

        var errorDescription: String? {
            switch self {
            case .usage:
                return "usage: RSPEmbedding --model-dir DIR --input texts.json --output embeddings.json"
            case let .missingValue(argument):
                return "missing value for \(argument)"
            case let .invalidOutput(message):
                return message
            }
        }
    }

    private static func parse(arguments: [String]) throws -> Options {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                throw CLIError.usage
            }
            guard argument.hasPrefix("--") else { throw CLIError.usage }
            guard index + 1 < arguments.count else { throw CLIError.missingValue(argument) }
            values[String(argument.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        guard let modelDirectory = values["model-dir"],
              let input = values["input"],
              let output = values["output"] else {
            throw CLIError.usage
        }
        return Options(
            modelDirectory: URL(fileURLWithPath: modelDirectory),
            input: URL(fileURLWithPath: input),
            output: URL(fileURLWithPath: output)
        )
    }
}
