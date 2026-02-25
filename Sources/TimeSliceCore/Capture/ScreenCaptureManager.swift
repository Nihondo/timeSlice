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

            guard window.windowLayer == 0 else {
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

    private func hasExtremeAspectRatio(_ frame: CGRect) -> Bool {
        let width = frame.width
        let height = frame.height
        guard width > 0, height > 0 else {
            return true
        }

        let aspectRatio = max(width / height, height / width)
        // Guard against malformed frames that occasionally appear with fullscreen/video windows.
        return aspectRatio >= 6
    }

    private func hasNonEmptyWindowTitle(_ title: String?) -> Bool {
        guard let title else {
            return false
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func isLikelyOverlayWindow(frame: CGRect, title: String?) -> Bool {
        let isShortHeightWindow = frame.height < 120
        guard isShortHeightWindow else {
            return false
        }

        if hasExtremeAspectRatio(frame) {
            return true
        }
        return hasNonEmptyWindowTitle(title) == false
    }

    private func isLikelyOverlayWindow(_ window: SCWindow) -> Bool {
        isLikelyOverlayWindow(frame: window.frame, title: window.title)
    }

    private func resolveLargestWindow(from windows: [SCWindow]) -> SCWindow? {
        windows.max(by: { calculateWindowArea($0.frame) < calculateWindowArea($1.frame) })
    }

    private func resolvePreferredWindow(from windows: [SCWindow]) -> SCWindow? {
        guard windows.isEmpty == false else {
            return nil
        }

        let titledWindows = windows.filter { hasNonEmptyWindowTitle($0.title) }
        if let largestTitledWindow = resolveLargestWindow(from: titledWindows) {
            return largestTitledWindow
        }
        return resolveLargestWindow(from: windows)
    }

    private func resolveCaptureTargetWindow(
        from candidateWindows: [SCWindow],
        processIdentifier: pid_t
    ) -> SCWindow? {
        guard !candidateWindows.isEmpty else {
            return nil
        }

        let nonOverlayWindows = candidateWindows.filter { !isLikelyOverlayWindow($0) }
        let activeWindows = candidateWindows.filter(\.isActive)
        let activeNonOverlayWindows = activeWindows.filter { !isLikelyOverlayWindow($0) }

        if activeNonOverlayWindows.count == 1, let activeWindow = activeNonOverlayWindows.first {
            return activeWindow
        }

        if !activeNonOverlayWindows.isEmpty,
           let frontmostWindowID = resolveFrontmostWindowID(processIdentifier: processIdentifier),
           let frontmostActiveWindow = activeNonOverlayWindows.first(where: { $0.windowID == frontmostWindowID }) {
            return frontmostActiveWindow
        }

        if let frontmostWindowID = resolveFrontmostWindowID(processIdentifier: processIdentifier),
           let frontmostWindow = candidateWindows.first(where: { $0.windowID == frontmostWindowID }) {
            if !isLikelyOverlayWindow(frontmostWindow) {
                return frontmostWindow
            }
            if let preferredWindow = resolvePreferredWindow(from: nonOverlayWindows) {
                return preferredWindow
            }
            return frontmostWindow
        }

        if let preferredActiveWindow = resolvePreferredWindow(from: activeNonOverlayWindows) {
            return preferredActiveWindow
        }

        if let preferredWindow = resolvePreferredWindow(from: nonOverlayWindows) {
            return preferredWindow
        }

        if let frontmostWindowID = resolveFrontmostWindowID(processIdentifier: processIdentifier),
           let frontmostWindow = candidateWindows.first(where: { $0.windowID == frontmostWindowID }) {
            return frontmostWindow
        }

        let nonExtremeWindows = candidateWindows.filter { !hasExtremeAspectRatio($0.frame) }
        if let largestNonExtremeWindow = resolveLargestWindow(from: nonExtremeWindows) {
            return largestNonExtremeWindow
        }

        return resolveLargestWindow(from: candidateWindows)
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

        var fallbackWindowID: CGWindowID?

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
            let windowID = CGWindowID(windowNumber.uint32Value)
            if fallbackWindowID == nil {
                fallbackWindowID = windowID
            }

            let windowBounds = resolveWindowBounds(from: windowInfo)
            let windowName = windowInfo[kCGWindowName as String] as? String
            if let windowBounds,
               isLikelyOverlayWindow(frame: windowBounds, title: windowName) {
                continue
            }

            return windowID
        }

        return fallbackWindowID
    }

    private func resolveWindowBounds(from windowInfo: [String: Any]) -> CGRect? {
        guard
            let boundsDictionaryValue = windowInfo[kCGWindowBounds as String] as? [String: Any]
        else {
            return nil
        }
        let boundsDictionary = boundsDictionaryValue as CFDictionary
        return CGRect(dictionaryRepresentation: boundsDictionary)
    }
}
