import Foundation

/// Resolves the active browser tab URL from the frontmost browser application.
public protocol BrowserURLResolving: Sendable {
    func resolveBrowserURL(bundleIdentifier: String) async -> String?
}

/// AppleScript-based implementation for supported browsers.
/// Uses a longer timeout for the first attempt per browser (permission dialog may appear),
/// then a shorter timeout for subsequent attempts.
public final class BrowserURLResolver: BrowserURLResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var attemptedBundleIdentifiers: Set<String> = []

    private let firstAttemptTimeoutMilliseconds = 30_000
    private let normalTimeoutMilliseconds = 3_000

    public init() {}

    public func resolveBrowserURL(bundleIdentifier: String) async -> String? {
        guard let scriptSource = resolveAppleScriptSource(for: bundleIdentifier) else {
            return nil
        }

        let isFirstAttempt = markAttemptAndCheckIfFirst(bundleIdentifier: bundleIdentifier)

        let timeout = isFirstAttempt ? firstAttemptTimeoutMilliseconds : normalTimeoutMilliseconds
        return await executeAppleScriptWithTimeout(source: scriptSource, timeoutMilliseconds: timeout)
    }

    private func markAttemptAndCheckIfFirst(bundleIdentifier: String) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return attemptedBundleIdentifiers.insert(bundleIdentifier).inserted
    }

    private func resolveAppleScriptSource(for bundleIdentifier: String) -> String? {
        switch bundleIdentifier {
        // Safari
        case "com.apple.Safari",
             "com.apple.SafariTechnologyPreview":
            return """
                tell application "Safari"
                    if not (exists front document) then return ""
                    return URL of current tab of front window
                end tell
                """

        // Google Chrome (including beta/dev/canary)
        case "com.google.Chrome",
             "com.google.Chrome.beta",
             "com.google.Chrome.dev",
             "com.google.Chrome.canary":
            return """
                tell application "Google Chrome"
                    if not (exists front window) then return ""
                    return URL of active tab of front window
                end tell
                """

        // Microsoft Edge (including Beta/Dev/Canary)
        case "com.microsoft.edgemac",
             "com.microsoft.edgemac.Beta",
             "com.microsoft.edgemac.Dev",
             "com.microsoft.edgemac.Canary":
            return """
                tell application "Microsoft Edge"
                    if not (exists front window) then return ""
                    return URL of active tab of front window
                end tell
                """

        // Brave Browser (including beta/nightly)
        case "com.brave.Browser",
             "com.brave.Browser.beta",
             "com.brave.Browser.nightly":
            return """
                tell application "Brave Browser"
                    if not (exists front window) then return ""
                    return URL of active tab of front window
                end tell
                """

        // Arc
        case "company.thebrowser.Browser":
            return """
                tell application "Arc"
                    if not (exists front window) then return ""
                    return URL of active tab of front window
                end tell
                """

        // Vivaldi
        case "com.vivaldi.Vivaldi":
            return """
                tell application "Vivaldi"
                    if not (exists front window) then return ""
                    return URL of active tab of front window
                end tell
                """

        default:
            return nil
        }
    }

    private func executeAppleScriptWithTimeout(source: String, timeoutMilliseconds: Int) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await Task.detached(priority: .utility) {
                    let script = NSAppleScript(source: source)
                    var errorInfo: NSDictionary?
                    let result = script?.executeAndReturnError(&errorInfo)
                    guard errorInfo == nil else {
                        return nil
                    }
                    let urlString = result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let urlString, urlString.isEmpty == false else {
                        return nil
                    }
                    return urlString
                }.value
            }

            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                return nil
            }

            let firstResult = await group.next() ?? nil
            group.cancelAll()
            return firstResult
        }
    }
}
