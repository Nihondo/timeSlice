import AppKit
import Foundation
import ServiceManagement
import UserNotifications
import Carbon

final class GlobalHotKeyManager {
    var onHotKeyPressed: (() -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var registeredHotKeyRef: EventHotKeyRef?
    private let hotKeyID = EventHotKeyID(signature: 0x5453484B, id: 1)

    init() {
        installHotKeyEventHandlerIfNeeded()
    }

    deinit {
        unregisterHotKeyIfNeeded()
        removeHotKeyEventHandlerIfNeeded()
    }

    func updateRegistration(_ shortcutConfiguration: CaptureNowShortcutConfiguration?) {
        unregisterHotKeyIfNeeded()

        guard
            let shortcutConfiguration,
            let keyCode = shortcutConfiguration.keyCode
        else {
            return
        }

        let carbonModifiers = resolveCarbonModifiers(shortcutConfiguration.modifiersRawValue)
        guard keyCode >= 0 else {
            return
        }

        var createdHotKeyRef: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &createdHotKeyRef
        )
        guard registrationStatus == noErr else {
            return
        }
        registeredHotKeyRef = createdHotKeyRef
    }

    fileprivate func handleHotKeyPressedEvent(_ eventRef: EventRef?) -> OSStatus {
        guard let eventRef else {
            return OSStatus(eventNotHandledErr)
        }

        var pressedHotKeyID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &pressedHotKeyID
        )
        guard parameterStatus == noErr else {
            return parameterStatus
        }
        guard pressedHotKeyID.signature == hotKeyID.signature, pressedHotKeyID.id == hotKeyID.id else {
            return OSStatus(eventNotHandledErr)
        }

        onHotKeyPressed?()
        return noErr
    }

    private func installHotKeyEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }

        var hotKeyPressedEventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installationStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            captureNowGlobalHotKeyEventHandler,
            1,
            &hotKeyPressedEventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
        guard installationStatus == noErr else {
            return
        }
    }

    private func removeHotKeyEventHandlerIfNeeded() {
        guard let eventHandlerRef else {
            return
        }
        RemoveEventHandler(eventHandlerRef)
        self.eventHandlerRef = nil
    }

    private func unregisterHotKeyIfNeeded() {
        guard let registeredHotKeyRef else {
            return
        }
        UnregisterEventHotKey(registeredHotKeyRef)
        self.registeredHotKeyRef = nil
    }

    private func resolveCarbonModifiers(_ shortcutModifiersRawValue: Int) -> UInt32 {
        var carbonModifiers: UInt32 = 0
        if shortcutModifiersRawValue & 16 != 0 {
            carbonModifiers |= UInt32(cmdKey)
        }
        if shortcutModifiersRawValue & 8 != 0 {
            carbonModifiers |= UInt32(optionKey)
        }
        if shortcutModifiersRawValue & 4 != 0 {
            carbonModifiers |= UInt32(controlKey)
        }
        if shortcutModifiersRawValue & 2 != 0 {
            carbonModifiers |= UInt32(shiftKey)
        }
        return carbonModifiers
    }
}

private func captureNowGlobalHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ eventRef: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else {
        return OSStatus(eventNotHandledErr)
    }
    let hotKeyManager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    return hotKeyManager.handleHotKeyPressedEvent(eventRef)
}

enum FrontmostSelectionTextResolver {
    static func isAccessibilityPermissionGranted() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() -> Bool {
        let promptOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(promptOptions)
    }

