import AppKit
import SwiftUI

@MainActor
final class ManualCaptureCommentPanelPresenter: NSObject, NSWindowDelegate {
    private let closeAnimationDuration: TimeInterval = 0.12
    private var activePanel: ManualCaptureCommentPanel?
    private var keyDownEventMonitor: Any?
    private var onCancelAction: (() -> Void)?
    private var onSearchInViewerAction: ((String) -> Void)?
    private var currentCommentText = ""
    private var isHandlingPanelAction = false

    var isPresenting: Bool {
        activePanel != nil
    }

    func dismissActivePanelIfNeeded() {
        guard isPresenting else {
            return
        }
        cancelAndClosePanel()
    }

    func present(
        applicationName: String,
        windowTitle: String?,
        initialComment: String = "",
        onSubmitComment: @escaping (String) -> Void,
        onSearchInViewer: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        closePanelIfNeeded()
        onCancelAction = onCancel
        onSearchInViewerAction = onSearchInViewer
        currentCommentText = initialComment

        let panel = ManualCaptureCommentPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 190),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow

        let commentView = ManualCaptureCommentView(
            applicationName: applicationName,
            windowTitle: windowTitle,
            initialComment: initialComment,
            onSubmitComment: { [weak self] commentText in
                guard let self else {
                    return
                }
                self.onCancelAction = nil
                self.onSearchInViewerAction = nil
                self.isHandlingPanelAction = true
                self.closePanelIfNeeded(animated: true) { [weak self] in
                    guard let self else {
                        return
                    }
                    self.isHandlingPanelAction = false
                    onSubmitComment(commentText)
                }
            },
            onCommentTextChange: { [weak self] updatedCommentText in
                self?.currentCommentText = updatedCommentText
            },
            onCancel: { [weak self] in
                self?.cancelAndClosePanel()
            }
        )
        panel.contentView = NSHostingView(rootView: commentView)

        activePanel = panel
        installKeyDownMonitorIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        activePanel = nil
        onSearchInViewerAction = nil
        currentCommentText = ""
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isHandlingPanelAction == false else {
            return
        }
        cancelAndClosePanel()
    }

    private func closePanelIfNeeded(animated: Bool = false, completion: (() -> Void)? = nil) {
        removeKeyDownMonitorIfNeeded()
        guard let activePanel else {
            completion?()
            return
        }
        self.activePanel = nil

        guard animated else {
            activePanel.close()
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = closeAnimationDuration
            activePanel.animator().alphaValue = 0
        } completionHandler: {
            activePanel.close()
            activePanel.alphaValue = 1
            completion?()
        }
    }

    private func installKeyDownMonitorIfNeeded() {
        guard keyDownEventMonitor == nil else {
            return
        }
        keyDownEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] keyEvent in
            guard let self, let activePanel = self.activePanel, activePanel.isKeyWindow else {
                return keyEvent
            }
            if self.isCommandEnterKeyEvent(keyEvent) {
                self.searchInViewerAndClosePanel()
                return nil
            }
            guard keyEvent.keyCode == 53 else {
                return keyEvent
            }
            // Esc cancels the popup and intentionally avoids capture execution.
            self.cancelAndClosePanel()
            return nil
        }
    }

    private func removeKeyDownMonitorIfNeeded() {
        guard let keyDownEventMonitor else {
            return
        }
        NSEvent.removeMonitor(keyDownEventMonitor)
        self.keyDownEventMonitor = nil
    }

    private func cancelAndClosePanel() {
        let onCancelAction = onCancelAction
        self.onCancelAction = nil
        self.onSearchInViewerAction = nil
        self.currentCommentText = ""
        closePanelIfNeeded(animated: true) {
            onCancelAction?()
        }
    }

    private func searchInViewerAndClosePanel() {
        let onSearchInViewerAction = onSearchInViewerAction
        let normalizedSearchQuery = currentCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onCancelAction = nil
        self.onSearchInViewerAction = nil
        self.isHandlingPanelAction = true
        closePanelIfNeeded(animated: true) { [weak self] in
            guard let self else {
                return
            }
            self.isHandlingPanelAction = false
            self.currentCommentText = ""
            onSearchInViewerAction?(normalizedSearchQuery)
        }
    }

    private func isCommandEnterKeyEvent(_ keyEvent: NSEvent) -> Bool {
        let modifierFlags = keyEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifierFlags.contains(.command) else {
            return false
        }
        return keyEvent.keyCode == 36 || keyEvent.keyCode == 76
    }
}

private final class ManualCaptureCommentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct ManualCaptureCommentView: View {
    let applicationName: String
    let windowTitle: String?
    let onSubmitComment: (String) -> Void
    let onCommentTextChange: (String) -> Void
    let onCancel: () -> Void

    @State private var commentText: String
    @State private var isViewVisible = false
    @FocusState private var isInputFocused: Bool

    init(
        applicationName: String,
        windowTitle: String?,
        initialComment: String = "",
        onSubmitComment: @escaping (String) -> Void,
        onCommentTextChange: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.onSubmitComment = onSubmitComment
        self.onCommentTextChange = onCommentTextChange
        self.onCancel = onCancel
        self._commentText = State(initialValue: initialComment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ManualCaptureContextLineView(
                    value: applicationName
                )
                ManualCaptureContextLineView(
                    value: resolveWindowTitleText()
                )
            }

            TextField(
                L10n.string("manual_capture.comment.placeholder"),
                text: $commentText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 23, weight: .medium))
            .focused($isInputFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isInputFocused ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.14),
                            lineWidth: isInputFocused ? 1.8 : 1
                        )
                }
            )
            .shadow(
                color: isInputFocused ? Color.accentColor.opacity(0.24) : .clear,
                radius: isInputFocused ? 10 : 0,
                x: 0,
                y: 0
            )
            .onSubmit(submitComment)
            .onChange(of: commentText) { _, updatedCommentText in
                onCommentTextChange(updatedCommentText)
            }

            HStack(spacing: 14) {
                ShortcutHintView(
                    keyLabel: "Enter",
                    actionLabel: L10n.string("manual_capture.comment.hint.submit")
                )
                ShortcutHintView(
                    keyLabel: "⌘ + ENTER",
                    actionLabel: L10n.string("manual_capture.comment.hint.search")
                )
                ShortcutHintView(
                    keyLabel: "Esc",
                    actionLabel: L10n.string("manual_capture.comment.hint.cancel")
                )
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.06),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        )
        .overlay(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.30), lineWidth: 2.2)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .inset(by: 1.8)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.9)
            }
        )
        .shadow(color: Color.black.opacity(0.24), radius: 20, x: 0, y: 10)
        .opacity(isViewVisible ? 1 : 0)
        .scaleEffect(isViewVisible ? 1 : 0.96)
        .onAppear {
            withAnimation(.easeOut(duration: 0.12)) {
                isViewVisible = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                isInputFocused = true
            }
        }
        .onExitCommand {
            onCancel()
        }
    }

    private func resolveWindowTitleText() -> String {
        guard let windowTitle, windowTitle.isEmpty == false else {
            return L10n.string("viewer.value.no_window_title")
        }
        return windowTitle
    }

    private func submitComment() {
        let normalizedComment = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmitComment(normalizedComment)
    }
}

private struct ManualCaptureContextLineView: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.secondary)
    }
}

private struct ShortcutHintView: View {
    let keyLabel: String
    let actionLabel: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keyLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.86))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
            Text(actionLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
