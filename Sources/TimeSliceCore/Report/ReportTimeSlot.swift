import Foundation

/// Time range filter for loading records within a specific time window.
public struct ReportTimeRange: Sendable, Equatable {
    public let startHour: Int
    public let startMinute: Int
    public let endHour: Int
    public let endMinute: Int

    public init(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
    }

    /// Returns whether the given date's time-of-day falls within [start, end).
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let timeValue = hour * 60 + minute
        let startValue = startHour * 60 + startMinute
        let endValue = endHour * 60 + endMinute
        return timeValue >= startValue && timeValue < endValue
    }

    /// Display label like "08:00-12:00".
    public var label: String {
        String(format: "%02d:%02d-%02d:%02d", startHour, startMinute, endHour, endMinute)
    }
}

/// Configurable time slot for periodic report generation.
public struct ReportTimeSlot: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.isEnabled = isEnabled
    }

    /// Decodes from JSON, ignoring unknown keys (e.g. legacy "label" field).
    enum CodingKeys: String, CodingKey {
        case id, startHour, startMinute, endHour, endMinute, isEnabled
    }

    /// Actual execution hour (endHour modulo 24).
    public var executionHour: Int { endHour % 24 }

    /// Actual execution minute.
    public var executionMinute: Int { endMinute }

    /// Whether execution fires on the next calendar day (endHour >= 24).
    public var executionIsNextDay: Bool { endHour >= 24 }

    /// Time range filter for the primary (logical) day: [startHour:startMinute, min(endHour,24):00).
    public var primaryDayTimeRange: ReportTimeRange {
        let clampedEndHour = min(endHour, 24)
        let clampedEndMinute = endHour >= 24 ? 0 : endMinute
        return ReportTimeRange(
            startHour: startHour,
            startMinute: startMinute,
            endHour: clampedEndHour,
            endMinute: clampedEndMinute
        )
    }

    /// Time range filter for the overflow (next calendar) day: [00:00, endHour%24:endMinute).
    /// Returns nil if the slot does not cross midnight.
    public var overflowDayTimeRange: ReportTimeRange? {
        guard executionIsNextDay else { return nil }
        let overflowHour = endHour % 24
        guard overflowHour > 0 || endMinute > 0 else { return nil }
        return ReportTimeRange(
            startHour: 0,
            startMinute: 0,
            endHour: overflowHour,
            endMinute: endMinute
        )
    }

    /// Output file name like "report-0800-1200.md".
    public var outputFileName: String {
        String(format: "report-%02d%02d-%02d%02d.md", startHour, startMinute, endHour, endMinute)
    }

    /// Display label for time range like "08:00-25:00".
    public var timeRangeLabel: String {
        String(format: "%02d:%02d-%02d:%02d", startHour, startMinute, endHour, endMinute)
    }

    /// Default time slots: Full day (enabled) + Morning/Afternoon/Evening (disabled).
    public static var defaults: [ReportTimeSlot] {
        [
            ReportTimeSlot(
                startHour: 8, startMinute: 0, endHour: 25, endMinute: 0, isEnabled: true
            ),
            ReportTimeSlot(
                startHour: 8, startMinute: 0, endHour: 12, endMinute: 0, isEnabled: false
            ),
            ReportTimeSlot(
                startHour: 12, startMinute: 0, endHour: 18, endMinute: 0, isEnabled: false
            ),
            ReportTimeSlot(
                startHour: 18, startMinute: 0, endHour: 25, endMinute: 0, isEnabled: false
            ),
        ]
    }
}
