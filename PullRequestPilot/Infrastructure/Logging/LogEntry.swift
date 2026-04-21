import Foundation

struct LogEntry: Sendable, Equatable {
    enum Level: String, Sendable, Equatable {
        case debug
        case info
        case notice
        case error
        case fault
    }

    let date: Date
    let level: Level
    let category: String
    let message: String
}
