import Foundation
import Darwin

/// Executes external CLI commands used for report generation.
public protocol CLIExecutable: Sendable {
    func execute(
        command: String,
        arguments: [String],
        input: String?,
        timeoutSeconds: TimeInterval,
        currentDirectoryURL: URL?
    ) async throws -> String
}

public enum CLIExecutorError: LocalizedError {
    case emptyCommand
    case failedToLaunch(String)
    case stdinWriteFailed(command: String, reason: String)
    case executionFailed(command: String, exitCode: Int32, output: String)
    case timedOut(command: String, timeoutSeconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "CLI command is empty."
        case let .failedToLaunch(command):
            return "Failed to launch CLI command: \(command)"
        case let .stdinWriteFailed(command, reason):
            return "Failed to write stdin for command (\(command)): \(reason)"
        case let .executionFailed(command, exitCode, output):
            return "CLI command failed (\(command), exit=\(exitCode)): \(output)"
        case let .timedOut(command, timeoutSeconds):
            return "CLI command timed out (\(command), timeout=\(Int(timeoutSeconds))s)"
        }
    }
}

/// `Process` based CLI executor with stdin/stdout piping and timeout handling.
public final class CLIExecutor: CLIExecutable, @unchecked Sendable {
    private static let sigpipeIgnored: Void = {
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    public init() {}

    /// Executes CLI command with optional stdin text and returns stdout text.
    public func execute(
        command: String,
        arguments: [String],
        input: String?,
        timeoutSeconds: TimeInterval = 300,
        currentDirectoryURL: URL? = nil
    ) async throws -> String {
        // Prevent app termination when child process closes stdin early.
        _ = Self.sigpipeIgnored

        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCommand.isEmpty == false else {
            throw CLIExecutorError.emptyCommand
        }
        let preparedExecutionInput = prepareExecutionInput(arguments: arguments, input: input)

        return try await withCheckedThrowingContinuation { continuation in
            let standardOutputPipe = Pipe()
            let standardErrorPipe = Pipe()
            let standardInputPipe = Pipe()
            let process = buildProcess(
                command: normalizedCommand,
                arguments: preparedExecutionInput.arguments,
                currentDirectoryURL: currentDirectoryURL,
                standardOutputPipe: standardOutputPipe,
                standardErrorPipe: standardErrorPipe,
                standardInputPipe: standardInputPipe
            )

            // Accumulate stdout/stderr asynchronously to avoid blocking on
            // readDataToEndOfFile() when child processes inherit pipe fds.
            let outputAccumulator = PipeAccumulator()
            let errorAccumulator = PipeAccumulator()
            standardOutputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    standardOutputPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    outputAccumulator.append(data)
                }
            }
            standardErrorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    standardErrorPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    errorAccumulator.append(data)
                }
            }

            let continuationGate = ContinuationGate(continuation: continuation)
            process.terminationHandler = { terminatedProcess in
                // Stop readability handlers and drain remaining buffered data.
                standardOutputPipe.fileHandleForReading.readabilityHandler = nil
                standardErrorPipe.fileHandleForReading.readabilityHandler = nil
                let remainingOutput = standardOutputPipe.fileHandleForReading.availableData
                let remainingError = standardErrorPipe.fileHandleForReading.availableData
                if remainingOutput.isEmpty == false { outputAccumulator.append(remainingOutput) }
                if remainingError.isEmpty == false { errorAccumulator.append(remainingError) }

                let executionResult = Self.resolveExecutionResult(
                    process: terminatedProcess,
                    command: normalizedCommand,
                    standardOutputText: outputAccumulator.text,
                    standardErrorText: errorAccumulator.text
                )
                continuationGate.finish(with: executionResult)
            }

            do {
                try process.run()
            } catch {
                continuationGate.finish(with: .failure(CLIExecutorError.failedToLaunch(normalizedCommand)))
                return
            }

            writeInput(
                preparedExecutionInput.stdinInput,
                command: normalizedCommand,
                into: standardInputPipe,
                continuationGate: continuationGate
            )
            startTimeoutTask(
                command: normalizedCommand,
                timeoutSeconds: timeoutSeconds,
                process: process,
                standardOutputPipe: standardOutputPipe,
                standardErrorPipe: standardErrorPipe,
                continuationGate: continuationGate
            )
        }
    }

    private func prepareExecutionInput(arguments: [String], input: String?) -> PreparedExecutionInput {
        guard let input, input.isEmpty == false else {
            return PreparedExecutionInput(arguments: arguments, stdinInput: input)
        }

        // Gemini CLI requires a value for -p/--prompt. If the flag is provided
        // without a following value, reuse input as the prompt argument.
        for argumentIndex in arguments.indices {
            let argument = arguments[argumentIndex]
            if argument == "--prompt=" || argument == "-p=" || argument.hasPrefix("--prompt=") || argument.hasPrefix("-p=") {
                return PreparedExecutionInput(arguments: arguments, stdinInput: input)
            }

            guard argument == "-p" || argument == "--prompt" else {
                continue
            }

            let hasPromptValue = arguments.indices.contains(argumentIndex + 1)
            guard hasPromptValue == false else {
                return PreparedExecutionInput(arguments: arguments, stdinInput: input)
            }

            var preparedArguments = arguments
            preparedArguments.append(input)
            return PreparedExecutionInput(arguments: preparedArguments, stdinInput: nil)
        }

        return PreparedExecutionInput(arguments: arguments, stdinInput: input)
    }

    private func buildProcess(
        command: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        standardOutputPipe: Pipe,
        standardErrorPipe: Pipe,
        standardInputPipe: Pipe
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = buildExecutionEnvironment()
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        process.standardInput = standardInputPipe
        return process
    }

    private func buildExecutionEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let configuredPath = environment["PATH"] ?? ""
        var pathComponents = configuredPath
            .split(separator: ":")
            .map(String.init)
            .filter { $0.isEmpty == false }

        let fallbackPaths = [
            "\(NSHomeDirectory())/.local/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin"
        ]

        for fallbackPath in fallbackPaths where pathComponents.contains(fallbackPath) == false {
            pathComponents.append(fallbackPath)
        }

        environment["PATH"] = pathComponents.joined(separator: ":")
        return environment
    }

    private func writeInput(
        _ input: String?,
        command: String,
        into standardInputPipe: Pipe,
        continuationGate: ContinuationGate
    ) {
        let inputHandle = standardInputPipe.fileHandleForWriting
        defer {
            inputHandle.closeFile()
        }

        guard let input else {
            return
        }

        guard let inputData = input.data(using: .utf8) else {
            return
        }

        do {
            try inputHandle.write(contentsOf: inputData)
        } catch let posixError as POSIXError where posixError.code == .EPIPE {
            // Child may close stdin immediately (e.g. command not found or fast failure).
            return
        } catch {
            continuationGate.finish(
                with: .failure(
                    CLIExecutorError.stdinWriteFailed(
                        command: command,
                        reason: error.localizedDescription
                    )
                )
            )
        }
    }

    private func startTimeoutTask(
        command: String,
        timeoutSeconds: TimeInterval,
        process: Process,
        standardOutputPipe: Pipe,
        standardErrorPipe: Pipe,
        continuationGate: ContinuationGate
    ) {
        Task {
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
            }

            guard continuationGate.isCompleted == false else {
                return
            }

            // Clean up pipe handlers to prevent resource leaks.
            standardOutputPipe.fileHandleForReading.readabilityHandler = nil
            standardErrorPipe.fileHandleForReading.readabilityHandler = nil

            if process.isRunning {
                process.terminate()
            }
            continuationGate.finish(
                with: .failure(CLIExecutorError.timedOut(command: command, timeoutSeconds: timeoutSeconds))
            )
        }
    }

    private static func resolveExecutionResult(
        process: Process,
        command: String,
        standardOutputText: String,
        standardErrorText: String
    ) -> Result<String, Error> {
        let mergedOutput = [standardOutputText, standardErrorText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")

        guard process.terminationStatus == 0 else {
            return .failure(
                CLIExecutorError.executionFailed(
                    command: command,
                    exitCode: process.terminationStatus,
                    output: mergedOutput
                )
            )
        }

        return .success(standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private struct PreparedExecutionInput {
    let arguments: [String]
    let stdinInput: String?
}

private final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class ContinuationGate {
    private let lock = NSLock()
    private var hasCompleted = false
    private var continuation: CheckedContinuation<String, Error>?

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasCompleted
    }

    func finish(with result: Result<String, Error>) {
        lock.lock()
        guard hasCompleted == false, let continuation else {
            lock.unlock()
            return
        }
        hasCompleted = true
        self.continuation = nil
        lock.unlock()

        switch result {
        case let .success(output):
            continuation.resume(returning: output)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
