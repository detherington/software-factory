import Foundation

/// What one day of a session came to: Claude's working time, turns and tokens.
struct Usage: Codable, Hashable, Sendable {
    /// Time Claude spent on your turns.
    var seconds: Double = 0
    var turns = 0
    /// The day's longest turn.
    var longestTurn: Double = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    /// Every token: read (fresh and from the cache) and written.
    var tokens: Int { input + output + cacheRead + cacheWrite }

    static func + (a: Usage, b: Usage) -> Usage {
        Usage(seconds: a.seconds + b.seconds, turns: a.turns + b.turns, longestTurn: max(a.longestTurn, b.longestTurn),
              input: a.input + b.input, output: a.output + b.output,
              cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    static func += (a: inout Usage, b: Usage) { a = a + b }
}

/// One transcript in ~/.claude/projects, added up by day, and where reading it stopped. Transcripts
/// only grow, so each read picks up from the last; Claude Code deletes old ones, but what they added
/// up to is kept.
///
/// Working time is the time between your message and Claude's last reply in each turn, from the
/// timestamps of everything in between. It leaves out the wait for you (before your message, and while
/// a question or a plan waits for your answer), and counts at most 30 minutes for any one step, so a
/// permission prompt left overnight doesn't count as work. A subagent's transcript adds its tokens; its
/// time is already its session's.
///
/// Lines are read as bytes, not parsed: transcripts run to gigabytes, mostly tool output, and only a
/// few fields of each line matter.
struct TranscriptTally: Codable, Sendable {
    var session: String
    /// The project folder it ran in (worktrees folded in).
    var root: String?
    var isAgent: Bool
    /// "2026-10-28": what each day came to.
    var days: [String: Usage] = [:]

    // Where reading stopped.
    var offset: UInt64 = 0
    var last: Date?
    var turnStart: Date?
    var turnSeconds: Double = 0
    var waitingOnYou = false
    var lastMessage: String?

    init(session: String, root: String?, isAgent: Bool) {
        self.session = session
        self.root = root
        self.isAgent = isAgent
    }

    /// The most one step can count.
    static let stepCap: Double = 30 * 60

    /// Reads what was added since last time: complete lines only.
    mutating func read(_ url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
        if UInt64(data.count) < offset {
            // Shorter than before: rewritten, so start again.
            self = TranscriptTally(session: session, root: root, isAgent: isAgent)
        }
        guard UInt64(data.count) > offset else { return }
        var keys = DayKeys()
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var start = Int(offset)
            while start < raw.count, let newline = memchr(base + start, 0x0A, raw.count - start) {
                let end = base.distance(to: UnsafeRawPointer(newline))
                if end > start { line(base + start, end - start, keys: &keys) }
                start = end + 1
            }
            offset = UInt64(start)
        }
    }

    // MARK: - One line

    private mutating func line(_ p: UnsafeRawPointer, _ n: Int, keys: inout DayKeys) {
        // A line's type and flags come first, its timestamp and usage last, with any amount between.
        let head = min(n, 2048)
        let tail = max(0, n - 8192)
        guard let stamp = Bytes.find(Bytes.timestamp, in: p + tail, n - tail).map({ $0 + tail })
                ?? (tail > 0 ? Bytes.find(Bytes.timestamp, in: p, tail) : nil),
              let date = Bytes.date(p + stamp + Bytes.timestamp.count, n - stamp - Bytes.timestamp.count) else { return }
        let sidechain = Bytes.find(Bytes.sidechain, in: p, head) != nil

        if Bytes.find(Bytes.user, in: p, head) != nil {
            guard !isAgent, !sidechain else { return }
            if Bytes.find(Bytes.toolResult, in: p, head) != nil || Bytes.find(Bytes.toolResultType, in: p, head) != nil {
                // A tool finished, or you answered a question.
                step(to: date, counts: !waitingOnYou, keys: &keys)
                waitingOnYou = false
            } else if Bytes.find(Bytes.meta, in: p, head) != nil || Bytes.find(Bytes.compactSummary, in: p, n) != nil {
                // A note the app adds, or the summary that carries a turn on after compacting.
                step(to: date, counts: true, keys: &keys)
            } else if Bytes.find(Bytes.interrupted, in: p, head) != nil {
                step(to: date, counts: true, keys: &keys)
                endTurn(keys: &keys)
            } else {
                // A message starts a turn: yours, or one the app sends when background work ends.
                endTurn(keys: &keys)
                turnStart = date
                turnSeconds = 0
                days[keys.key(for: date), default: Usage()].turns += 1
                if date > (last ?? .distantPast) { last = date }
            }
        } else if Bytes.find(Bytes.assistant, in: p + tail, n - tail) != nil {
            tokens(p, n, head: head, tail: tail, day: keys.key(for: date))
            guard !isAgent, !sidechain else { return }
            step(to: date, counts: true, keys: &keys)
            if Bytes.find(Bytes.askUser, in: p, n) != nil || Bytes.find(Bytes.exitPlan, in: p, n) != nil { waitingOnYou = true }
            if Bytes.find(Bytes.endTurn, in: p + tail, n - tail) != nil || Bytes.find(Bytes.apiError, in: p + tail, n - tail) != nil {
                endTurn(keys: &keys)
            }
        } else if !isAgent {
            // Hooks, attachments, requests: steps within a turn.
            step(to: date, counts: true, keys: &keys)
        }
    }

    /// The time since the last line, while a turn is going on.
    private mutating func step(to date: Date, counts: Bool, keys: inout DayKeys) {
        guard let previous = last, date > previous else {
            if last == nil { last = date }
            return
        }
        last = date
        guard turnStart != nil, counts else { return }
        let gap = min(date.timeIntervalSince(previous), Self.stepCap)
        days[keys.key(for: date), default: Usage()].seconds += gap
        turnSeconds += gap
    }

    private mutating func endTurn(keys: inout DayKeys) {
        guard let start = turnStart else { return }
        let day = keys.key(for: start)
        days[day, default: Usage()].longestTurn = max(days[day]?.longestTurn ?? 0, turnSeconds)
        turnStart = nil
        turnSeconds = 0
        waitingOnYou = false
    }

    /// A reply's tokens, once: a reply is written as several lines, each with the same usage.
    private mutating func tokens(_ p: UnsafeRawPointer, _ n: Int, head: Int, tail: Int, day: String) {
        if let at = Bytes.find(Bytes.messageID, in: p, head) {
            let id = Bytes.string(p + at + Bytes.messageID.count, n - at - Bytes.messageID.count)
            guard id != lastMessage else { return }
            lastMessage = id
        }
        guard let at = Bytes.find(Bytes.usage, in: p + tail, n - tail).map({ $0 + tail }) ?? Bytes.find(Bytes.usage, in: p, n) else { return }
        // The first of each count after "usage" is the reply's own; per-iteration counts follow.
        let q = p + at
        let length = min(1500, n - at)
        var usage = days[day, default: Usage()]
        usage.input += Bytes.int(after: Bytes.inputTokens, in: q, length)
        usage.output += Bytes.int(after: Bytes.outputTokens, in: q, length)
        usage.cacheRead += Bytes.int(after: Bytes.cacheRead, in: q, length)
        usage.cacheWrite += Bytes.int(after: Bytes.cacheWrite, in: q, length)
        days[day] = usage
    }
}

/// "2026-10-28" for a moment, in this Mac's time zone.
struct DayKeys {
    private let zone = TimeZone.current
    private var cache: [Int: String] = [:]

