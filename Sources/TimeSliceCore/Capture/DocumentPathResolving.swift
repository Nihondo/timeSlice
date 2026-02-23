import ApplicationServices
import Foundation

/// Resolves the frontmost document path from an application process via Accessibility APIs.
public protocol DocumentPathResolving: Sendable {
    func resolveDocumentPath(processIdentifier: pid_t) -> String?
}

/// Accessibility-based document path resolver.
///
/// It attempts to read, in order:
/// 1. `AXDocument` from the focused window
/// 2. `AXFilename` from the focused window
/// 3. `AXURL` / `AXDocument` / `AXFilename` from the window's `AXProxy` element
public final class AccessibilityDocumentPathResolver: DocumentPathResolving, @unchecked Sendable {
    public init() {}

    public func resolveDocumentPath(processIdentifier: pid_t) -> String? {
        guard processIdentifier > 0 else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard let focusedWindowElement = resolveFocusedWindowElement(from: applicationElement) else {
            return nil
        }
        return resolveDocumentPath(from: focusedWindowElement)
    }

    private func resolveFocusedWindowElement(from applicationElement: AXUIElement) -> AXUIElement? {
        if let focusedWindowValue = copyAttributeValue(
            of: applicationElement,
            attribute: kAXFocusedWindowAttribute as CFString
        ) {
            return castToAXUIElement(focusedWindowValue)
        }

        guard
            let focusedElementValue = copyAttributeValue(
                of: applicationElement,
                attribute: kAXFocusedUIElementAttribute as CFString
            ),
            let focusedElement = castToAXUIElement(focusedElementValue),
            let parentWindowValue = copyAttributeValue(
                of: focusedElement,
                attribute: kAXWindowAttribute as CFString
            )
        else {
            return nil
        }
        return castToAXUIElement(parentWindowValue)
    }

    private func resolveDocumentPath(from windowElement: AXUIElement) -> String? {
        let primaryAttributes: [CFString] = [
            kAXDocumentAttribute as CFString,
            kAXFilenameAttribute as CFString
        ]
        if let windowDocumentPath = resolveDocumentPath(from: windowElement, attributes: primaryAttributes) {
            return windowDocumentPath
        }

        guard
            let proxyValue = copyAttributeValue(of: windowElement, attribute: kAXProxyAttribute as CFString),
            let proxyElement = castToAXUIElement(proxyValue)
        else {
            return nil
        }

        let proxyAttributes: [CFString] = [
            kAXURLAttribute as CFString,
            kAXDocumentAttribute as CFString,
            kAXFilenameAttribute as CFString
        ]
        return resolveDocumentPath(from: proxyElement, attributes: proxyAttributes)
    }

    private func resolveDocumentPath(from element: AXUIElement, attributes: [CFString]) -> String? {
        for attribute in attributes {
            guard let rawAttributeValue = copyAttributeValue(of: element, attribute: attribute) else {
                continue
            }
            if let documentPath = normalizeDocumentPath(from: rawAttributeValue) {
                return documentPath
            }
        }
        return nil
    }

    private func copyAttributeValue(of element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var attributeValue: CFTypeRef?
        let copyStatus = AXUIElementCopyAttributeValue(element, attribute, &attributeValue)
        guard copyStatus == .success else {
            return nil
        }
        return attributeValue
    }

    private func castToAXUIElement(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func normalizeDocumentPath(from rawAttributeValue: CFTypeRef) -> String? {
        if let attributeStringValue = rawAttributeValue as? String {
            return resolveFilePath(from: attributeStringValue)
        }
        if let attributeURLValue = rawAttributeValue as? URL {
            let path = attributeURLValue.path(percentEncoded: false)
            return path.isEmpty ? nil : path
        }
        return nil
    }

    private func resolveFilePath(from attributeValue: String) -> String? {
        let trimmedValue = attributeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.isEmpty == false else {
            return nil
        }

        if trimmedValue.hasPrefix("/") {
            return trimmedValue.removingPercentEncoding ?? trimmedValue
        }

        guard let resolvedURL = URL(string: trimmedValue), resolvedURL.isFileURL else {
            return nil
        }
        let resolvedPath = resolvedURL.path(percentEncoded: false)
        return resolvedPath.isEmpty ? nil : resolvedPath
    }
}
