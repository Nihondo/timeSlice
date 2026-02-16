import Foundation

/// Provides the current date for storage cleanup and scheduling logic.
public protocol DateProviding: Sendable {
    var now: Date { get }
}

/// Uses system clock as the current date source.
public struct SystemDateProvider: DateProviding {
    public init() {}

    public var now: Date {
        Date()
    }
}
