import Foundation

/// Runs command-line tools off the main thread. Used to read data (system_profiler, pmset -g)
/// and to run privileged changes (osascript "with administrator privileges").
enum Shell {
    struct ShellError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe

                do {
                    try task.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                task.waitUntilExit()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""

                if task.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8)
                        .flatMap { $0.isEmpty ? nil : $0 } ?? "Command exited with status \(task.terminationStatus)"
                    continuation.resume(throwing: ShellError(message: errText.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }

                continuation.resume(returning: output)
            }
        }
    }
}
