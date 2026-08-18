import AppKit
import Foundation
import ServiceManagement
import UserNotifications
import Carbon

final class GlobalHotKeyManager {
    var onHotKeyPressed: (() -> Void)?
    var onRectangleCaptureHotKeyPressed: (() -> Void)?
    var onOpenViewerHotKeyPressed: (() -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var registeredHotKeyRef: EventHotKeyRef?
    private var registeredRectangleCaptureHotKeyRef: EventHotKeyRef?
    private var registeredOpenViewerHotKeyRef: EventHotKeyRef?
    private let hotKeyID = EventHotKeyID(signature: 0x5453484B, id: 1)
    private let rectangleCaptureHotKeyID = EventHotKeyID(signature: 0x5453484B, id: 2)
    private let openViewerHotKeyID = EventHotKeyID(signature: 0x5453484B, id: 3)

    init() {
        installHotKeyEventHandlerIfNeeded()
    }

    deinit {
        unregisterHotKeyIfNeeded()
        unregisterRectangleCaptureHotKeyIfNeeded()
        unregisterOpenViewerHotKeyIfNeeded()
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

    func updateRectangleCaptureRegistration(_ shortcutConfiguration: CaptureNowShortcutConfiguration?) {
        unregisterRectangleCaptureHotKeyIfNeeded()

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
            rectangleCaptureHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &createdHotKeyRef
        )
        guard registrationStatus == noErr else {
            return
        }
        registeredRectangleCaptureHotKeyRef = createdHotKeyRef
    }

    func updateOpenViewerRegistration(_ shortcutConfiguration: CaptureNowShortcutConfiguration?) {
        unregisterOpenViewerHotKeyIfNeeded()

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
            openViewerHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &createdHotKeyRef
        )
        guard registrationStatus == noErr else {
            return
        }
        registeredOpenViewerHotKeyRef = createdHotKeyRef
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
        guard pressedHotKeyID.signature == hotKeyID.signature else {
            return OSStatus(eventNotHandledErr)
        }

        if pressedHotKeyID.id == hotKeyID.id {
            onHotKeyPressed?()
            return noErr
        } else if pressedHotKeyID.id == rectangleCaptureHotKeyID.id {
            onRectangleCaptureHotKeyPressed?()
            return noErr
        } else if pressedHotKeyID.id == openViewerHotKeyID.id {
            onOpenViewerHotKeyPressed?()
            return noErr
        }
        return OSStatus(eventNotHandledErr)
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

    private func unregisterRectangleCaptureHotKeyIfNeeded() {
        guard let registeredRectangleCaptureHotKeyRef else {
            return
        }
        UnregisterEventHotKey(registeredRectangleCaptureHotKeyRef)
        self.registeredRectangleCaptureHotKeyRef = nil
    }

    private func unregisterOpenViewerHotKeyIfNeeded() {
        guard let registeredOpenViewerHotKeyRef else {
            return
        }
        UnregisterEventHotKey(registeredOpenViewerHotKeyRef)
        self.registeredOpenViewerHotKeyRef = nil
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
    struct ManualCaptureContext {
        let initialComment: String
        let focusedWindowTitle: String?
    }

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
        resolveManualCaptureContext(
            from: application,
            shouldPromptForPermission: shouldPromptForPermission
        ).initialComment
    }

    static func resolveManualCaptureContext(
        from application: NSRunningApplication?,
        shouldPromptForPermission: Bool
    ) -> ManualCaptureContext {
        guard isAccessibilityTrusted(shouldPromptForPermission: shouldPromptForPermission) else {
            return ManualCaptureContext(initialComment: "", focusedWindowTitle: nil)
        }
        guard let processIdentifier = application?.processIdentifier else {
            return ManualCaptureContext(initialComment: "", focusedWindowTitle: nil)
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let resolvedInitialComment = resolveSelectedText(from: applicationElement)
        let resolvedWindowTitle = resolveFocusedWindowTitle(from: applicationElement)
        return ManualCaptureContext(
            initialComment: resolvedInitialComment,
            focusedWindowTitle: resolvedWindowTitle
        )
    }

    private static func resolveSelectedText(from applicationElement: AXUIElement) -> String {
        let (focusedElement, selectedText) = resolveFocusedElementAndSelectedText(from: applicationElement)
        guard shouldAttemptManualAccessibilityRecovery(
            hasFocusedElement: focusedElement != nil,
            selectedText: selectedText
        ) else {
            return selectedText
        }
        // Electron/Chromium apps (VS Code, Slack, etc.) don't build an accessibility tree unless
        // requested by assistive technology, so the read above always comes back empty in them.
        // Setting AXManualAccessibility asks the app to build it; the build happens asynchronously
        // in the target process, so an immediate re-read can still miss it even after this call.
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        let (recoveredFocusedElement, recoveredSelectedText) = resolveFocusedElementAndSelectedText(
            from: applicationElement
        )
        guard recoveredSelectedText.isEmpty else {
            return recoveredSelectedText
        }

        // AX-based recovery still came back empty. Capture Now is an explicit user action
        // (not a popup shown ambiently on every keystroke), so a Cmd+C read is an acceptable
        // fallback here — but never for secure text fields, to avoid ever copying a password.
        guard isSecureTextField(recoveredFocusedElement ?? focusedElement) == false else {
            return ""
        }
        return ClipboardSelectionReader.readSelectedText()
    }

    private static func isSecureTextField(_ focusedElement: AXUIElement?) -> Bool {
        guard let focusedElement else {
            return false
        }
        let role = copyAttributeValue(of: focusedElement, attribute: kAXRoleAttribute as CFString) as? String
        let subrole = copyAttributeValue(of: focusedElement, attribute: kAXSubroleAttribute as CFString) as? String
        let secureIdentifier = kAXSecureTextFieldSubrole as String
        return role == secureIdentifier || subrole == secureIdentifier
    }

    private static func resolveFocusedElementAndSelectedText(
        from applicationElement: AXUIElement
    ) -> (focusedElement: AXUIElement?, selectedText: String) {
        guard
            let focusedElementValue = copyAttributeValue(
                of: applicationElement,
                attribute: kAXFocusedUIElementAttribute as CFString
            ),
            CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID()
        else {
            return (nil, "")
        }
        let focusedElement = unsafeBitCast(focusedElementValue, to: AXUIElement.self)
        guard
            let selectedTextValue = copyAttributeValue(
                of: focusedElement,
                attribute: kAXSelectedTextAttribute as CFString
            ),
            let normalizedSelectedText = normalizeTextValue(selectedTextValue)
        else {
            return (focusedElement, "")
        }
        return (focusedElement, normalizeSelectedText(normalizedSelectedText))
    }

    private static func shouldAttemptManualAccessibilityRecovery(
        hasFocusedElement: Bool,
        selectedText: String
    ) -> Bool {
        hasFocusedElement == false || selectedText.isEmpty
    }

    private static func resolveFocusedWindowTitle(from applicationElement: AXUIElement) -> String? {
        if let focusedWindowElement = resolveFocusedWindowElement(from: applicationElement) {
            return resolveWindowTitle(from: focusedWindowElement)
        }
        guard
            let focusedElementValue = copyAttributeValue(
                of: applicationElement,
                attribute: kAXFocusedUIElementAttribute as CFString
            ),
            CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let focusedElement = unsafeBitCast(focusedElementValue, to: AXUIElement.self)
        guard
            let windowElementValue = copyAttributeValue(
                of: focusedElement,
                attribute: kAXWindowAttribute as CFString
            ),
            CFGetTypeID(windowElementValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let windowElement = unsafeBitCast(windowElementValue, to: AXUIElement.self)
        return resolveWindowTitle(from: windowElement)
    }

    private static func resolveFocusedWindowElement(from applicationElement: AXUIElement) -> AXUIElement? {
        guard
            let focusedWindowValue = copyAttributeValue(
                of: applicationElement,
                attribute: kAXFocusedWindowAttribute as CFString
            ),
            CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(focusedWindowValue, to: AXUIElement.self)
    }

    private static func resolveWindowTitle(from windowElement: AXUIElement) -> String? {
        guard
            let windowTitleValue = copyAttributeValue(
                of: windowElement,
                attribute: kAXTitleAttribute as CFString
            ),
            let normalizedWindowTitle = normalizeTextValue(windowTitleValue)
        else {
            return nil
        }
        return normalizeWindowTitle(normalizedWindowTitle)
    }

    private static func copyAttributeValue(of element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var attributeValue: CFTypeRef?
        let copyStatus = AXUIElementCopyAttributeValue(element, attribute, &attributeValue)
        guard copyStatus == .success else {
            return nil
        }
        return attributeValue
    }

    private static func normalizeTextValue(_ value: CFTypeRef) -> String? {
        if let plainText = value as? String {
            return plainText
        }
        if let attributedText = value as? NSAttributedString {
            return attributedText.string
        }
        return nil
    }

    private static func normalizeSelectedText(_ selectedText: String) -> String {
        selectedText
            .replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeWindowTitle(_ windowTitle: String) -> String? {
        let normalizedWindowTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedWindowTitle.isEmpty == false else {
            return nil
        }
        return normalizedWindowTitle
    }

    private static func isAccessibilityTrusted(shouldPromptForPermission: Bool) -> Bool {
        guard shouldPromptForPermission else {
            return isAccessibilityPermissionGranted()
        }
        return requestAccessibilityPermission()
    }
}

/// AX 経由の選択テキスト取得（`AXManualAccessibility` リカバリ込み）が失敗した場合の
/// 最終フォールバック。前面アプリへ Cmd+C を送出し、クリップボード経由で選択テキストを読み取る。
/// ユーザーのクリップボードを壊さないことを絶対条件とし、読取の成否によらず必ず元の内容を復元する。
///
/// 対象アプリ自身がコピーを実行するため、クリップボード履歴アプリには「選択テキスト」と
/// 「復元された元の内容」の 2 件が記録される制限がある。また VS Code のように未選択時に
/// 現在行をコピーするアプリでは、意図せず現在行が入力候補になることがある。
private enum ClipboardSelectionReader {
    private static let copyReflectionTimeoutMs = 300
    private static let pollIntervalMs = 10

    static func readSelectedText() -> String {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        defer {
            snapshot.restore(to: pasteboard)
        }

        postCommandC()

        // 対象アプリがコピーを反映して changeCount が動くのを短い間隔でポーリングする。
        // 動かなければ copyReflectionTimeoutMs 経過で「未選択」として打ち切る。
        var elapsedMs = 0
        while pasteboard.changeCount == snapshot.changeCountBeforeCapture, elapsedMs < copyReflectionTimeoutMs {
            Thread.sleep(forTimeInterval: TimeInterval(pollIntervalMs) / 1000)
            elapsedMs += pollIntervalMs
        }

        guard pasteboard.changeCount != snapshot.changeCountBeforeCapture else {
            return ""
        }
        return (pasteboard.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func postCommandC() {
        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else {
            return
        }
        let commandKeyCode: CGKeyCode = 0x37 // kVK_Command
        let cKeyCode: CGKeyCode = 0x08 // kVK_ANSI_C

        let commandDown = CGEvent(keyboardEventSource: eventSource, virtualKey: commandKeyCode, keyDown: true)
        let cDown = CGEvent(keyboardEventSource: eventSource, virtualKey: cKeyCode, keyDown: true)
        cDown?.flags = .maskCommand
        let cUp = CGEvent(keyboardEventSource: eventSource, virtualKey: cKeyCode, keyDown: false)
        cUp?.flags = .maskCommand
        let commandUp = CGEvent(keyboardEventSource: eventSource, virtualKey: commandKeyCode, keyDown: false)

        commandDown?.post(tap: .cghidEventTap)
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
        commandUp?.post(tap: .cghidEventTap)
    }
}

/// クリップボードの内容を型ごと複製したスナップショット。`ClipboardSelectionReader` が
/// Cmd+C 読取の前後でユーザーのクリップボードを退避・復元するために使う。
private struct PasteboardSnapshot {
    /// 各アイテムが持つ (型, データ) の一覧。
    let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
    /// 退避直前の changeCount。復元直前にこの値からの変化を確認するために使う。
    let changeCountBeforeCapture: Int

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [(NSPasteboard.PasteboardType, Data)] in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else {
                    return nil
                }
                return (type, data)
            }
        }
        return PasteboardSnapshot(items: items, changeCountBeforeCapture: pasteboard.changeCount)
    }

    func restore(to pasteboard: NSPasteboard) {
        // 復元直前に、まだ自分が書き込んだ内容のままかを確認する。
        // その間にユーザーが別の内容を手動コピーしていた場合は、それを上書きしない。
        guard pasteboard.changeCount != changeCountBeforeCapture else {
            return
        }

        pasteboard.clearContents()
        guard items.isEmpty == false else {
            // 退避時点でクリップボードが空だった場合は、空のまま維持する。
            return
        }

        let restoredItems: [NSPasteboardItem] = items.map { typedDataList in
            let item = NSPasteboardItem()
            for (type, data) in typedDataList {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}

enum ReportGenerationSource {
    case manual
    case scheduled
}

enum ReportNotificationUserInfoKey {
    static let reportFilePath = "reportFilePath"
}

enum CaptureNotificationUserInfoKey {
    static let captureRecordID = "captureRecordID"
    static let capturedAtEpochSeconds = "capturedAtEpochSeconds"
}

extension Notification.Name {
    static let captureNotificationDidRequestOpenRecord = Notification.Name(
        "captureNotificationDidRequestOpenRecord"
    )
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

    func postCaptureCompletedNotification(
        resultMessage: String,
        windowTitle: String?,
        captureRecordID: UUID?,
        capturedAt: Date?
    ) async {
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
        if let captureRecordID, let capturedAt {
            notificationContent.userInfo = [
                CaptureNotificationUserInfoKey.captureRecordID: captureRecordID.uuidString,
                CaptureNotificationUserInfoKey.capturedAtEpochSeconds: capturedAt.timeIntervalSince1970
            ]
        }
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
