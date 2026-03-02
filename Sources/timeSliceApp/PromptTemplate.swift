import Foundation

/// A named prompt template for report generation.
struct PromptTemplate: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var template: String

    init(id: UUID = UUID(), name: String, template: String) {
        self.id = id
        self.name = name
        self.template = template
    }
}

/// A named CLI profile for report generation.
struct ReportCLIProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var command: String
    var argumentsText: String

    init(id: UUID = UUID(), name: String, command: String, argumentsText: String) {
        self.id = id
        self.name = name
        self.command = command
        self.argumentsText = argumentsText
    }
}
