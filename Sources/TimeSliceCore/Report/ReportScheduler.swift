import Foundation

/// Result of one scheduled report generation execution.
public enum ReportSchedulerResult: Sendable {
    case succeeded(GeneratedReport)
    case skippedNoRecords(Date)
    case failed(String)
}

/// Immutable scheduler snapshot for UI or diagnostics.
public struct ReportSchedulerState: Sendable {
    public let isRunning: Bool
    public let isEnabled: Bool
    public let hour: Int
    public let minute: Int
    public let nextExecutionDate: Date?
    public let lastResult: ReportSchedulerResult?

    public init(
        isRunning: Bool,
        isEnabled: Bool,
        hour: Int,
        minute: Int,
        nextExecutionDate: Date?,
        lastResult: ReportSchedulerResult?
    ) {
        self.isRunning = isRunning
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.nextExecutionDate = nextExecutionDate
        self.lastResult = lastResult
    }
}

/// Runs daily report generation at a fixed local time.
public actor ReportScheduler {
    public private(set) var isRunning = false
    public private(set) var lastResult: ReportSchedulerResult?
    public private(set) var nextExecutionDate: Date?

    private let reportGenerator: ReportGenerator
    private let generationConfigurationProvider: () -> ReportGenerationConfiguration
    private let reportTargetDateProvider: () -> Date
    private let dateProvider: any DateProviding
    private let calendar: Calendar

    private var schedulerLoopTask: Task<Void, Never>?
    private var isEnabled: Bool
    private var hour: Int
    private var minute: Int

    public init(
        reportGenerator: ReportGenerator,
        generationConfigurationProvider: @escaping () -> ReportGenerationConfiguration,
        reportTargetDateProvider: @escaping () -> Date = { Date() },
        dateProvider: any DateProviding = SystemDateProvider(),
        calendar: Calendar = .current,
        isEnabled: Bool = false,
        hour: Int = 18,
        minute: Int = 0
    ) {
        self.reportGenerator = reportGenerator
        self.generationConfigurationProvider = generationConfigurationProvider
        self.reportTargetDateProvider = reportTargetDateProvider
        self.dateProvider = dateProvider
        self.calendar = calendar
        self.isEnabled = isEnabled
        self.hour = Self.clampHour(hour)
        self.minute = Self.clampMinute(minute)
    }

    /// Starts scheduling loop if auto generation is enabled.
    public func start() {
        guard schedulerLoopTask == nil else {
            return
        }
        guard isEnabled else {
            isRunning = false
            nextExecutionDate = nil
            return
        }

        isRunning = true
        schedulerLoopTask = Task {
            await runSchedulerLoop()
        }
    }

    /// Stops scheduling loop.
    public func stop() {
        schedulerLoopTask?.cancel()
        schedulerLoopTask = nil
        isRunning = false
        nextExecutionDate = nil
    }

    /// Updates auto-generation schedule and restarts loop when necessary.
    public func updateSchedule(isEnabled: Bool, hour: Int, minute: Int) {
        self.isEnabled = isEnabled
        self.hour = Self.clampHour(hour)
        self.minute = Self.clampMinute(minute)

        restartSchedulerLoop()
    }

    /// Returns current scheduler state.
    public func snapshot() -> ReportSchedulerState {
        ReportSchedulerState(
            isRunning: isRunning,
            isEnabled: isEnabled,
            hour: hour,
            minute: minute,
            nextExecutionDate: nextExecutionDate,
            lastResult: lastResult
        )
    }

    private func restartSchedulerLoop() {
        stop()
        guard isEnabled else {
            return
        }
        start()
    }

    private func runSchedulerLoop() async {
        while Task.isCancelled == false, isEnabled {
            let referenceDate = dateProvider.now
            let scheduledDate = calculateNextExecutionDate(from: referenceDate)
            nextExecutionDate = scheduledDate

            do {
                try await waitUntilExecutionDate(scheduledDate, referenceDate: referenceDate)
            } catch {
                break
            }
            guard Task.isCancelled == false, isEnabled else {
                break
            }

            lastResult = await executeScheduledReportGeneration()
        }

        schedulerLoopTask = nil
        isRunning = false
        nextExecutionDate = nil
    }

    private func calculateNextExecutionDate(from referenceDate: Date) -> Date {
        var dayComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        dayComponents.hour = hour
        dayComponents.minute = minute
        dayComponents.second = 0

        let todayCandidate = calendar.date(from: dayComponents) ?? referenceDate
        if todayCandidate > referenceDate {
            return todayCandidate
        }

        let tomorrowCandidate = calendar.date(byAdding: .day, value: 1, to: todayCandidate)
        return tomorrowCandidate ?? todayCandidate.addingTimeInterval(60 * 60 * 24)
    }

    private func waitUntilExecutionDate(_ executionDate: Date, referenceDate: Date) async throws {
        let waitSeconds = executionDate.timeIntervalSince(referenceDate)
        guard waitSeconds > 0 else {
            return
        }
        try await Task.sleep(for: .seconds(waitSeconds))
    }

    private func executeScheduledReportGeneration() async -> ReportSchedulerResult {
        do {
            let targetDate = reportTargetDateProvider()
            let generationConfiguration = generationConfigurationProvider()
            let generatedReport = try await reportGenerator.generateReport(
                on: targetDate,
                configuration: generationConfiguration
            )
            return .succeeded(generatedReport)
        } catch let reportError as ReportGenerationError {
            if case let .noRecords(targetDate) = reportError {
                return .skippedNoRecords(targetDate)
            }
            return .failed(reportError.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func clampHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }

    private static func clampMinute(_ minute: Int) -> Int {
        min(max(minute, 0), 59)
    }
}