    mutating func key(for date: Date) -> String {
        let local = date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))
        let day = Int((local / 86_400).rounded(.down))
        if let key = cache[day] { return key }
        let key = Self.string(day)
        cache[day] = key
        return key
    }

    /// Days since 1970-01-01 as "yyyy-MM-dd" (Howard Hinnant's civil-from-days).
    static func string(_ days: Int) -> String {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// The days since 1970-01-01 for a date's year, month and day.
    static func number(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

/// Byte-level reading of transcript lines.
nonisolated enum Bytes {
    static let timestamp = Array(#""timestamp":""#.utf8)
    static let sidechain = Array(#""isSidechain":true"#.utf8)
    static let user = Array(#""type":"user""#.utf8)
    static let assistant = Array(#""type":"assistant""#.utf8)
    static let toolResult = Array(#""tool_use_id":""#.utf8)
    static let toolResultType = Array(#""type":"tool_result""#.utf8)
    static let meta = Array(#""isMeta":true"#.utf8)
    static let compactSummary = Array(#""isCompactSummary":true"#.utf8)
    static let interrupted = Array("[Request interrupted by user".utf8)
    static let askUser = Array(#""name":"AskUserQuestion""#.utf8)
    static let exitPlan = Array(#""name":"ExitPlanMode""#.utf8)
    static let endTurn = Array(#""stop_reason":"end_turn""#.utf8)
    static let apiError = Array(#""isApiErrorMessage":true"#.utf8)
    static let messageID = Array(#""id":"msg_"#.utf8)
    static let usage = Array(#""usage":{"#.utf8)
    static let inputTokens = Array(#""input_tokens":"#.utf8)
    static let outputTokens = Array(#""output_tokens":"#.utf8)
    static let cacheRead = Array(#""cache_read_input_tokens":"#.utf8)
    static let cacheWrite = Array(#""cache_creation_input_tokens":"#.utf8)

    static func find(_ needle: [UInt8], in p: UnsafeRawPointer, _ n: Int) -> Int? {
        guard n >= needle.count else { return nil }
        return needle.withUnsafeBytes { needle in
            memmem(p, n, needle.baseAddress, needle.count).map { p.distance(to: UnsafeRawPointer($0)) }
        }
    }

    /// The string up to the closing quote.
    static func string(_ p: UnsafeRawPointer, _ n: Int) -> String? {
        let limit = min(n, 120)
        guard let quote = memchr(p, 0x22, limit) else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: p.distance(to: UnsafeRawPointer(quote))), as: UTF8.self)
    }

    /// The whole number after a key, or 0.
    static func int(after key: [UInt8], in p: UnsafeRawPointer, _ n: Int) -> Int {
        guard let at = find(key, in: p, n) else { return 0 }
        var value = 0
        var i = at + key.count
        while i < n {
            let c = p.load(fromByteOffset: i, as: UInt8.self)
            guard c >= 0x30, c <= 0x39 else { break }
            value = value * 10 + Int(c - 0x30)
            i += 1
        }
        return value
    }

    /// "2026-10-28T12:34:56.789Z".
    static func date(_ p: UnsafeRawPointer, _ n: Int) -> Date? {
        guard n >= 20 else { return nil }
        func digits(_ at: Int, _ count: Int) -> Int? {
            var value = 0
            for i in at..<(at + count) {
                let c = p.load(fromByteOffset: i, as: UInt8.self)
                guard c >= 0x30, c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            return value
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2) else { return nil }
        var fraction = 0.0
        if n >= 23, p.load(fromByteOffset: 19, as: UInt8.self) == 0x2E, let millis = digits(20, 3) { fraction = Double(millis) / 1000 }
        let days = DayKeys.number(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3600 + minute * 60 + second) + fraction)
    }
}
