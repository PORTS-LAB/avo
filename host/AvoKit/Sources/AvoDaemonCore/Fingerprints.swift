import AvoKit
import Foundation
import os

/// Avo's fingers (`fingerprints.json`, next to Android's data disk). They
/// are Avo's: added, renamed and removed whether Android runs or not. Which
/// of them Android has (`enrolled`) and Android's names for them are what Avo
/// saw last; while Android runs, its own list says.
struct FingerprintStore: Codable, Equatable {
    var fingers: [Fingerprint] = []
    /// The name Android had for each fingerprint it has, at the last look: a
    /// finger whose name differs from it was renamed in Avo since, one whose
    /// Android name changed was renamed in Android's Settings.
    var androidNames: [Int: String] = [:]
    /// Fingers removed in Avo that Android still has: it lets go of them
    /// once it runs and nothing waits for a finger.
    var removing: [Int] = []

    init(fingers: [Fingerprint] = [], androidNames: [Int: String] = [:], removing: [Int] = []) {
        self.fingers = fingers
        self.androidNames = androidNames
        self.removing = removing
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fingers = try container.decodeIfPresent([Fingerprint].self, forKey: .fingers) ?? []
        // Saved before Avo kept fingers of its own: the list was Android's, with its names.
        androidNames = try container.decodeIfPresent([Int: String].self, forKey: .androidNames)
            ?? Dictionary(fingers.filter(\.enrolled).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        removing = try container.decodeIfPresent([Int].self, forKey: .removing) ?? []
    }

    static func url(_ paths: AvoPaths) -> URL { paths.data.appending(path: "fingerprints.json") }

    static func load(_ paths: AvoPaths) -> FingerprintStore {
        guard let data = try? Data(contentsOf: url(paths)) else { return FingerprintStore() }
        return (try? JSONDecoder().decode(FingerprintStore.self, from: data)) ?? FingerprintStore()
    }

    func save(_ paths: AvoPaths) throws {
        try paths.ensureDataFolder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(paths), options: .atomic)
    }
}

