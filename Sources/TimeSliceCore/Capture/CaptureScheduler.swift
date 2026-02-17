import Foundation

public struct CaptureSchedulerConfiguration: Sendable {
    public let captureIntervalSeconds: TimeInterval
    public let minimumTextLength: Int
    public let shouldSaveImages: Bool

    public init(
        captureIntervalSeconds: TimeInterval = 60,
        minimumTextLength: Int = 10,
        shouldSaveImages: Bool = true
    ) {
        self.captureIntervalSeconds = captureIntervalSeconds
        self.minimumTextLength = minimumTextLength
        self.shouldSaveImages = shouldSaveImages
    }
}

public enum CaptureSkipReason: String, Sendable {
    case noWindow
    case shortText
    case duplicateText
    case pngEncodingFailed
}

public enum CaptureCycleOutcome: Sendable {
    case saved(CaptureRecord)
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
    public func performCaptureCycle() async -> CaptureCycleOutcome {
        do {
            guard let capturedWindow = try await screenCapturer.captureFrontWindow() else {
                return .skipped(.noWindow)
            }

            let recognizedText = try await textRecognizer.recognizeText(from: capturedWindow.image)
            let normalizedText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedText.count >= configuration.minimumTextLength else {
                return .skipped(.shortText)
            }

            let shouldStoreRecord = await duplicateDetector.shouldStoreText(normalizedText)
            guard shouldStoreRecord else {
                return .skipped(.duplicateText)
            }

            let imageData: Data?
            if configuration.shouldSaveImages {
                guard let encodedImageData = PNGImageEncoder.encodeImage(capturedWindow.image) else {
                    return .skipped(.pngEncodingFailed)
                }
                imageData = encodedImageData
            } else {
                imageData = nil
            }

            let captureRecord = CaptureRecord(
                applicationName: capturedWindow.applicationName,
                windowTitle: capturedWindow.windowTitle,
                capturedAt: capturedWindow.capturedAt,
                ocrText: normalizedText,
                hasImage: imageData != nil
            )
            try dataStore.saveRecord(captureRecord)

            if let imageData {
                try imageStore.saveImageData(
                    imageData,
                    capturedAt: capturedWindow.capturedAt,
                    recordID: captureRecord.id
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
}
