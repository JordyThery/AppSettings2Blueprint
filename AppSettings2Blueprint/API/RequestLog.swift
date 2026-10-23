import Foundation
import Observation

/// One logged HTTP exchange. Secrets are redacted before an entry is created.
nonisolated struct RequestLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let method: String
    let url: String
    let requestHeaders: [(String, String)]
    let requestBody: String?
    var statusCode: Int?
    var responseHeaders: [(String, String)]
    var responseBody: String?
    var errorDescription: String?
    var duration: TimeInterval?
    var attempt: Int
}

/// In-memory log shown in the Request Log window.
@Observable
final class RequestLog {
    private(set) var entries: [RequestLogEntry] = []
    private let maxEntries = 500

    func append(_ entry: RequestLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
