import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit based implementation for foreground window capture.
public final class ScreenCaptureManager: ScreenCapturing, @unchecked Sendable {
    private let bundleIdentifierToSkip: String?

    public init(bundleIdentifierToSkip: String? = Bundle.main.bundleIdentifier) {
        self.bundleIdentifierToSkip = bundleIdentifierToSkip
    }

    public func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func captureFrontWindow() async throws -> CapturedWindow? {
        guard hasScreenCapturePermission() else {
            throw ScreenCaptureError.permissionDenied
        }

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            throw ScreenCaptureError.frontmostApplicationNotFound
        }
        let frontmostApplicationName = frontmostApplication.localizedName ?? "Unknown"

        if let bundleIdentifierToSkip, frontmostApplication.bundleIdentifier == bundleIdentifierToSkip {
            return nil
        }

        let shareableContent = try await SCShareableContent.current
        let targetWindows = shareableContent.windows.filter { window in
            guard window.isOnScreen else {
                return false
            }

            guard let owningApplication = window.owningApplication else {
                return false
            }
            guard owningApplication.bundleIdentifier == frontmostApplication.bundleIdentifier else {
                return false
            }

            return window.frame.width > 1 && window.frame.height > 1
        }

        guard let targetWindow = targetWindows.max(by: { calculateWindowArea($0.frame) < calculateWindowArea($1.frame) }) else {
            throw ScreenCaptureError.targetWindowNotFound(applicationName: frontmostApplicationName)
        }

        let contentFilter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = Int(targetWindow.frame.width.rounded())
        streamConfiguration.height = Int(targetWindow.frame.height.rounded())
        streamConfiguration.showsCursor = false

        let capturedImage = try await SCScreenshotManager.captureImage(
            contentFilter: contentFilter,
            configuration: streamConfiguration
        )

        return CapturedWindow(
            image: capturedImage,
            applicationName: frontmostApplicationName,
            capturedAt: Date()
        )
    }

    private func calculateWindowArea(_ frame: CGRect) -> CGFloat {
        frame.width * frame.height
    }
}
