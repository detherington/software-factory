import Foundation

/// Dates in the board's JSON, to the millisecond: "2026-10-28T14:03:12.481Z". Whole seconds weren't
/// enough: two Macs changing the same to-do in one second tied, and each kept its own. Dates written
/// before, in whole seconds, still read.
nonisolated enum JSONDates {
    private static let style = Date.ISO8601FormatStyle.iso8601.year().month().day()
        .time(includingFractionalSeconds: true).timeZone(separator: .omitted)

    static let encoding = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(date.formatted(style))
    }

    static let decoding = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        if let date = try? Date(text, strategy: style) { return date }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
    }
}
