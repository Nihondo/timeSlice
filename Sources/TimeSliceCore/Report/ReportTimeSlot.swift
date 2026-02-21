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
    public var label: String
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.isEnabled = isEnabled
    }

    /// Converts to `ReportTimeRange` for record filtering.
    public func toTimeRange() -> ReportTimeRange {
        ReportTimeRange(
            startHour: startHour,
            startMinute: startMinute,
            endHour: endHour,
            endMinute: endMinute
        )
    }

    /// Output file name like "report-0800-1200.md".
    public var outputFileName: String {
        String(format: "report-%02d%02d-%02d%02d.md", startHour, startMinute, endHour, endMinute)
    }

    /// Display label for time range like "08:00-12:00".
    public var timeRangeLabel: String {
        toTimeRange().label
    }

    /// Default time slots: Morning, Afternoon, Evening.
    public static var defaults: [ReportTimeSlot] {
        [
            ReportTimeSlot(
                label: NSLocalizedString("time_slot.morning", value: "午前", comment: ""),
                startHour: 8, startMinute: 0, endHour: 12, endMinute: 0
            ),
            ReportTimeSlot(
                label: NSLocalizedString("time_slot.afternoon", value: "午後", comment: ""),
                startHour: 12, startMinute: 0, endHour: 18, endMinute: 0
            ),
            ReportTimeSlot(
                label: NSLocalizedString("time_slot.evening", value: "夜", comment: ""),
                startHour: 18, startMinute: 0, endHour: 24, endMinute: 0
            ),
        ]
    }
}
