import Foundation

/// A single server-sent event as emitted by the Anthropic streaming API.
public struct ServerSentEvent: Equatable, Sendable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental SSE parser. Feed raw text chunks as they arrive off the wire
/// (chunk boundaries need not align with lines or events).
public struct SSEParser: Sendable {
    private var lineBuffer = ""
    private var currentEvent: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feed a chunk; returns any events completed by it.
    public mutating func feed(_ chunk: String) -> [ServerSentEvent] {
        lineBuffer += chunk
        var events: [ServerSentEvent] = []

        while let line = nextLine() {
            if line.isEmpty {
                if !dataLines.isEmpty {
                    events.append(ServerSentEvent(event: currentEvent, data: dataLines.joined(separator: "\n")))
                }
                currentEvent = nil
                dataLines = []
            } else if line.hasPrefix(":") {
                continue // comment / keep-alive
            } else if let value = value(of: "event", in: line) {
                currentEvent = value
            } else if let value = value(of: "data", in: line) {
                dataLines.append(value)
            }
        }
        return events
    }

    /// Pops the next complete line from the buffer, stripping a trailing CR.
    ///
    /// Scans `unicodeScalars` rather than the String itself: Swift treats CRLF
    /// as a single grapheme cluster, so `range(of: "\n")` does not match inside
    /// it and a CRLF stream would never yield a line.
    private mutating func nextLine() -> String? {
        let scalars = lineBuffer.unicodeScalars
        guard let newline = scalars.firstIndex(of: "\n") else { return nil }
        var lineScalars = scalars[scalars.startIndex..<newline]
        if lineScalars.last == "\r" { lineScalars = lineScalars.dropLast() }
        lineBuffer = String(scalars[scalars.index(after: newline)...])
        return String(lineScalars)
    }

    private func value(of field: String, in line: String) -> String? {
        guard line.hasPrefix("\(field):") else { return nil }
        var value = String(line.dropFirst(field.count + 1))
        if value.hasPrefix(" ") { value.removeFirst() }
        return value
    }
}
