import AppKit
import SwiftUI

struct LeftAlignedTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmitAction: (() -> Void)?

    init(
        placeholder: String,
        text: Binding<String>,
        onSubmitAction: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        self.onSubmitAction = onSubmitAction
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.alignment = .left
        textField.placeholderString = placeholder
        textField.stringValue = text
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.handleSubmit)
        textField.delegate = context.coordinator
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.alignment = .left
        if textField.placeholderString != placeholder {
            textField.placeholderString = placeholder
        }
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LeftAlignedTextField

        init(_ parent: LeftAlignedTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }
            parent.text = textField.stringValue
        }

        @objc func handleSubmit() {
            parent.onSubmitAction?()
        }
    }
}

struct CaptureNowShortcutRecorderView: View {
    let shortcutDisplayText: String
    let hasShortcut: Bool
    let onShortcutCaptured: (String, Int, EventModifiers) -> Void
    let onShortcutCleared: () -> Void

    @State private var isRecordingShortcut = false
    @State private var keyEventMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(isRecordingShortcut ? L10n.string("settings.button.shortcut_recording") : shortcutDisplayText) {
                beginShortcutRecording()
            }
            .buttonStyle(BorderedButtonStyle())

            if hasShortcut {
                Button("settings.button.clear_shortcut") {
                    onShortcutCleared()
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(isRecordingShortcut)
            }
        }
        .onChange(of: isRecordingShortcut) { _, isRecordingShortcut in
            if isRecordingShortcut {
                startKeyEventMonitor()
            } else {
                stopKeyEventMonitor()
            }
        }
        .onDisappear {
            stopKeyEventMonitor()
        }
    }

    private func beginShortcutRecording() {
        isRecordingShortcut = true
    }

    private func startKeyEventMonitor() {
        guard keyEventMonitor == nil else {
            return
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecordingShortcut else {
                return event
            }
            return handleKeyDownEvent(event)
        }
    }

    private func stopKeyEventMonitor() {
        guard let keyEventMonitor else {
            return
        }
        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
    }

    private func handleKeyDownEvent(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            isRecordingShortcut = false
            return nil
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            onShortcutCleared()
            isRecordingShortcut = false
            return nil
        }

        guard let capturedKey = resolveCapturedKey(event: event) else {
            NSSound.beep()
            return nil
        }

        let capturedModifiers = resolveCapturedModifiers(eventModifierFlags: event.modifierFlags)
        if capturedModifiers.isEmpty {
            NSSound.beep()
            return nil
        }

        onShortcutCaptured(capturedKey, Int(event.keyCode), capturedModifiers)
        isRecordingShortcut = false
        return nil
    }

    private func resolveCapturedModifiers(eventModifierFlags: NSEvent.ModifierFlags) -> EventModifiers {
        var capturedModifiers: EventModifiers = []

        if eventModifierFlags.contains(.command) {
            capturedModifiers.insert(.command)
        }
        if eventModifierFlags.contains(.control) {
            capturedModifiers.insert(.control)
        }
        if eventModifierFlags.contains(.option) {
            capturedModifiers.insert(.option)
        }
        if eventModifierFlags.contains(.shift) {
            capturedModifiers.insert(.shift)
        }

        return capturedModifiers
    }

    private func resolveCapturedKey(event: NSEvent) -> String? {
        guard let inputCharacters = event.charactersIgnoringModifiers, let firstCharacter = inputCharacters.first else {
            return nil
        }
        return CaptureNowShortcutResolver.normalizeStoredKey(String(firstCharacter))
    }
}
