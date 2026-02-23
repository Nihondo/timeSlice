import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit based implementation for foreground window capture.
public final class ScreenCaptureManager: ScreenCapturing, @unchecked Sendable {
    private let bundleIdentifierToSkip: String?
    private let browserURLResolver: (any BrowserURLResolving)?
    private let documentPathResolver: (any DocumentPathResolving)?

    public init(
        bundleIdentifierToSkip: String? = Bundle.main.bundleIdentifier,
        browserURLResolver: (any BrowserURLResolving)? = BrowserURLResolver(),
        documentPathResolver: (any DocumentPathResolving)? = AccessibilityDocumentPathResolver()
    ) {
        self.bundleIdentifierToSkip = bundleIdentifierToSkip
        self.browserURLResolver = browserURLResolver
        self.documentPathResolver = documentPathResolver
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

        guard let targetWindow = resolveCaptureTargetWindow(
            from: targetWindows,
            processIdentifier: frontmostApplication.processIdentifier
        ) else {
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

        let resolvedBrowserURL: String?
        if let bundleIdentifier = frontmostApplication.bundleIdentifier,
           let resolver = browserURLResolver {
            resolvedBrowserURL = await resolver.resolveBrowserURL(bundleIdentifier: bundleIdentifier)
        } else {
            resolvedBrowserURL = nil
        }
        let resolvedDocumentPath: String?
        if let resolver = documentPathResolver {
            resolvedDocumentPath = resolver.resolveDocumentPath(
                processIdentifier: frontmostApplication.processIdentifier
            )
        } else {
            resolvedDocumentPath = nil
        }

        return CapturedWindow(
            image: capturedImage,
            applicationName: frontmostApplicationName,
            windowTitle: targetWindow.title,
            capturedAt: Date(),
            browserURL: resolvedBrowserURL,
            documentPath: resolvedDocumentPath
        )
    }

    private func calculateWindowArea(_ frame: CGRect) -> CGFloat {
        frame.width * frame.height
    }

    private func resolveCaptureTargetWindow(
        from candidateWindows: [SCWindow],
        processIdentifier: pid_t
    ) -> SCWindow? {
        if let frontmostWindowID = resolveFrontmostWindowID(processIdentifier: processIdentifier),
           let frontmostWindow = candidateWindows.first(where: { $0.windowID == frontmostWindowID }) {
            return frontmostWindow
        }

        return candidateWindows.max(by: { calculateWindowArea($0.frame) < calculateWindowArea($1.frame) })
    }

    private func resolveFrontmostWindowID(processIdentifier: pid_t) -> CGWindowID? {
        guard processIdentifier > 0 else {
            return nil
        }

        let windowListOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let windowInfoList = CGWindowListCopyWindowInfo(windowListOptions, kCGNullWindowID)
                as? [[String: Any]]
        else {
            return nil
        }

        for windowInfo in windowInfoList {
            guard
                let ownerProcessIdentifier = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
                ownerProcessIdentifier.int32Value == processIdentifier
            else {
                continue
            }

            let windowLayer = (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard windowLayer == 0 else {
                continue
            }

            guard let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber else {
                continue
            }
            return CGWindowID(windowNumber.uint32Value)
        }

        return nil
    }
}
