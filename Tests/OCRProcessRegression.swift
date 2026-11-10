// Standalone process lifecycle tests. See CLAUDE.md for compile/run commands.
import CoreGraphics
import CoreText
import Darwin
import Foundation

@main
struct OCRProcessRegression {
    static func makeImage() -> CGImage {
        let context = CGContext(data: nil, width: 640, height: 240, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 240))
        for (index, text) in ["日本語の文字認識", "timeSlice OCR test 123"].enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HiraginoSans-W3" as CFString, 32, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]))
            context.textPosition = CGPoint(x: 25, y: 150 - index * 70)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }

    static func assertClean(_ root: URL) throws {
        let directories = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("timeSlice-OCR-") }
        precondition(directories.isEmpty, "Temporary images were not cleaned up")
    }

    static func assertExited(_ pid: Int32) {
        precondition(kill(pid, 0) == -1 && errno == ESRCH, "Child is still alive")
    }

    static func metadata(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static func main() async throws {
        // Run from a temporary .app bundle to verify the production Bundle.main lookup.
        if CommandLine.arguments.dropFirst().first == "--bundled" {
            let manager = OCRManager()
            let text = try await manager.recognizeText(from: makeImage())
            precondition(text.contains("日本語の文字認識") && text.contains("timeSlice OCR test 123"))
            let blank = CGContext(data: nil, width: 640, height: 240, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            blank.setFillColor(CGColor(gray: 1, alpha: 1))
            blank.fill(CGRect(x: 0, y: 0, width: 640, height: 240))
            let empty = try await manager.recognizeText(from: blank.makeImage()!)
            precondition(empty.isEmpty)
            print("PASS: production bundle lookup, actual Release helper Japanese/English OCR and valid blank result")
            return
        }
        guard CommandLine.arguments.count >= 2 else { fatalError("Pass the fixture executable path") }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OCR tests 日本語 \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = makeImage()
        @Sendable func manager(_ mode: String, timeout: TimeInterval = 5) -> OCRManager {
            OCRManager(helperExecutableURL: executable, timeoutSeconds: timeout, temporaryDirectoryURL: root,
                       recognitionLanguages: [mode], usesLanguageCorrection: false)
        }

        // Sequential and overlapping invocations must all use distinct, already exited children.
        let first = try metadata(await manager("success").recognizeText(from: image))
        let second = try metadata(await manager("success").recognizeText(from: image))
        precondition(first["pid"] as! Int != second["pid"] as! Int)
        precondition(first["correction"] as! String == "false")
        precondition(first["text"] as! String == "日本語\nOCR test")
        precondition(!FileManager.default.fileExists(atPath: first["imagePath"] as! String))
        assertExited(Int32(first["pid"] as! Int))
        assertExited(Int32(second["pid"] as! Int))
        async let concurrentA = manager("success").recognizeText(from: image)
        async let concurrentB = manager("success").recognizeText(from: image)
        let (a, b) = try await (concurrentA, concurrentB)
        let concurrentPIDa = try metadata(a)["pid"] as! Int
        let concurrentPIDb = try metadata(b)["pid"] as! Int
        precondition(concurrentPIDa != concurrentPIDb)
        try assertClean(root)
        print("PASS: fresh children, concurrent calls, Japanese/space paths, options, stdout/stderr separation, cleanup")

        let empty = try await manager("empty").recognizeText(from: image)
        precondition(empty.isEmpty)
        do {
            _ = try await manager("failure").recognizeText(from: image)
            fatalError("Expected helper failure")
        } catch let error as OCRManagerError {
            guard case let .executionFailed(status, message) = error else { throw error }
            precondition(status == 17 && message == "injected failure")
        }
        do {
            _ = try await manager("signal").recognizeText(from: image)
            fatalError("Expected signal failure")
        } catch let error as OCRManagerError {
            guard case .executionFailed = error else { throw error }
        }
        let large = try await manager("large").recognizeText(from: image)
        precondition(large.utf8.count == 192 * 1024)
        for mode in ["invalid", "overflow"] {
            do {
                _ = try await manager(mode).recognizeText(from: image)
                fatalError("Expected invalid/oversized output")
            } catch let error as OCRManagerError {
                switch error {
                case .invalidOutput where mode == "invalid": break
                case .outputTooLarge where mode == "overflow": break
                default: throw error
                }
            }
        }
        try assertClean(root)
        print("PASS: empty text, partial output discarded on failure, signal exit, large pipes, UTF-8/output limits")

        let start = Date()
        do {
            _ = try await manager("hang", timeout: 0.2).recognizeText(from: image)
            fatalError("Expected timeout")
        } catch let error as OCRManagerError {
            guard case .timedOut = error else { throw error }
        }
        precondition(Date().timeIntervalSince(start) < 3)
        try assertClean(root)

        // Wait for a marker from the actual child before canceling, avoiding a launch race in the test.
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        let task = Task { try await manager("hang").recognizeText(from: image) }
        var marker: URL?
        for _ in 0..<250 {
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
            if let name = names.subtracting(before).first(where: { $0.hasPrefix("started-") }) {
                marker = root.appendingPathComponent(name)
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(marker != nil, "Child did not launch")
        task.cancel()
        do {
            _ = try await task.value
            fatalError("Expected cancellation")
        } catch is CancellationError {}
        let cancelled = try JSONSerialization.jsonObject(with: Data(contentsOf: marker!)) as! [String: Any]
        assertExited(Int32(cancelled["pid"] as! Int))
        try assertClean(root)
        print("PASS: timeout and cancellation kill/reap child before removing its image")

        // Missing and non-executable-format helpers must fail without leaving images behind.
        let missing = OCRManager(helperExecutableURL: root.appendingPathComponent("missing"), timeoutSeconds: 1, temporaryDirectoryURL: root)
        do {
            _ = try await missing.recognizeText(from: image)
            fatalError("Expected missing helper")
        } catch let error as OCRManagerError {
            guard case .helperUnavailable = error else { throw error }
        }
        let invalidExecutable = root.appendingPathComponent("invalid executable")
        try Data("invalid executable".utf8).write(to: invalidExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: invalidExecutable.path)
        do {
            _ = try await OCRManager(helperExecutableURL: invalidExecutable, timeoutSeconds: 1, temporaryDirectoryURL: root).recognizeText(from: image)
            fatalError("Expected launch failure")
        } catch let error as OCRManagerError {
            guard case .launchFailed = error else { throw error }
        }
        try assertClean(root)
        print("PASS: missing helper and launch failure cleanup")

        if CommandLine.arguments.count > 2 {
            let helper = URL(fileURLWithPath: CommandLine.arguments[2])
            for iteration in 1...2 {
                let started = Date()
                let text = try await OCRManager(helperExecutableURL: helper, timeoutSeconds: 45, temporaryDirectoryURL: root).recognizeText(from: image)
                precondition(text.contains("日本語の文字認識") && text.contains("timeSlice OCR test 123"), "Japanese/English OCR mismatch")
                try assertClean(root)
                print("PASS: actual helper call \(iteration), Japanese/English match, elapsed=\(Date().timeIntervalSince(started))s")
            }
        }
    }
}
