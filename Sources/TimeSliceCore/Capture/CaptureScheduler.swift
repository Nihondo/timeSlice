import Foundation

public struct CaptureSchedulerConfiguration: Sendable {
    public let captureIntervalSeconds: TimeInterval
    public let minimumTextLength: Int
    public let shouldSaveImages: Bool
    public let imageFormat: CaptureImageFormat
    public let excludedApplications: [String]
    public let excludedWindowTitles: [String]

    public init(
        captureIntervalSeconds: TimeInterval = 60,
        minimumTextLength: Int = 10,
        shouldSaveImages: Bool = true,
        imageFormat: CaptureImageFormat = .png,
        excludedApplications: [String] = [],
        excludedWindowTitles: [String] = []
    ) {
        self.captureIntervalSeconds = captureIntervalSeconds
        self.minimumTextLength = minimumTextLength
        self.shouldSaveImages = shouldSaveImages
        self.imageFormat = imageFormat
        self.excludedApplications = excludedApplications
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        self.excludedWindowTitles = excludedWindowTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }
}

public enum CaptureSkipReason: String, Sendable {
    case noWindow
    case shortText
    case duplicateText
    case imageEncodingFailed
}

public enum CaptureCycleOutcome: Sendable {
    case saved(CaptureRecord)
    case skipped(CaptureSkipReason)
    case failed(String)
}

public struct ManualCaptureDraft: Sendable {
    public let applicationName: String
    public let windowTitle: String?
    public let capturedAt: Date
    public let ocrText: String
    public let imageData: Data?
    public let browserURL: String?
    public let documentPath: String?

    public init(
        applicationName: String,
        windowTitle: String?,
        capturedAt: Date,
        ocrText: String,
        imageData: Data?,
        browserURL: String? = nil,
        documentPath: String? = nil
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.capturedAt = capturedAt
        self.ocrText = ocrText
        self.imageData = imageData
        self.browserURL = browserURL
        self.documentPath = documentPath
    }
}

public enum ManualCapturePreparationOutcome: Sendable {
    case prepared(ManualCaptureDraft)
    case skipped(CaptureSkipReason)
    case failed(String)
}