    static func resolveInitialComment(
        from application: NSRunningApplication?,
        shouldPromptForPermission: Bool
    ) -> String {
        guard isAccessibilityTrusted(shouldPromptForPermission: shouldPromptForPermission) else {
            return ""
        }
        guard let processIdentifier = application?.processIdentifier else {
            return ""
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard
            let focusedElementValue = copyAttributeValue(
                of: applicationElement,
                attribute: kAXFocusedUIElementAttribute as CFString
            ),
            CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID()
        else {
            return ""
        }
        let focusedElement = unsafeBitCast(focusedElementValue, to: AXUIElement.self)
        guard
            let selectedTextValue = copyAttributeValue(
                of: focusedElement,
                attribute: kAXSelectedTextAttribute as CFString
            )
        else {
            return ""
        }
        return normalizeSelectedText(selectedTextValue)
    }

    private static func copyAttributeValue(of element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var attributeValue: CFTypeRef?
        let copyStatus = AXUIElementCopyAttributeValue(element, attribute, &attributeValue)
        guard copyStatus == .success else {
            return nil
        }
        return attributeValue
    }

    private static func normalizeSelectedText(_ selectedTextValue: CFTypeRef) -> String {
        let selectedText: String
        if let plainText = selectedTextValue as? String {
            selectedText = plainText
        } else if let attributedText = selectedTextValue as? NSAttributedString {
            selectedText = attributedText.string
        } else {
            return ""
        }

        return selectedText
            .replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAccessibilityTrusted(shouldPromptForPermission: Bool) -> Bool {
        guard shouldPromptForPermission else {
            return isAccessibilityPermissionGranted()
        }
        return requestAccessibilityPermission()
    }
}

enum ReportGenerationSource {
    case manual
    case scheduled
}

enum ReportNotificationUserInfoKey {
    static let reportFilePath = "reportFilePath"
}

enum ReportFileOpeningExecutor {
    static func executeOpenCommand(reportFilePath: String) {
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [reportFilePath]
        do {
            try openProcess.run()
        } catch {
            // Ignore open-command failures.
        }
    }
}

@MainActor
final class ReportNotificationManager {
    private let notificationCenter: UNUserNotificationCenter
    private var hasConfigured = false
    private var isNotificationAuthorized = false

    init() {
        notificationCenter = UNUserNotificationCenter.current()
    }

    func configureIfNeeded() {
        guard hasConfigured == false else {
            return
        }
        hasConfigured = true

        Task { [weak self] in
            guard let self else {
                return
            }
            await refreshAuthorizationState()
        }
    }

    func postReportGeneratedNotification(
        reportFileURL: URL,
        sourceRecordCount: Int,
        generationSource: ReportGenerationSource
    ) async {
        await refreshAuthorizationState()
        guard isNotificationAuthorized else {
            return
        }

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = resolveGeneratedNotificationTitle(for: generationSource)
        notificationContent.body = L10n.format(
            "notification.report.body",
            reportFileURL.lastPathComponent,
            sourceRecordCount
        )
        notificationContent.userInfo = [ReportNotificationUserInfoKey.reportFilePath: reportFileURL.path]
        notificationContent.sound = .default

        let notificationRequest = UNNotificationRequest(
            identifier: "report-generated-\(UUID().uuidString)",
            content: notificationContent,
            trigger: nil
        )
        do {
            try await notificationCenter.add(notificationRequest)
        } catch {
            // Ignore notification submission failures to avoid blocking report generation.
        }
    }

    func postReportFailedNotification(
        errorDescription: String,
        generationSource: ReportGenerationSource
    ) async {
        await refreshAuthorizationState()
        guard isNotificationAuthorized else {
            return
        }

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = resolveFailedNotificationTitle(for: generationSource)
        notificationContent.body = L10n.format(
            "notification.report.body.failed",
            errorDescription
        )
        notificationContent.sound = .default

        let notificationRequest = UNNotificationRequest(
            identifier: "report-failed-\(UUID().uuidString)",
            content: notificationContent,
            trigger: nil
        )
        do {
            try await notificationCenter.add(notificationRequest)
        } catch {
            // Ignore notification submission failures to avoid blocking report generation.
        }
    }

    func postCaptureCompletedNotification(resultMessage: String, windowTitle: String?) async {
        await refreshAuthorizationState()
        guard isNotificationAuthorized else {
            return
        }

        let resolvedWindowTitle: String
        if let windowTitle, windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            resolvedWindowTitle = windowTitle
        } else {
            resolvedWindowTitle = L10n.string("notification.capture.value.window_title_unavailable")
        }
        let captureDetailMessage = L10n.format("notification.capture.body.window_title", resolvedWindowTitle)

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = L10n.string("notification.capture.title.manual")
        notificationContent.body = [resultMessage, captureDetailMessage].joined(separator: "\n")
        notificationContent.sound = .default

        let notificationRequest = UNNotificationRequest(
            identifier: "capture-completed-\(UUID().uuidString)",
            content: notificationContent,
            trigger: nil
        )
        do {
            try await notificationCenter.add(notificationRequest)
        } catch {
            // Ignore notification submission failures to avoid blocking capture flow.
        }
    }

    private func resolveGeneratedNotificationTitle(for generationSource: ReportGenerationSource) -> String {
        switch generationSource {
        case .manual:
            return L10n.string("notification.report.title.manual")
        case .scheduled:
            return L10n.string("notification.report.title.scheduled")
        }
    }

    private func resolveFailedNotificationTitle(for generationSource: ReportGenerationSource) -> String {
        switch generationSource {
        case .manual:
            return L10n.string("notification.report.title.manual_failed")
        case .scheduled:
            return L10n.string("notification.report.title.scheduled_failed")
        }
    }

    private func refreshAuthorizationState() async {
        let notificationSettings = await notificationCenter.notificationSettings()
        switch notificationSettings.authorizationStatus {
        case .authorized, .provisional:
            isNotificationAuthorized = true
        case .notDetermined:
            do {
                isNotificationAuthorized = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            } catch {
                isNotificationAuthorized = false
            }
        default:
            isNotificationAuthorized = false
        }
    }
}

enum LaunchAtLoginManager {
    static func resolveServiceStatus() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func resolveRegistrationState() -> Bool {
        resolveRegistrationState(serviceStatus: resolveServiceStatus())
    }

    static func resolveRegistrationState(serviceStatus: SMAppService.Status) -> Bool {
        switch serviceStatus {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    static func updateRegistration(isEnabled: Bool) throws {
        let currentValue = resolveRegistrationState()
        guard currentValue != isEnabled else {
            return
        }

        if isEnabled {
            try SMAppService.mainApp.register()
            return
        }
        try SMAppService.mainApp.unregister()
    }
}
