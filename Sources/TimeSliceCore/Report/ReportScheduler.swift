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
    public let timeSlots: [ReportTimeSlot]
    public let nextExecutionDate: Date?
    public let nextTimeSlotLabel: String?
    public let lastResult: ReportSchedulerResult?

    public init(
        isRunning: Bool,
        isEnabled: Bool,
        hour: Int,
        minute: Int,
        timeSlots: [ReportTimeSlot] = [],
        nextExecutionDate: Date?,
        nextTimeSlotLabel: String? = nil,
        lastResult: ReportSchedulerResult?
    ) {
        self.isRunning = isRunning
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.timeSlots = timeSlots
        self.nextExecutionDate = nextExecutionDate
        self.nextTimeSlotLabel = nextTimeSlotLabel
        self.lastResult = lastResult
    }
}

/// Runs report generation at fixed local times, supporting multiple time slots per day.
public actor ReportScheduler {
    public private(set) var isRunning = false
    public private(set) var lastResult: ReportSchedulerResult?
    public private(set) var nextExecutionDate: Date?
    public private(set) var nextTimeSlot: ReportTimeSlot?

    private let reportGenerator: ReportGenerator
    private let generationConfigurationProvider: (ReportTimeSlot?) -> ReportGenerationConfiguration
    private let reportTargetDateProvider: () -> Date
    private let timeSlotsProvider: () -> [ReportTimeSlot]
    private let dateProvider: any DateProviding
    private let calendar: Calendar

    private var schedulerLoopTask: Task<Void, Never>?
    private var isEnabled: Bool
    private var hour: Int
    private var minute: Int
    private var timeSlots: [ReportTimeSlot]

    public init(
        reportGenerator: ReportGenerator,
        generationConfigurationProvider: @escaping (ReportTimeSlot?) -> ReportGenerationConfiguration,
        reportTargetDateProvider: @escaping () -> Date = { Date() },
        timeSlotsProvider: @escaping () -> [ReportTimeSlot] = { [] },
        dateProvider: any DateProviding = SystemDateProvider(),
        calendar: Calendar = .current,
        isEnabled: Bool = false,
        hour: Int = 18,
        minute: Int = 0,
        timeSlots: [ReportTimeSlot] = []
    ) {
        self.reportGenerator = reportGenerator
        self.generationConfigurationProvider = generationConfigurationProvider
        self.reportTargetDateProvider = reportTargetDateProvider
        self.timeSlotsProvider = timeSlotsProvider
        self.dateProvider = dateProvider
        self.calendar = calendar
        self.isEnabled = isEnabled
        self.hour = Self.clampHour(hour)
        self.minute = Self.clampMinute(minute)
        self.timeSlots = timeSlots
    }

    /// Starts scheduling loop if auto generation is enabled.
    public func start() {
        guard schedulerLoopTask == nil else {
            return
        }
        guard isEnabled else {
            isRunning = false
            nextExecutionDate = nil
            nextTimeSlot = nil
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
        nextTimeSlot = nil
    }

    /// Updates auto-generation schedule and restarts loop when necessary.
    public func updateSchedule(
        isEnabled: Bool,
        hour: Int,
        minute: Int,
        timeSlots: [ReportTimeSlot] = []
    ) {
        self.isEnabled = isEnabled
        self.hour = Self.clampHour(hour)
        self.minute = Self.clampMinute(minute)
        self.timeSlots = timeSlots

        restartSchedulerLoop()
    }

    /// Returns current scheduler state.
    public func snapshot() -> ReportSchedulerState {
        ReportSchedulerState(
            isRunning: isRunning,
            isEnabled: isEnabled,
            hour: hour,
            minute: minute,
            timeSlots: timeSlots,
            nextExecutionDate: nextExecutionDate,
            nextTimeSlotLabel: nextTimeSlot?.label,
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
            let enabledSlots = timeSlotsProvider().filter(\.isEnabled)

            let (scheduledDate, matchedSlot): (Date, ReportTimeSlot?)
            if enabledSlots.isEmpty {
                scheduledDate = calculateNextExecutionDate(from: referenceDate)
                matchedSlot = nil
            } else {
                guard let result = calculateNextSlotExecution(from: referenceDate, slots: enabledSlots) else {
                    scheduledDate = calculateNextExecutionDate(from: referenceDate)
                    matchedSlot = nil
                    break
                }
                scheduledDate = result.date
                matchedSlot = result.slot
            }

            nextExecutionDate = scheduledDate
            nextTimeSlot = matchedSlot

            do {
                try await waitUntilExecutionDate(scheduledDate, referenceDate: referenceDate)
            } catch {
                break
            }
            guard Task.isCancelled == false, isEnabled else {
                break
            }

            lastResult = await executeScheduledReportGeneration(timeSlot: matchedSlot)
        }

        schedulerLoopTask = nil
        isRunning = false
        nextExecutionDate = nil
        nextTimeSlot = nil
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

    private struct SlotExecution {
        let date: Date
        let slot: ReportTimeSlot
    }

    private func calculateNextSlotExecution(
        from referenceDate: Date,
        slots: [ReportTimeSlot]
    ) -> SlotExecution? {
        var bestExecution: SlotExecution?

        for slot in slots {
            let executionHour = slot.endHour == 24 ? 0 : slot.endHour
            let executionMinute = slot.endHour == 24 ? 0 : slot.endMinute

            var dayComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            dayComponents.hour = executionHour
            dayComponents.minute = executionMinute
            dayComponents.second = 0

            var candidateDate = calendar.date(from: dayComponents) ?? referenceDate

            // If end is 24:00, the execution is at 00:00 next day
            if slot.endHour == 24 {
                candidateDate = calendar.date(byAdding: .day, value: 1, to: candidateDate) ?? candidateDate
            }

            // If already past, schedule for tomorrow
            if candidateDate <= referenceDate {
                candidateDate = calendar.date(byAdding: .day, value: 1, to: candidateDate)
                    ?? candidateDate.addingTimeInterval(60 * 60 * 24)
            }

            if bestExecution == nil || candidateDate < bestExecution!.date {
                bestExecution = SlotExecution(date: candidateDate, slot: slot)
            }
        }

        return bestExecution
    }

    private func waitUntilExecutionDate(_ executionDate: Date, referenceDate: Date) async throws {
        let waitSeconds = executionDate.timeIntervalSince(referenceDate)
        guard waitSeconds > 0 else {
            return
        }
        try await Task.sleep(for: .seconds(waitSeconds))
    }

    private func executeScheduledReportGeneration(timeSlot: ReportTimeSlot?) async -> ReportSchedulerResult {
        do {
            let targetDate = reportTargetDateProvider()
            let generationConfiguration = generationConfigurationProvider(timeSlot)
            let timeRange = timeSlot?.toTimeRange()
            let generatedReport = try await reportGenerator.generateReport(
                on: targetDate,
                configuration: generationConfiguration,
                timeRange: timeRange
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
