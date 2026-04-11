import Foundation

enum ShellError: LocalizedError {
    case failed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .failed(let code, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Command exited with status \(code)."
                : "Command failed (\(code)): \(trimmed)"
        }
    }
}

enum ShellRunner {
    nonisolated static func run(_ path: String, args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    cont.resume(returning: outData)
                } else {
                    let message = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: ShellError.failed(
                        code: process.terminationStatus,
                        message: message
                    ))
                }
            }
        }
    }

    /// Runs a shell command via `osascript` with administrator privileges.
    /// macOS prompts the user for their password once per session.
    nonisolated static func runPrivileged(_ command: String) async throws {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        _ = try await run("/usr/bin/osascript", args: ["-e", script])
    }
}
