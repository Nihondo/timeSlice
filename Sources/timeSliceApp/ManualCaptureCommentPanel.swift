import AppKit
import SwiftUI

@MainActor
final class ManualCaptureCommentPanelPresenter: NSObject, NSWindowDelegate {
    private let closeAnimationDuration: TimeInterval = 0.12
    private var activePanel: ManualCaptureCommentPanel?
    private var keyDownEventMonitor: Any?
    private var onCancelAction: (() -> Void)?
    private var isHandlingSubmit = false

    var isPresenting: Bool {
        activePanel != nil
    }

    func dismissActivePanelIfNeeded() {
        guard isPresenting else {
            return
        }
        cancelAndClosePanel()
    }

    func present(onSubmitComment: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        closePanelIfNeeded()
        onCancelAction = onCancel

        let panel = ManualCaptureCommentPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 170),
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
            onSubmitComment: { [weak self] commentText in
                guard let self else {
                    return
                }
                self.onCancelAction = nil
                self.isHandlingSubmit = true
                self.closePanelIfNeeded(animated: true) { [weak self] in
                    guard let self else {
                        return
                    }
                    self.isHandlingSubmit = false
                    onSubmitComment(commentText)
                }
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
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isHandlingSubmit == false else {
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
        closePanelIfNeeded(animated: true) {
            onCancelAction?()
        }
    }
}

private final class ManualCaptureCommentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct ManualCaptureCommentView: View {
    let onSubmitComment: (String) -> Void
    let onCancel: () -> Void

    @State private var commentText = ""
    @State private var isViewVisible = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text("manual_capture.comment.title")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
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

            HStack(spacing: 14) {
                ShortcutHintView(
                    keyLabel: "Enter",
                    actionLabel: L10n.string("manual_capture.comment.hint.submit")
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
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .inset(by: 1.2)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
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

    private func submitComment() {
        let normalizedComment = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmitComment(normalizedComment)
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