/// Settings › Fingerprints and the app windows' fingerprint menus: keeps
/// Avo's fingers, touches Android's sensor with them (which adds one to
/// Android while its Settings app adds a fingerprint), follows what Android
/// does with them, and says what in Android asks for a finger (an app's
/// BiometricPrompt shows on Android's own screen, which no window shows).
/// Guest steps are in GuestFingerprints; every change goes to `updates`.
actor FingerprintCenter {
    nonisolated let updates: AsyncStream<FingerprintStatus>
    private let continuation: AsyncStream<FingerprintStatus>.Continuation
    private let paths: AvoPaths
    private let engine: (any FingerprintEngine)?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Fingerprints")

    private var store: FingerprintStore
    /// What `vm/fingerprints.json` holds.
    private var saved: FingerprintStore
    private(set) var current: FingerprintStatus
    private var running = false
    /// Android is paused (Pause When Idle, the menu bar): the watcher waits,
    /// since asking Android would wake it. A touch or a status asked for still does.
    private(set) var paused = false
    /// This boot's Android has the settings `fingerdown` and lockout need.
    private var prepared = false
    private var refreshedAt: ContinuousClock.Instant?
    /// How many fingerprints Android had at the last look (another count:
    /// its Settings added or removed one).
    private var androidCount: Int?
    /// The sensor's own enrollments at the last look: ids a new finger does not take.
    private var sensorEnrollments: [Int] = []
    /// When taking fingers out of Android last left some in.
    private var removalFailedAt: ContinuousClock.Instant?
    /// Asks Android every `pollInterval` what waits for a finger, while Avo has fingers.
    private var watcher: Task<Void, Never>?
    /// Asks again once a timed lockout is over.
    private var lockoutCheck: Task<Void, Never>?
    /// One guest change at a time (`exclusive`).
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static let pollInterval: Duration = .seconds(2)
    /// A status younger than this is not asked again (menus open often).
    static let freshFor: Duration = .seconds(5)
    /// The sensor answers after its latency (400 ms) and capture (10 ms).
    static let touchTimeout: Duration = .milliseconds(2500)
    static let timedLockout: Duration = .seconds(31)
    /// How long a removal Android did not take waits before the next try.
    static let removalRetry: Duration = .seconds(30)

    init(paths: AvoPaths, engine: any VMEngine) {
        self.paths = paths
        self.engine = engine as? any FingerprintEngine
        (updates, continuation) = AsyncStream.makeStream(of: FingerprintStatus.self, bufferingPolicy: .bufferingNewest(8))
        store = FingerprintStore.load(paths)
        saved = store
        current = FingerprintStatus(availability: .androidStopped, fingers: store.fingers)
    }

    // MARK: Android starts and stops

    func androidChanged(_ state: VMState) {
        let nowRunning = state == .running
        guard nowRunning != running else { return }
        running = nowRunning
        prepared = false
        refreshedAt = nil
        androidCount = nil
        removalFailedAt = nil
        watcher?.cancel()
        watcher = nil
        lockoutCheck?.cancel()
        lockoutCheck = nil
        guard nowRunning else {
            publish(FingerprintStatus(availability: .androidStopped, fingers: store.fingers))
            return
        }
        guard engine != nil else {
            publish(FingerprintStatus(availability: .unsupported))
            return
        }
        // Once per start: what Android did with the fingers meanwhile, and
        // the settings fingerprints need (only on an Android that has some).
        Task {
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
                guard running else { return }
                do {
                    try await exclusive { try await refresh() }
                    return
                } catch {
                    logger.notice("fingerprints not read yet: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func androidPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        updateWatcher()
    }

    /// The watcher asks Android now and then (tests).
    var isWatching: Bool { watcher != nil }

    /// Android's data is in another place now (Android is stopped): its
    /// fingers are the ones kept with it.
    func reload() {
        store = FingerprintStore.load(paths)
        saved = store
        publish(FingerprintStatus(availability: .androidStopped, fingers: store.fingers))
    }

    /// Reset Android: its fingerprints went with its data; Avo's fingers stay, none of them in Android.
    func forget() {
        store = FingerprintStore(fingers: store.fingers.map { Fingerprint(id: $0.id, name: $0.name, enrolled: false) })
        persist()
        var status = current
        status.fingers = store.fingers
        status.request = nil
        publish(status)
    }

    // MARK: Requests from the Control Panel and app windows

    /// The status, asked from Android when `refresh` or when it is older than `freshFor`.
    func status(refresh wanted: Bool) async -> FingerprintStatus {
        guard running, engine != nil else { return current }
        let stale = refreshedAt.map { ContinuousClock.now - $0 > Self.freshFor } ?? true
        if wanted || stale {
            do {
                try await exclusive { try await refresh() }
            } catch {
                logger.error("fingerprint status: \(String(describing: error), privacy: .public)")
            }
        }
        return current
    }

    /// A new finger, in Avo only: Android adds it when its Settings app is touched with it.
    func add(named name: String) async throws -> Fingerprint {
        try requireSensor()
        return try await exclusive {
            let name = try FingerprintName.validated(name, among: store.fingers).mapError(AvoError.fingerprint).get()
            let finger = Fingerprint(id: GuestFingerprints.newID(avoiding: knownIDs()), name: name, enrolled: false)
            store.fingers.append(finger)
            persist()
            publishFingers()
            logger.notice("finger \(finger.id) added")
            return finger
        }
    }

    /// Renames a finger; Android's Settings shows the new name too (now, or
    /// once Android runs).
    func rename(_ id: Int, to name: String) async throws {
        try requireSensor()
        try await exclusive {
            guard let index = store.fingers.firstIndex(where: { $0.id == id }) else { throw AvoError.fingerprint(.unknownFinger) }
            let name = try FingerprintName.validated(name, among: store.fingers, renaming: id).mapError(AvoError.fingerprint).get()
            store.fingers[index].name = name
            let finger = store.fingers[index]
            publishFingers()
            if finger.enrolled, running, let guest = try? await guest() {
                await renameInAndroid(finger, guest)
            }
            persist()
        }
    }

    /// Removes a finger; Android lets go of it too (now, or once it runs and
    /// nothing waits for a finger).
    func remove(_ id: Int) async throws {
        try requireSensor()
        try await exclusive {
            guard let finger = store.fingers.first(where: { $0.id == id }) else { throw AvoError.fingerprint(.unknownFinger) }
            store.fingers.removeAll { $0.id == id }
            if finger.enrolled || store.androidNames[id] != nil, !store.removing.contains(id) { store.removing.append(id) }
            persist()
            publishFingers()
            logger.notice("finger \(id) removed")
            if !store.removing.isEmpty, running, let guest = try? await guest(),
               let dump = try? await dump(guest), dump.request == nil {
                await removeFromAndroid(guest)
            }
            updateWatcher()
        }
    }

    /// Puts finger `id` (nil: one Avo does not know) on the sensor and says
    /// what Android made of it. While Android's Settings adds a fingerprint,
    /// the touch adds that finger.
    func touch(_ id: Int?) async throws -> FingerprintTouchResult {
        try await exclusive {
            let guest = try await guest()
            if let id, current.finger(id) == nil { throw AvoError.fingerprint(.unknownFinger) }
            let before = try await dump(guest)
            guard let request = before.request else {
                // Nothing waits: say why when it is Android holding fingerprints back.
                let report = try await refresh(guest)
                if report.helper.lockout != .none { return .lockedOut }
                if GuestFingerprints.credentialRequired(report) { return .credentialRequired }
                return .nobodyAsked
            }
            if request.purpose == .enroll { return try await enroll(id, guest: guest, before: before) }
            _ = try await guest.fingerprintShell(GuestFingerprints.touchScript(id: id ?? 0), asRoot: true)
            guard let stats = before.stats else {
                // An Android without the counts: the touch went in, its outcome is the app's to show.
                try? await Task.sleep(for: .milliseconds(600))
                _ = try? await refresh(guest)
                return .touched
            }
            var outcome: FingerprintTouchResult?
            let deadline = ContinuousClock.now + Self.touchTimeout
            while outcome == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(200))
                guard let after = try await dump(guest).stats else { continue }
                outcome = GuestFingerprints.touchOutcome(request.purpose, before: stats, after: after)
                if outcome == .notRecognized {
                    // The wrong finger that locks fingerprints out is counted a moment later.
                    try await Task.sleep(for: .milliseconds(250))
                    if let later = try await dump(guest).stats,
                       GuestFingerprints.touchOutcome(request.purpose, before: stats, after: later) == .lockedOut {
                        outcome = .lockedOut
                    }
                }
            }
            logger.notice("fingerprint touch \(id ?? 0) for \(request.package, privacy: .public): \(outcome?.rawValue ?? "no answer", privacy: .public)")
            switch outcome {
            case .recognized?, .notRecognized?:
                // The request is over or still waits: the counts' dump says which.
                if let after = try? await dump(guest) {
                    var status = current
                    status.request = after.request
                    publish(status)
                }
            default:
                // A lockout or no answer: everything again.
                _ = try? await refresh(guest)
                if outcome == .lockedOut, current.lockout == .timed { checkLockoutLater() }
            }
            return outcome ?? .touched
        }
    }

    /// Cancels an app's BiometricPrompt (not the lock screen's, nor an enrollment).
    func cancelRequest() async throws {
        try await exclusive {
            let guest = try await guest()
            guard let request = try await dump(guest).request, request.purpose == .authenticate, !request.isLockScreen else {
                return
            }
            _ = try await guest.fingerprintShell(GuestFingerprints.cancelCommand, asRoot: false)
            try? await Task.sleep(for: .milliseconds(300))
            let after = try await dump(guest)
            var status = current
            status.request = after.request
            publish(status)
        }
    }

    /// Locks Android, which then asks for its screen lock (Avo's lock over
    /// its windows): entering it lifts a fingerprint lockout.
    func lockAndroid() async throws {
        try await exclusive {
            let guest = try await guest()
            _ = try await guest.fingerprintShell(GuestFingerprints.lockCommand, asRoot: false)
        }
    }

    // MARK: Guest steps

    private func guest() async throws -> any FingerprintGuest {
        guard running else { throw AvoError.vmNotRunning }
        guard let engine else { throw AvoError.fingerprint(.unsupported) }
        return try await engine.fingerprintGuest()
    }

    /// Fingers are kept for an Android that can take them (an engine with
    /// the sensor, an image with it as far as Avo knows).
    private func requireSensor() throws {
        guard engine != nil, current.availability != .unsupported else { throw AvoError.fingerprint(.unsupported) }
    }

    /// Ids a new finger does not take: Avo's, Android's and the sensor's.
    private func knownIDs() -> [Int] {
        store.fingers.map(\.id) + store.removing + Array(store.androidNames.keys) + sensorEnrollments
    }

    /// A touch while Android's Settings adds a fingerprint: the sensor
    /// enrolls finger `id` under its own id, and Android takes its name.
    private func enroll(_ id: Int?, guest: any FingerprintGuest, before: GuestFingerprints.SensorDump) async throws -> FingerprintTouchResult {
        guard let id else { throw AvoError.fingerprint(.unregisteredFinger) }
        // Android's list now: the finger may be in it already.
        let report = try await refresh(guest)
        guard var finger = store.fingers.first(where: { $0.id == id }) else { throw AvoError.fingerprint(.unknownFinger) }
        guard !finger.enrolled else { throw AvoError.fingerprint(.alreadyInAndroid(finger.name)) }
        let taken = report.helper.fingers.map(\.id) + report.facts.sensorEnrollments + store.removing
        if taken.contains(finger.id), let index = store.fingers.firstIndex(where: { $0.id == finger.id }) {
            // Android or its sensor still has that id from before: the finger takes a new one.
            finger.id = GuestFingerprints.newID(avoiding: taken + knownIDs())
            store.fingers[index].id = finger.id
            persist()
        }
        try await prepare(guest, report: report)
        _ = try await guest.fingerprintShell(GuestFingerprints.enrollScript(id: finger.id), asRoot: true)
        var enrolled = false
        if let stats = before.stats {
            let deadline = ContinuousClock.now + Self.touchTimeout
            while !enrolled, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(200))
                guard let after = try await dump(guest).stats else { continue }
                enrolled = GuestFingerprints.touchOutcome(.enroll, before: stats, after: after) == .enrolled
            }
        } else {
            try? await Task.sleep(for: .milliseconds(800))
        }
        // Android named it "Finger N"; the look after gives it the finger's name.
        _ = try? await refresh(guest)
        logger.notice("finger \(finger.id) touched for Settings: \(enrolled ? "added" : "no answer", privacy: .public)")
        if enrolled { return .enrolled }
        return current.finger(finger.id)?.enrolled == true ? .enrolled : .touched
    }

    @discardableResult
    private func refresh(_ known: (any FingerprintGuest)? = nil) async throws -> GuestFingerprints.Report {
        let guest: any FingerprintGuest
        if let known { guest = known } else { guest = try await self.guest() }
        let report = GuestFingerprints.report(try await runHelperScript(GuestFingerprints.statusScript, guest))
        try await apply(report, guest: guest)
        return report
    }

    /// Takes Android's list (from `report`) as what Android has, and Avo's
    /// fingers as what the user has: see `GuestFingerprints.merge`.
    private func apply(_ report: GuestFingerprints.Report, guest: any FingerprintGuest) async throws {
        let availability = GuestFingerprints.availability(report)
        if availability != .unsupported {
            guard report.helper.complete else {
                throw AvoError.fingerprint(.androidRefused(report.helper.error ?? String(localized: "Android did not list its fingerprints.", bundle: .avoKit)))
            }
            var android = report.helper.fingers
            if !store.removing.isEmpty, report.dump.request == nil, removalDue, let after = await removeFromAndroid(guest) {
                android = after
            }
            // The ones Android no longer has are out.
            store.removing.removeAll { id in !android.contains { $0.id == id } }
            let merged = GuestFingerprints.merge(android: android, fingers: store.fingers, androidNames: store.androidNames,
                                                 removing: store.removing, defaultName: Self.defaultName)
            store.fingers = merged.fingers
            store.androidNames = merged.androidNames
            for finger in merged.renames { await renameInAndroid(finger, guest) }
            androidCount = android.count
            sensorEnrollments = report.facts.sensorEnrollments
            // An Android that has, or had, fingerprints from Avo (the setting stays on).
            if !store.fingers.isEmpty || report.facts.virtualEnabled { try? await prepare(guest, report: report) }
            persist()
        }
        refreshedAt = .now
        publish(FingerprintStatus(availability: availability, fingers: store.fingers, lockout: report.helper.lockout,
                                  credentialRequired: GuestFingerprints.credentialRequired(report), request: report.dump.request))
        updateWatcher()
    }

    /// Gives Android's fingerprint the finger's name, and notes what Android has after.
    @discardableResult
    private func renameInAndroid(_ finger: Fingerprint, _ guest: any FingerprintGuest) async -> Bool {
        guard let output = try? await runHelperScript(GuestFingerprints.renameScript(id: finger.id, name: finger.name), guest),
              let named = GuestFingerprints.helperStatus(output).fingers.first(where: { $0.id == finger.id }) else {
            logger.error("fingerprint \(finger.id) not renamed in Android")
            return false
        }
        store.androidNames[finger.id] = named.name
        return named.name == finger.name
    }

    /// Takes the fingers removed in Avo out of Android, one at a time as its
    /// Settings does (each waits for the sensor, so only while nothing asks
    /// for a finger). Android's list after, nil when no removal answered.
    @discardableResult
    private func removeFromAndroid(_ guest: any FingerprintGuest) async -> [Fingerprint]? {
        var android: [Fingerprint]?
        var left: [Int] = []
        for id in store.removing {
            guard let output = try? await runHelperScript(GuestFingerprints.removeScript(id: id), guest) else {
                left.append(id)
                continue
            }
            let status = GuestFingerprints.helperStatus(output)
            guard status.complete, !status.fingers.contains(where: { $0.id == id }) else {
                left.append(id)
                continue
            }
            android = status.fingers
            store.androidNames[id] = nil
            logger.notice("fingerprint \(id) removed from Android")
        }
        store.removing = left
        removalFailedAt = left.isEmpty ? nil : .now
        if let android { androidCount = android.count }
        persist()
        return android
    }

    private var removalDue: Bool {
        removalFailedAt.map { ContinuousClock.now - $0 > Self.removalRetry } ?? true
    }

    /// What `fingerdown` and lockout need, once per boot.
    private func prepare(_ guest: any FingerprintGuest, report: GuestFingerprints.Report) async throws {
        guard !prepared || !report.facts.virtualEnabled else { return }
        let result = try await guest.fingerprintShell(GuestFingerprints.prepareScript, asRoot: true)
        if result.succeeded { prepared = true }
    }

    private func dump(_ guest: any FingerprintGuest) async throws -> GuestFingerprints.SensorDump {
        GuestFingerprints.sensorDump(try await guest.fingerprintShell(GuestFingerprints.dumpCommand, asRoot: false).output)
    }

    /// Runs a root script that uses the helper, copying the helper into
    /// Android first when it is not there yet.
    private func runHelperScript(_ script: String, _ guest: any FingerprintGuest) async throws -> String {
        var result = try await guest.fingerprintShell(script, asRoot: true)
        if result.exitCode == GuestFingerprints.helperMissingStatus || result.output.contains(GuestFingerprints.helperMissingMarker) {
            guard let jar = GuestFingerprints.helperJar else { throw AvoError.internalError("the fingerprint helper is missing") }
            try await guest.fingerprintPush(jar, to: GuestFingerprints.helperPath)
            result = try await guest.fingerprintShell(script, asRoot: true)
        }
        return result.output
    }

    // MARK: Watching what asks for a finger

    private func updateWatcher() {
        let wanted = running && !paused && engine != nil && current.availability != .unsupported
            && !(store.fingers.isEmpty && store.removing.isEmpty)
        if wanted, watcher == nil {
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pollInterval)
                    await self?.poll()
                }
            }
        } else if !wanted, let watcher {
            watcher.cancel()
            self.watcher = nil
        }
    }

    private func poll() async {
        guard running, !busy, let guest = try? await guest(), let dump = try? await dump(guest) else { return }
        // Added or removed in Android's Settings (or gone with its screen
        // lock), a request while Android was not ready (a screen lock set
        // meanwhile), or fingers to take out of Android now that nothing asks.
        let counted = dump.stats.map { $0.count != androidCount } ?? false
        let readyNow = dump.request != nil && current.availability != .ready
        let removals = !store.removing.isEmpty && dump.request == nil && removalDue
        if counted || readyNow || removals {
            _ = try? await exclusive { try await refresh(guest) }
            return
        }
        guard dump.request != current.request else { return }
        var status = current
        status.request = dump.request
        publish(status)
    }

    private func checkLockoutLater() {
        lockoutCheck?.cancel()
        lockoutCheck = Task { [weak self] in
            try? await Task.sleep(for: Self.timedLockout)
            guard !Task.isCancelled else { return }
            _ = await self?.status(refresh: true)
        }
    }

    // MARK: Plumbing

    private func publish(_ status: FingerprintStatus) {
        guard status != current else { return }
        current = status
        continuation.yield(status)
    }

    private func publishFingers() {
        var status = current
        status.fingers = store.fingers
        publish(status)
    }

    private func persist() {
        guard store != saved else { return }
        do {
            try store.save(paths)
            saved = store
        } catch {
            logger.error("cannot save fingerprints: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One guest change at a time: a touch and a look must not cross.
    @discardableResult
    private func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    static func defaultName(_ number: Int) -> String {
        String(localized: "Finger \(number)", bundle: .avoKit)
    }
}

// MARK: - The daemon's fingerprint calls (XPC: AvoDaemonXPC "Fingerprints")

extension DaemonCore {
    /// Control Panels and App Shims.
    public func fingerprintStatus(refresh: Bool, client: ClientID) async throws -> FingerprintStatus {
        try requireFingerprintCaller(client, changes: false)
        return await fingerprints.status(refresh: refresh)
    }

    /// Control Panel only, like every setting: fingers live in Avo, Android's
    /// Settings adds them when touched with one.
    public func addFingerprint(named name: String, client: ClientID) async throws -> Fingerprint {
        try requireFingerprintCaller(client, changes: true)
        return try await fingerprints.add(named: name)
    }

    public func renameFingerprint(_ id: Int, to name: String, client: ClientID) async throws {
        try requireFingerprintCaller(client, changes: true)
        try await fingerprints.rename(id, to: name)
    }

    public func removeFingerprint(_ id: Int, client: ClientID) async throws {
        try requireFingerprintCaller(client, changes: true)
        try await fingerprints.remove(id)
    }

    /// Control Panels and App Shims (a window's fingerprint menu). `id`
    /// nil: a finger Avo does not know.
    public func touchFingerprint(_ id: Int?, client: ClientID) async throws -> FingerprintTouchResult {
        try requireFingerprintCaller(client, changes: false)
        return try await fingerprints.touch(id)
    }

    public func cancelFingerprintRequest(client: ClientID) async throws {
        try requireFingerprintCaller(client, changes: false)
        try await fingerprints.cancelRequest()
    }

    public func lockAndroidForFingerprints(client: ClientID) async throws {
        try requireFingerprintCaller(client, changes: false)
        try await fingerprints.lockAndroid()
    }

    private func requireFingerprintCaller(_ client: ClientID, changes: Bool) throws {
        switch role(of: client) {
        case .controlPanel?: return
        case .shim?: if !changes { return }
        default: break
        }
        throw AvoError.unauthorizedCaller
    }
}
