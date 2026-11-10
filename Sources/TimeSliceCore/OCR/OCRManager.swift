import CoreGraphics
import Darwin
import Foundation

/// Runs each recognition in a new bundled helper process, which exits after one image.
public final class OCRManager: TextRecognizing, @unchecked Sendable {
    public let recognitionLanguages: [String]
    public let usesLanguageCorrection: Bool
    private let helperExecutableURL: URL
    private let timeoutSeconds: TimeInterval
    private let temporaryDirectoryURL: URL

    public init(
        recognitionLanguages: [String] = ["ja-JP", "en-US"],
        usesLanguageCorrection: Bool = true
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.helperExecutableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/timeSliceOCR")
        self.timeoutSeconds = 45
        self.temporaryDirectoryURL = FileManager.default.temporaryDirectory
    }

    // Explicit paths/deadline allow isolated process tests without launching the app.
    init(
        helperExecutableURL: URL,
        timeoutSeconds: TimeInterval,
        temporaryDirectoryURL: URL,
        recognitionLanguages: [String] = ["ja-JP", "en-US"],
        usesLanguageCorrection: Bool = true
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.helperExecutableURL = helperExecutableURL
        self.timeoutSeconds = timeoutSeconds
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    public func recognizeText(from image: CGImage) async throws -> String {
        try Task.checkCancellation()
        let execution = OCRProcessExecution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    continuation.resume(with: Result {
                        try recognizeText(from: image, execution: execution)
                    })
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }

    private func recognizeText(from image: CGImage, execution: OCRProcessExecution) throws -> String {
        try execution.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: helperExecutableURL.path) else {
            throw OCRManagerError.helperUnavailable
        }
        let directory = temporaryDirectoryURL.appendingPathComponent("timeSlice-OCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("input.png")
        guard let imageData = CaptureImageEncoder.encodeImage(image, format: .png) else {
            throw OCRManagerError.imageEncodingFailed
        }
        try imageData.write(to: imageURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
        return try execution.run(
            executableURL: helperExecutableURL,
            arguments: [imageURL.path, "--languages", recognitionLanguages.joined(separator: ","),
                        "--language-correction", usesLanguageCorrection ? "true" : "false"],
            timeoutSeconds: timeoutSeconds
        )
    }
}

enum OCRManagerError: LocalizedError, CustomStringConvertible {
    case helperUnavailable
    case imageEncodingFailed
    case launchFailed
    case executionFailed(Int32, String)
    case timedOut(TimeInterval)
    case invalidOutput
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .helperUnavailable: NSLocalizedString("error.ocr.helper_unavailable", comment: "")
        case .imageEncodingFailed: NSLocalizedString("error.ocr.image_encoding_failed", comment: "")
        case .launchFailed: NSLocalizedString("error.ocr.launch_failed", comment: "")
        case let .executionFailed(status, diagnostic):
            String(format: NSLocalizedString("error.ocr.execution_failed", comment: ""), status, diagnostic)
        case let .timedOut(seconds):
            String(format: NSLocalizedString("error.ocr.timed_out", comment: ""), Int(seconds))
        case .invalidOutput: NSLocalizedString("error.ocr.invalid_output", comment: "")
        case .outputTooLarge: NSLocalizedString("error.ocr.output_too_large", comment: "")
        }
    }

    var description: String { errorDescription ?? "OCR failed" }
}

/// One call owns one child. The lock coordinates cancellation with process launch/exit.
private final class OCRProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled { throw CancellationError() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        killChildIfRunning()
    }

    private func killChildIfRunning() {
        if let process, process.isRunning {
            // SIGTERM can leave a stuck inference alive; this disposable child owns no persistent data.
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func run(executableURL: URL, arguments: [String], timeoutSeconds: TimeInterval) throws -> String {
        let child = Process()
        child.executableURL = executableURL
        child.arguments = arguments
        child.qualityOfService = .utility
        child.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        child.standardOutput = outputPipe
        child.standardError = errorPipe
        let exited = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in exited.signal() }

        // Never launch a child after cancellation has already been observed.
        lock.lock()
        if isCancelled {
            lock.unlock()
            throw CancellationError()
        }
        process = child
        do {
            try child.run()
        } catch {
            process = nil
            lock.unlock()
            throw OCRManagerError.launchFailed
        }
        lock.unlock()
        defer {
            lock.lock()
            process = nil
            lock.unlock()
            child.terminationHandler = nil
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }

        // Drain both streams concurrently so neither can block the child on a full pipe.
        let output = OCRPipeReader(limit: 4 * 1024 * 1024)
        let diagnostic = OCRPipeReader(limit: 64 * 1024)
        let readers = DispatchGroup()
        for (pipe, reader) in [(outputPipe, output), (errorPipe, diagnostic)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                reader.read(from: pipe.fileHandleForReading)
                readers.leave()
            }
        }
        let timedOut = exited.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            lock.lock()
            killChildIfRunning()
            lock.unlock()
        }
        // The helper never spawns descendants. Exit/kill closes its pipes before cleanup.
        child.waitUntilExit()
        readers.wait()
        try checkCancellation()
        if timedOut { throw OCRManagerError.timedOut(timeoutSeconds) }
        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
            let message = String(decoding: diagnostic.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw OCRManagerError.executionFailed(child.terminationStatus, message)
        }
        guard !output.exceededLimit else { throw OCRManagerError.outputTooLarge }
        guard !output.failed, let text = String(data: output.data, encoding: .utf8) else {
            throw OCRManagerError.invalidOutput
        }
        return text
    }
}

/// Written on one reader queue, accessed only after its DispatchGroup completes.
private final class OCRPipeReader: @unchecked Sendable {
    private let limit: Int
    private(set) var data = Data()
    private(set) var exceededLimit = false
    private(set) var failed = false

    init(limit: Int) { self.limit = limit }

    func read(from handle: FileHandle) {
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                let remaining = limit - data.count
                data.append(chunk.prefix(remaining))
                if chunk.count > remaining { exceededLimit = true }
            }
        } catch {
            failed = true
        }
    }
}
