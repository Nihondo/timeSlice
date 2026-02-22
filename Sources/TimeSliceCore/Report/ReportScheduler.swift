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
    public let timeSlots: [ReportTimeSlot]
    public let nextExecutionDate: Date?
    public let nextTimeSlotRangeLabel: String?
    public let lastResult: ReportSchedulerResult?
    public let lastResultSequence: UInt64

    public init(
        isRunning: Bool,
        isEnabled: Bool,
        timeSlots: [ReportTimeSlot] = [],
        nextExecutionDate: Date?,
        nextTimeSlotRangeLabel: String? = nil,
        lastResult: ReportSchedulerResult?,
        lastResultSequence: UInt64 = 0
    ) {
        self.isRunning = isRunning
        self.isEnabled = isEnabled
        self.timeSlots = timeSlots
        self.nextExecutionDate = nextExecutionDate
        self.nextTimeSlotRangeLabel = nextTimeSlotRangeLabel
        self.lastResult = lastResult
        self.lastResultSequence = lastResultSequence
    }
}

/// Runs report generation at fixed local times using time slots.
public actor ReportScheduler {
    public private(set) var isRunning = false
    public private(set) var lastResult: ReportSchedulerResult?
    public private(set) var lastResultSequence: UInt64 = 0
    public private(set) var nextExecutionDate: Date?
    public private(set) var nextTimeSlot: ReportTimeSlot?

    private let reportGenerator: ReportGenerator
    private let generationConfigurationProvider: (ReportTimeSlot, Bool) -> ReportGenerationConfiguration
    private let dateProvider: any DateProviding
    private let calendar: Calendar

    private var schedulerLoopTask: Task<Void, Never>?
    private var schedulerLoopGeneration: UInt64 = 0
    private var isEnabled: Bool
    private var timeSlots: [ReportTimeSlot]

    /// Creates a new report scheduler.
    /// - Parameters:
    ///   - generationConfigurationProvider: Returns configuration for a time slot.
    ///     The Bool parameter indicates whether the slot is the only enabled slot (for output file naming).
    public init(
        reportGenerator: ReportGenerator,
        generationConfigurationProvider: @escaping (ReportTimeSlot, Bool) -> ReportGenerationConfiguration,
        dateProvider: any DateProviding = SystemDateProvider(),
        calendar: Calendar = .current,
        isEnabled: Bool = false,
        timeSlots: [ReportTimeSlot] = []
    ) {
        self.reportGenerator = reportGenerator
        self.generationConfigurationProvider = generationConfigurationProvider
        self.dateProvider = dateProvider
        self.calendar = calendar
        self.isEnabled = isEnabled
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

        startSchedulerLoop()
    }

    /// Stops scheduling loop.
    public func stop() {
        invalidateSchedulerLoop()
        isRunning = false
        nextExecutionDate = nil
        nextTimeSlot = nil
    }

    /// Updates auto-generation schedule and restarts loop when necessary.
    public func updateSchedule(
        isEnabled: Bool,
        timeSlots: [ReportTimeSlot] = []
    ) {
        self.isEnabled = isEnabled
        self.timeSlots = timeSlots

        restartSchedulerLoop()
    }

    /// Returns current scheduler state.
    public func snapshot() -> ReportSchedulerState {
        ReportSchedulerState(
            isRunning: isRunning,
            isEnabled: isEnabled,
            timeSlots: timeSlots,
            nextExecutionDate: nextExecutionDate,
            nextTimeSlotRangeLabel: nextTimeSlot?.timeRangeLabel,
            lastResult: lastResult,
            lastResultSequence: lastResultSequence
        )
    }

    private func restartSchedulerLoop() {
        invalidateSchedulerLoop()

        guard isEnabled else {
            isRunning = false
            nextExecutionDate = nil
            nextTimeSlot = nil
            return
        }

        startSchedulerLoop()
    }

    private func startSchedulerLoop() {
        schedulerLoopGeneration &+= 1
        let loopGeneration = schedulerLoopGeneration
        updateNextExecutionPreview(referenceDate: dateProvider.now)
        isRunning = true
        schedulerLoopTask = Task {
            await runSchedulerLoop(loopGeneration: loopGeneration)
        }
    }

    private func invalidateSchedulerLoop() {
        schedulerLoopGeneration &+= 1
        schedulerLoopTask?.cancel()
        schedulerLoopTask = nil
    }

    private func runSchedulerLoop(loopGeneration: UInt64) async {
        while Task.isCancelled == false, isEnabled {
            guard loopGeneration == schedulerLoopGeneration else {
                break
            }

            let referenceDate = dateProvider.now
            let enabledSlots = timeSlots.filter(\.isEnabled)

            guard let result = calculateNextSlotExecution(from: referenceDate, slots: enabledSlots) else {
                break
            }

            nextExecutionDate = result.date
            nextTimeSlot = result.slot

            do {
                try await waitUntilExecutionDate(result.date, referenceDate: referenceDate)
            } catch {
                break
            }
            guard Task.isCancelled == false, isEnabled else {
                break
            }

            let currentEnabledSlots = timeSlots.filter(\.isEnabled)
            let isSoleEnabledSlot = currentEnabledSlots.count == 1
            let executionResult = await executeScheduledReportGeneration(
                timeSlot: result.slot,
                isSoleEnabledSlot: isSoleEnabledSlot
            )
            lastResult = executionResult
            lastResultSequence &+= 1
        }

        guard loopGeneration == schedulerLoopGeneration else {
            return
        }
        schedulerLoopTask = nil
        isRunning = false
        nextExecutionDate = nil
        nextTimeSlot = nil
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
            let executionHour = slot.executionHour
            let executionMinute = slot.executionMinute

            var dayComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            dayComponents.hour = executionHour
            dayComponents.minute = executionMinute
            dayComponents.second = 0

            var candidateDate = calendar.date(from: dayComponents) ?? referenceDate

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

    private func updateNextExecutionPreview(referenceDate: Date) {
        let enabledSlots = timeSlots.filter(\.isEnabled)
        guard let nextExecution = calculateNextSlotExecution(from: referenceDate, slots: enabledSlots) else {
            nextExecutionDate = nil
            nextTimeSlot = nil
            return
        }
        nextExecutionDate = nextExecution.date
        nextTimeSlot = nextExecution.slot
    }

    private func executeScheduledReportGeneration(
        timeSlot: ReportTimeSlot,
        isSoleEnabledSlot: Bool
    ) async -> ReportSchedulerResult {
        do {
            let executionDate = dateProvider.now
            let targetDate: Date
            if timeSlot.executionIsNextDay {
                targetDate = calendar.date(byAdding: .day, value: -1, to: executionDate) ?? executionDate
            } else {
                targetDate = executionDate
            }

            let generationConfiguration = generationConfigurationProvider(timeSlot, isSoleEnabledSlot)
            let generatedReport = try await reportGenerator.generateReport(
                for: timeSlot,
                targetDate: targetDate,
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
}
