import Foundation
import Observation
import OSLog

/// The morning digest: once a day, at a time you choose, a notification with the days since the
/// last one in numbers (from the Passport) and what's been left (questions, loose ends, old to-dos),
/// with the Today screen behind it.
///
/// It waits until you're at the Mac, so it arrives when you sit down, and only one Mac sends each
/// day's: the others hear through iCloud Drive that it went out.
@MainActor
@Observable
final class DigestStore {
    static let shared = DigestStore()

    var isOn = UserDefaults.standard.object(forKey: "FactoryDigest") == nil || UserDefaults.standard.bool(forKey: "FactoryDigest") {
        didSet { UserDefaults.standard.set(isOn, forKey: "FactoryDigest") }
    }
    /// Minutes after midnight: 9:00 by default.
    var minutes = UserDefaults.standard.object(forKey: "FactoryDigestMinutes") == nil ? 9 * 60 : UserDefaults.standard.integer(forKey: "FactoryDigestMinutes") {
        didSet { UserDefaults.standard.set(minutes, forKey: "FactoryDigestMinutes") }
    }
    var weekdaysOnly = UserDefaults.standard.bool(forKey: "FactoryDigestWeekdays") {
        didSet { UserDefaults.standard.set(weekdaysOnly, forKey: "FactoryDigestWeekdays") }
    }

    private(set) var state = DigestState()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isSending = false
    @ObservationIgnored private let log = Logger(subsystem: "com.darrell.softwarefactory", category: "digest")
    /// `-FactoryDigestIgnoresPresence YES`: send without waiting for you to be at the Mac (for testing).
    @ObservationIgnored private let ignoresPresence = UserDefaults.standard.bool(forKey: "FactoryDigestIgnoresPresence")

