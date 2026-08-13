import Darwin
import Foundation
import OllamaLocalCore

@main
struct OllamaLocalCommand {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIError {
            writeError("error: \(error.message)\n")
            Darwin.exit(error.exitCode)
        } catch is CancellationError {
            writeError("error: cancelled\n")
            Darwin.exit(130)
        } catch {
            // Do not expose raw transport bodies or model-controlled error text.
            writeError("error: local request failed safely; run 'ollama-local status'\n")
            Darwin.exit(4)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard arguments.count == 1 else { throw CLIError.usage }
        let client = OllamaLocalClient()

        switch arguments[0] {
        case "status":
            let status = try await client.status()
            writeOutput("ready: Ollama \(status.version) at 127.0.0.1:11434\n")

        case "verify":
            let result = try await client.verify()
            writeOutput("verified: \(result.model), events=\(result.eventCount), bytes=\(result.responseBytes)\n")

        case "ask":
            let data = try readStandardInput(maxBytes: 512 * 1_024)
            guard let prompt = String(data: data, encoding: .utf8) else {
                throw CLIError.promptMustBeUTF8
            }
            let response = try await client.ask(prompt: prompt)
            writeOutput(response)
            if !response.hasSuffix("\n") { writeOutput("\n") }

        case "help", "--help", "-h":
            writeOutput(usage)

        default:
            throw CLIError.usage
        }
    }

    private static func readStandardInput(maxBytes: Int) throws -> Data {
        var result = Data()
        while true {
            let remainingProbe = maxBytes + 1 - result.count
            guard remainingProbe > 0 else { throw CLIError.inputOversized }
            guard let chunk = try FileHandle.standardInput.read(
                upToCount: min(64 * 1_024, remainingProbe)
            ), !chunk.isEmpty else { break }
            result.append(chunk)
            guard result.count <= maxBytes else { throw CLIError.inputOversized }
        }
        guard !result.isEmpty else { throw CLIError.emptyPrompt }
        return result
    }

    private static func writeOutput(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private static func writeError(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }

    private static let usage = """
    Usage:
      ollama-local status   Verify the fixed loopback service
      ollama-local verify   Validate bounded NDJSON streaming with gemma3:4b
      ollama-local ask      Read a UTF-8 prompt from standard input
      ollama-local help     Show this help

    Example:
      printf '%s\\n' 'Explain actors in Swift.' | ollama-local ask

    Fixed boundary: http://127.0.0.1:11434, model gemma3:4b.
    No cloud fallback, arbitrary URL, shell execution, or filesystem authority.
    """

    private enum CLIError: Error {
        case usage
        case inputOversized
        case emptyPrompt
        case promptMustBeUTF8

        var message: String {
            switch self {
            case .usage: "invalid command; run 'ollama-local help'"
            case .inputOversized: "prompt exceeds the 512 KiB limit"
            case .emptyPrompt: "prompt cannot be empty"
            case .promptMustBeUTF8: "prompt must be valid UTF-8"
            }
        }

        var exitCode: Int32 { self == .usage ? 64 : 65 }
    }
}