/// Runs capture pipeline periodically: capture -> OCR -> dedupe -> persist.
public actor CaptureScheduler {
    public private(set) var isRunning = false
    public private(set) var lastErrorDescription: String?

    private let screenCapturer: any ScreenCapturing
    private let textRecognizer: any TextRecognizing
    private let duplicateDetector: DuplicateDetector
    private let dataStore: DataStore
    private let imageStore: ImageStore
    private let dateProvider: any DateProviding
    private let configuration: CaptureSchedulerConfiguration

    private var captureLoopTask: Task<Void, Never>?

    public init(
        screenCapturer: any ScreenCapturing,
        textRecognizer: any TextRecognizing,
        duplicateDetector: DuplicateDetector,
        dataStore: DataStore,
        imageStore: ImageStore,
        dateProvider: any DateProviding = SystemDateProvider(),
        configuration: CaptureSchedulerConfiguration = .init()
    ) {
        self.screenCapturer = screenCapturer
        self.textRecognizer = textRecognizer
        self.duplicateDetector = duplicateDetector
        self.dataStore = dataStore
        self.imageStore = imageStore
        self.dateProvider = dateProvider
        self.configuration = configuration
    }

    public func start() {
        guard captureLoopTask == nil else {
            return
        }

        isRunning = true
        captureLoopTask = Task {
            await runCaptureLoop()
        }
    }

    public func stop() {
        captureLoopTask?.cancel()
        captureLoopTask = nil
        isRunning = false
    }

    @discardableResult
    public func performCaptureCycle(
        captureTrigger: CaptureTrigger = .scheduled,
        manualComment: String? = nil
    ) async -> CaptureCycleOutcome {
        do {
            guard let capturedWindow = try await screenCapturer.captureFrontWindow() else {
                return .skipped(.noWindow)
            }
            return try await processCapturedWindow(
                capturedWindow,
                captureTrigger: captureTrigger,
                manualComment: manualComment
            )
        } catch {
            let errorDescription = String(describing: error)
            lastErrorDescription = errorDescription
            return .failed(errorDescription)
        }
    }

    public func prepareManualCaptureDraft() async -> ManualCapturePreparationOutcome {
        do {
            guard let capturedWindow = try await screenCapturer.captureFrontWindow() else {
                return .skipped(.noWindow)
            }

            let isExcludedApplication = matchesExcludedKeyword(
                capturedWindow.applicationName,
                excludedKeywords: configuration.excludedApplications
            )
            let isExcludedWindowTitle = matchesExcludedKeyword(
                capturedWindow.windowTitle,
                excludedKeywords: configuration.excludedWindowTitles
            )
            if isExcludedApplication || isExcludedWindowTitle {
                let manualCaptureDraft = ManualCaptureDraft(
                    applicationName: capturedWindow.applicationName,
                    windowTitle: capturedWindow.windowTitle,
                    capturedAt: capturedWindow.capturedAt,
                    ocrText: "",
                    imageData: nil,
                    browserURL: capturedWindow.browserURL,
                    documentPath: capturedWindow.documentPath
                )
                lastErrorDescription = nil
                return .prepared(manualCaptureDraft)
            }

            let recognizedText: String
            do {
                recognizedText = try await textRecognizer.recognizeText(from: capturedWindow.image)
            } catch {
                recognizedText = ""
            }
            let normalizedText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let encodedImageData: Data?
            if configuration.shouldSaveImages {
                encodedImageData = CaptureImageEncoder.encodeImage(
                    capturedWindow.image,
                    format: configuration.imageFormat
                )
            } else {
                encodedImageData = nil
            }
            let manualCaptureDraft = ManualCaptureDraft(
                applicationName: capturedWindow.applicationName,
                windowTitle: capturedWindow.windowTitle,
                capturedAt: capturedWindow.capturedAt,
                ocrText: normalizedText,
                imageData: encodedImageData,
                browserURL: capturedWindow.browserURL,
                documentPath: capturedWindow.documentPath
            )
            lastErrorDescription = nil
            return .prepared(manualCaptureDraft)
        } catch {
            let errorDescription = String(describing: error)
            lastErrorDescription = errorDescription
            return .failed(errorDescription)
        }
    }

    @discardableResult
    public func saveManualCaptureDraft(
        _ manualCaptureDraft: ManualCaptureDraft,
        manualComment: String? = nil,
        captureTrigger: CaptureTrigger = .manual
    ) async -> CaptureCycleOutcome {
        do {
            let normalizedManualComment = normalizeManualComment(
                captureTrigger: captureTrigger,
                manualComment: manualComment
            )
            _ = await duplicateDetector.shouldStoreText(manualCaptureDraft.ocrText)
            let captureRecord = CaptureRecord(
                applicationName: manualCaptureDraft.applicationName,
                windowTitle: manualCaptureDraft.windowTitle,
                capturedAt: manualCaptureDraft.capturedAt,
                ocrText: manualCaptureDraft.ocrText,
                hasImage: manualCaptureDraft.imageData != nil,
                imageFormat: manualCaptureDraft.imageData == nil ? nil : configuration.imageFormat,
                captureTrigger: captureTrigger,
                comments: normalizedManualComment,
                browserURL: manualCaptureDraft.browserURL,
                documentPath: manualCaptureDraft.documentPath
            )
            try dataStore.saveRecord(captureRecord)
            if let imageData = manualCaptureDraft.imageData {
                try imageStore.saveImageData(
                    imageData,
                    capturedAt: manualCaptureDraft.capturedAt,
                    recordID: captureRecord.id,
                    imageFormat: configuration.imageFormat
                )
            }
            try dataStore.cleanupExpiredData(referenceDate: dateProvider.now)
            try imageStore.cleanupExpiredImages(referenceDate: dateProvider.now)
            lastErrorDescription = nil
            return .saved(captureRecord)
        } catch {
            let errorDescription = String(describing: error)
            lastErrorDescription = errorDescription
            return .failed(errorDescription)
        }
    }

    private func runCaptureLoop() async {
        while Task.isCancelled == false {
            _ = await performCaptureCycle()
            do {
                try await Task.sleep(for: .seconds(configuration.captureIntervalSeconds))
            } catch {
                break
            }
        }

        captureLoopTask = nil
        isRunning = false
    }

    private func processCapturedWindow(
        _ capturedWindow: CapturedWindow,
        captureTrigger: CaptureTrigger,
        manualComment: String?
    ) async throws -> CaptureCycleOutcome {
        let isUserInitiatedCapture = captureTrigger.isUserInitiated
        let normalizedManualComment = normalizeManualComment(
            captureTrigger: captureTrigger,
            manualComment: manualComment
        )

        let isExcludedApplication = matchesExcludedKeyword(
            capturedWindow.applicationName,
            excludedKeywords: configuration.excludedApplications
        )
        let isExcludedWindowTitle = matchesExcludedKeyword(
            capturedWindow.windowTitle,
            excludedKeywords: configuration.excludedWindowTitles
        )
        if isExcludedApplication || isExcludedWindowTitle {
            let captureRecord = CaptureRecord(
                applicationName: capturedWindow.applicationName,
                windowTitle: capturedWindow.windowTitle,
                capturedAt: capturedWindow.capturedAt,
                ocrText: "",
                hasImage: false,
                imageFormat: nil,
                captureTrigger: captureTrigger,
                comments: normalizedManualComment,
                browserURL: capturedWindow.browserURL,
                documentPath: capturedWindow.documentPath
            )
            try dataStore.saveRecord(captureRecord)
            try dataStore.cleanupExpiredData(referenceDate: dateProvider.now)
            try imageStore.cleanupExpiredImages(referenceDate: dateProvider.now)
            lastErrorDescription = nil
            return .saved(captureRecord)
        }

        let recognizedText: String
        do {
            recognizedText = try await textRecognizer.recognizeText(from: capturedWindow.image)
        } catch {
            guard isUserInitiatedCapture else {
                throw error
            }
            recognizedText = ""
        }
        let normalizedText = normalizeRecognizedText(
            recognizedText,
            isUserInitiatedCapture: isUserInitiatedCapture
        )
        guard normalizedText.isEmpty == false || isUserInitiatedCapture else {
            return .skipped(.shortText)
        }

        if isUserInitiatedCapture {
            _ = await duplicateDetector.shouldStoreText(normalizedText)
        } else {
            let shouldStoreRecord = await duplicateDetector.shouldStoreText(normalizedText)
            guard shouldStoreRecord else {
                return .skipped(.duplicateText)
            }
        }

        let imageData: Data?
        if configuration.shouldSaveImages {
            if let encodedImageData = CaptureImageEncoder.encodeImage(
                capturedWindow.image,
                format: configuration.imageFormat
            ) {
                imageData = encodedImageData
            } else if isUserInitiatedCapture {
                imageData = nil
            } else {
                return .skipped(.imageEncodingFailed)
            }
        } else {
            imageData = nil
        }

        let captureRecord = CaptureRecord(
            applicationName: capturedWindow.applicationName,
            windowTitle: capturedWindow.windowTitle,
            capturedAt: capturedWindow.capturedAt,
            ocrText: normalizedText,
            hasImage: imageData != nil,
            imageFormat: imageData == nil ? nil : configuration.imageFormat,
            captureTrigger: captureTrigger,
            comments: normalizedManualComment,
            browserURL: capturedWindow.browserURL,
            documentPath: capturedWindow.documentPath
        )
        try dataStore.saveRecord(captureRecord)

        if let imageData {
            try imageStore.saveImageData(
                imageData,
                capturedAt: capturedWindow.capturedAt,
                recordID: captureRecord.id,
                imageFormat: configuration.imageFormat
            )
        }

        try dataStore.cleanupExpiredData(referenceDate: dateProvider.now)
        try imageStore.cleanupExpiredImages(referenceDate: dateProvider.now)

        lastErrorDescription = nil
        return .saved(captureRecord)
    }

    private func matchesExcludedKeyword(_ text: String?, excludedKeywords: [String]) -> Bool {
        guard let text else {
            return false
        }
        guard text.isEmpty == false else {
            return false
        }
        return excludedKeywords.contains { excludedKeyword in
            text.range(of: excludedKeyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func normalizeManualComment(captureTrigger: CaptureTrigger, manualComment: String?) -> String? {
        guard captureTrigger != .scheduled else {
            return nil
        }
        return manualComment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizeRecognizedText(
        _ recognizedText: String,
        isUserInitiatedCapture: Bool
    ) -> String {
        let normalizedLines = recognizedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard isUserInitiatedCapture == false else {
            return normalizedLines.joined(separator: "\n")
        }

        let filteredLines = normalizedLines.filter { lineText in
            lineText.count >= configuration.minimumTextLength
        }
        return filteredLines.joined(separator: "\n")
    }
}