    private var fileURL: URL { ProjectStore.shared.dataDirectory.appending(path: "digest.json") }

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? ProjectStore.decoder.decode(DigestState.self, from: data) {
            state = saved
        }
    }

    /// The time it comes, as a date today, for a time picker.
    var time: Date {
        get { Calendar.current.date(byAdding: .minute, value: minutes, to: Calendar.current.startOfDay(for: .now)) ?? .now }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            minutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
        }
    }

    // MARK: - What it says

    /// Today's digest: the one sent today, or the one that's coming.
    func digest(now: Date) -> Digest {
        let store = ProjectStore.shared
        let days = coveredDays(now: now)
        let found = Digest.nudges(in: Array(store.projects.values), now: now) { store.chat(for: $0)?.isArchived == true }
        func live(_ nudges: [Nudge]) -> [Nudge] { nudges.filter { !isSnoozed($0, now: now) } }
        var keys = DayKeys()
        let record = state.record.flatMap { $0.day == keys.key(for: now) ? $0 : nil }
        return Digest(days: days, summary: PassportStore.shared.summary(of: days, now: now),
                      waiting: live(found.waiting), looseEnds: live(found.looseEnds), todos: live(found.todos),
                      snoozed: (found.waiting + found.looseEnds + found.todos).filter { isSnoozed($0, now: now) },
                      sent: record?.sent, names: store.projects.mapValues(\.name))
    }

    /// The days the digest covers: those since the last one (a week at most), through yesterday; or,
    /// once today's has gone out, the days it covered.
    private func coveredDays(now: Date) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var keys = DayKeys()
        let todayKey = keys.key(for: today)
        let recent = (1...7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let days: [Date]
        if let record = state.record, record.day == todayKey {
            days = recent.filter { day in
                let key = keys.key(for: day)
                return key >= record.from && key <= record.through
            }
        } else if let record = state.record {
            days = recent.filter { keys.key(for: $0) > record.through }
        } else {
            days = []
        }
        return days.isEmpty ? Array(recent.suffix(1)) : days
    }

    private func isSnoozed(_ nudge: Nudge, now: Date) -> Bool {
        state.snoozed[nudge.id].map { $0.until > now } ?? false
    }

    // MARK: - Snoozing

    func snooze(_ nudge: Nudge, days: Int) {
        let now = Date.now
        state.snoozed[nudge.id] = DigestState.Snooze(until: now.addingTimeInterval(Double(days) * 86_400), set: now)
        save()
    }

    /// A snooze from the iPhone: taken when it's the later decision.
    func applySnooze(_ snooze: DigestState.Snooze, to nudge: String) {
        guard state.snoozed[nudge].map({ snooze.set > $0.set }) ?? true else { return }
        state.snoozed[nudge] = snooze
        save()
    }

    /// Brings every snoozed nudge back, on every Mac.
    func wakeSnoozed() {
        let now = Date.now
        for (id, snooze) in state.snoozed where snooze.until > now {
            state.snoozed[id] = DigestState.Snooze(until: now, set: now)
        }
        save()
    }

    // MARK: - Sending

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // The Passport reads first.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled, let self {
                await self.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func tick() async {
        let now = Date.now
        Notifier.shared.remind(ProjectStore.shared.projects, now: now)
        await readOtherMacs()
        guard isOn, isDue(at: now), !isSending else { return }
        // When you're at the Mac: you've moved the mouse or typed in the last two minutes.
        if (ignoresPresence || Presence.secondsSinceInput < 120) && !PhoneShare.shared.pretendsAway {
            await send(now: now)
            return
        }
        // Nobody at any Mac three hours after the digest's time: it goes to the iPhone instead.
        let calendar = Calendar.current
        let time = calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: now)) ?? now
        let phone = PhoneShare.shared
        if now >= time.addingTimeInterval(Self.phoneAfter), phone.reachesPhone, phone.lastUsedAnyMac < time {
            await send(now: now, toPhone: true)
        }
    }

    /// How long after the digest's time it goes to the iPhone, when nobody has been at a Mac.
    static let phoneAfter: TimeInterval = 3 * 3600

    /// Past today's time, on a digest day, and not sent today by this Mac or another.
    private func isDue(at now: Date) -> Bool {
        let calendar = Calendar.current
        if weekdaysOnly, calendar.isDateInWeekend(now) { return false }
        guard now >= calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: now)) ?? now else { return false }
        var keys = DayKeys()
        return state.record?.day != keys.key(for: now)
    }

    /// Makes today's digest and sends it, unless there's nothing to say: as a notification here, or as
    /// an alert on the iPhone. `force` sends it again, for the same days (for testing).
    func send(now: Date, force: Bool = false, toPhone: Bool = false) async {
        let passport = PassportStore.shared
        guard !isSending, !passport.isReading || force else { return }
        isSending = true
        defer { isSending = false }
        // Read what's new, so last night's work counts.
        await passport.read()
        var keys = DayKeys()
        let digest = digest(now: now)
        guard let first = digest.days.first, let last = digest.days.last else { return }
        guard !digest.isEmpty else {
            state.record = DigestState.Record(day: keys.key(for: now), from: keys.key(for: first), through: keys.key(for: last),
                                              sent: nil, machine: ProjectStore.shared.machineName)
            save()
            log.info("Nothing for the digest today")
            return
        }
        if toPhone {
            // Kept for later if the iPhone can't be reached now.
            guard await PhoneShare.shared.sendAlert(id: "digest.\(keys.key(for: now))", title: digest.title, body: digest.body,
                                                    project: "today") else { return }
        }
        state.record = DigestState.Record(day: keys.key(for: now), from: keys.key(for: first), through: keys.key(for: last),
                                          sent: now, machine: ProjectStore.shared.machineName, toPhone: toPhone ? true : nil)
        save()
        guard !toPhone else { return }
        let needsYou = digest.waiting.contains { $0.state?.needsYou == true }
        Notifier.shared.post(Notifier.Notice(key: "digest|\(keys.key(for: now))", kind: "digest", title: digest.title, body: digest.body,
                                             project: "", screen: "today"),
                             sound: needsYou)
    }

    // MARK: - Other Macs

    private func readOtherMacs() async {
        let store = ProjectStore.shared
        guard store.syncsWithOtherMacs, SyncFolder.isAvailable else { return }
        let machineID = store.machineID
        let theirs = await Task.detached(priority: .utility) {
            SyncFolder.readShared(DigestState.self, in: "Digest", excluding: machineID)
        }.value
        var merged = state
        for other in theirs { merged.merge(other) }
        guard merged.record != state.record || merged.snoozed != state.snoozed else { return }
        state = merged
        save(share: false)
    }

    // MARK: - Saving

    private func save(share: Bool = true) {
        let now = Date.now
        // Woken and expired snoozes are kept a week, so waking one reaches every Mac.
        state.snoozed = state.snoozed.filter { $0.value.until > now.addingTimeInterval(-7 * 86_400) }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ProjectStore.encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Couldn't save the digest: \(error.localizedDescription, privacy: .public)")
        }
        let store = ProjectStore.shared
        guard share, store.syncsWithOtherMacs, SyncFolder.isAvailable else { return }
        let (shared, machineID) = (state, store.machineID)
        Task.detached(priority: .utility) {
            try? SyncFolder.writeShared(shared, in: "Digest", machineID: machineID)
        }
    }
}
