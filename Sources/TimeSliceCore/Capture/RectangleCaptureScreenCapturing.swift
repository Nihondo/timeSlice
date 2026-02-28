import CoreGraphics
import Foundation
import ImageIO

/// ScreenCapturing implementation that uses `screencapture -i` for interactive rectangle selection.
/// Returns nil when the user cancels (Esc key), which CaptureScheduler maps to .skipped(.noWindow).
public final class RectangleCaptureScreenCapturing: ScreenCapturing, @unchecked Sendable {
    private let applicationName: String

    public init(applicationName: String = "Rectangle Capture") {
        self.applicationName = applicationName
    }

    public func captureFrontWindow() async throws -> CapturedWindow? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeslice_rect_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let terminationStatus: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i: interactive rectangle selection
            // -t png: PNG output format
            // -x: suppress shutter sound
            process.arguments = ["-i", "-t", "png", "-x", tempURL.path]
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: 1)
            }
        }

        // User pressed Esc to cancel, or an error occurred — no file is written in this case.
        guard terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempURL.path),
              let imageData = try? Data(contentsOf: tempURL),
              let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            return nil
        }

        return CapturedWindow(
            image: cgImage,
            applicationName: applicationName,
            windowTitle: nil,
            capturedAt: Date()
        )
    }
}
