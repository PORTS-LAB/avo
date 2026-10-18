import AvoKit
import AvoPackages
import Foundation
import Testing
@testable import AvoDaemonCore

/// Android as the installer sees it: dm-verity, the overlay `remount` sets
/// up, the system partitions with the commit's manifest, and whether it
/// boots, with every step recorded.
actor FakeSystemApps: SystemAppsGuest {
    var verity: Bool
    var verityOffAtNextBoot = false
    /// `remount` asks for a reboot until the overlay exists (after one restart).
    var overlayReady: Bool
    var overlayAtNextBoot = false
    var facts = SystemFacts(sdk: 37, arch: "arm64", product: "vsoc_arm64_only")
    var free: UInt64 = 8 << 30
    var staged: [String: Data] = [:]
    var system: [String: Data] = [:]
    /// What the last commit added (its manifest) and how far it got.
    var added: Set<String> = []
    var manifest = CommitState.none
    var packages: Set<String> = ["com.android.settings"]
    var steps: [String] = []
    /// Android does not get ready while the commit's files are in (system_server loops).
    var bootLoopsWithCommit = false
    private(set) var ready = true
    var commitFails = false
    var holdCommit = false
    private var held: CheckedContinuation<Void, any Error>?

    init(verity: Bool, overlayReady: Bool) {
        self.verity = verity
        self.overlayReady = overlayReady
    }

    func set(free bytes: UInt64? = nil, bootLoops: Bool? = nil, commitFails: Bool? = nil, holdCommit: Bool? = nil) {
        if let bytes { free = bytes }
        if let bootLoops { bootLoopsWithCommit = bootLoops }
        if let commitFails { self.commitFails = commitFails }
        if let holdCommit { self.holdCommit = holdCommit }
    }

    func note(_ step: String) { steps.append(step) }

    /// The engine started: Android boots with what the partitions have.
    func boot() {
        if verityOffAtNextBoot { verity = false }
        if overlayAtNextBoot { overlayReady = true }
        ready = !(bootLoopsWithCommit && !added.isEmpty)
        if system.keys.contains("product/priv-app/Phonesky/Phonesky.apk") {
            packages.formUnion([GoogleApps.playStore, GoogleApps.playServices])
        } else {
            packages.subtract([GoogleApps.playStore, GoogleApps.playServices])
        }
    }

    func restart() throws {
        steps.append("restart")
        boot()
        guard ready else { throw AvoError.timedOut("Android boot") }
    }

    /// The running guest (`SystemAppsEngine.systemApps`): not while Android loops.
    func whenReady() throws -> FakeSystemApps {
        guard ready else { throw AvoError.vmNotRunning }
        return self
    }

    /// Lets a held commit finish, or fails it as a lost connection would.
    func releaseCommit(failing: Bool = false) {
        let held = self.held
        self.held = nil
        if failing { held?.resume(throwing: AvoError.guestUnavailable) } else { held?.resume() }
    }

    var commitIsHeld: Bool { held != nil }

    func systemFacts() async throws -> SystemFacts { facts }

    func verityEnabled() async throws -> Bool { verity }

    func disableVerity() async throws {
        steps.append("disable-verity")
        verityOffAtNextBoot = true
    }

    func remount(afterRestart: Bool) async throws -> RemountResult {
        steps.append("remount")
        guard !verity else { throw AvoError.installFailed("verity is on") }
        if overlayReady { return .writable }
        overlayAtNextBoot = true
        return afterRestart ? .writable : .needsRestart
    }

    func freeBytes(_ path: String) async -> UInt64? { free }

    func stage(_ files: [GoogleAppsPackage.File], of package: GoogleAppsPackage,
               progress: @escaping @Sendable (UInt64) -> Void) async throws {
        steps.append("stage")
        var sent: UInt64 = 0
        for file in files {
            var data = Data()
            try package.stream(file) { data.append($0) }
            staged[file.path] = data
            sent += UInt64(data.count)
            progress(sent)
        }
    }

    func commitStaged(_ paths: [String]) async throws {
        steps.append("commit")
        #expect(Set(paths) == Set(staged.keys))
        manifest = .partial
        do {
            if holdCommit { try await withCheckedThrowingContinuation { held = $0 } }
            if commitFails { throw AvoError.installFailed("copying into the system partitions failed: No space left on device") }
        } catch {
            // Allowlists went in first, then it stopped.
            if let first = staged.keys.sorted().first {
                if system[first] == nil { added.insert(first) }
                system[first] = staged[first]
            }
            staged.removeAll()
            throw error
        }
        for (path, data) in staged {
            if system[path] == nil { added.insert(path) }
            system[path] = data
        }
        staged.removeAll()
        manifest = .complete
    }

    func commitState() async throws -> CommitState { manifest }

    func rollBackCommit() async throws {
        steps.append("rollback")
        takeOut()
    }

    /// The same script over a fresh adbd connection.
    func rescue() {
        steps.append("rescue")
        takeOut()
    }

    private func takeOut() {
        for path in added { system[path] = nil }
        added.removeAll()
        manifest = .none
    }

    func packageNames() async throws -> Set<String> { packages }

    func googleAppsStatus() async -> GoogleAppsStatus { GoogleAppsStatus(supported: true) }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [GoogleAppsProgress] = []
    var items: [GoogleAppsProgress] { lock.withLock { _items } }
    func append(_ item: GoogleAppsProgress) { lock.withLock { _items.append(item) } }
}

/// A MindTheGapps folder: the layout of 17.0.0, shortened.
func googleAppsPackageFolder(version: String = "37", in parent: URL? = nil) throws -> URL {
    let root = (parent ?? FileManager.default.temporaryDirectory).appending(path: "avo-gapps-\(UUID().uuidString)")
    let files: [(String, Data)] = [
        ("build.prop", Data("arch=arm64\nversion=\(version)\nversion_nice=17.0.0\n".utf8)),
        ("META-INF/com/google/android/update-binary", Data("#!/sbin/sh\n".utf8)),
        ("system/addon.d/addond_head", Data("#!/sbin/sh\n".utf8)),
        ("system/product/etc/permissions/privapp-permissions-google-product.xml", Data("<permissions/>".utf8)),
        ("system/product/priv-app/Phonesky/Phonesky.apk", Data(repeating: 1, count: 4000)),
        ("system/product/priv-app/VelvetTitan/VelvetTitan.apk", Data(repeating: 2, count: 3000)),
        ("system/product/apex/com.google.android.gmssystem.prodvic.apex", Data(repeating: 3, count: 2000)),
        ("system/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk", Data(repeating: 4, count: 1000)),
        ("system/system_ext/priv-app/SetupWizard/SetupWizard.apk", Data(repeating: 5, count: 500)),
    ]
    for (path, data) in files {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    return root
}

private func installer(_ guest: FakeSystemApps, log: ProgressLog, interrupted: @escaping @Sendable () async -> Bool = { false }) -> GoogleAppsInstaller {
    var installer = GoogleAppsInstaller(id: UUID(), ensureRunning: {}, restart: { try await guest.restart() },
                                        guest: { try await guest.whenReady() }, report: { log.append($0) })
    installer.rescue = { await guest.rescue() }
    installer.committing = { await guest.note("committing") }
    installer.committed = { await guest.note("committed") }
    installer.restored = { await guest.note("restored") }
    installer.interrupted = interrupted
    return installer
}

@Suite struct GoogleAppsInstallerTests {
    static let installed = [
        "product/apex/com.google.android.gmssystem.prodvic.apex",
        "product/etc/permissions/privapp-permissions-google-product.xml",
        "product/priv-app/Phonesky/Phonesky.apk",
        "system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk",
    ]

    @Test func firstInstallTurnsOffVerityAndRestartsThreeTimes() async throws {
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = FakeSystemApps(verity: true, overlayReady: false)
        let log = ProgressLog()
        try await installer(guest, log: log).run(GoogleAppsPackage(url: folder))

        #expect(await guest.steps == ["disable-verity", "restart", "remount", "restart", "remount", "stage",
                                      "committing", "commit", "restart", "committed"])
        // The installer's rules: no VelvetTitan (not a tablet), no SetupWizard, no addon.d.
        #expect(await guest.system.keys.sorted() == Self.installed)
        #expect(await guest.system["product/priv-app/Phonesky/Phonesky.apk"] == Data(repeating: 1, count: 4000))

        let phases = log.items.map(\.phase)
        #expect(phases.first == .startingVM)
        #expect(phases.last == .checking)
        #expect(phases.filter { $0 == .restarting }.count == 3)
        let fractions = log.items.filter { $0.phase == .transferring }.compactMap(\.fraction)
        #expect(fractions.first == 0)
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
    }

    @Test func updatingSkipsWhatIsAlreadyDone() async throws {
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        try await installer(guest, log: ProgressLog()).run(GoogleAppsPackage(url: folder))
        #expect(await guest.steps == ["remount", "stage", "committing", "commit", "restart", "committed"])
    }

    @Test func aPackageForAnotherAndroidChangesNothing() async throws {
        let folder = try googleAppsPackageFolder(version: "36")
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = FakeSystemApps(verity: true, overlayReady: false)
        await #expect(throws: AvoError.self) {
            try await installer(guest, log: ProgressLog()).run(GoogleAppsPackage(url: folder))
        }
        #expect(await guest.steps.isEmpty)
    }

    @Test func notEnoughSpaceStopsBeforeCopying() async throws {
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await guest.set(free: 1 << 20)
        await #expect(throws: AvoError.self) {
            try await installer(guest, log: ProgressLog()).run(GoogleAppsPackage(url: folder))
        }
        #expect(await guest.steps == ["remount"])
    }

    /// The commit stops halfway (ENOSPC, a lost connection): what went in
    /// comes out through the running guest, which loaded none of it.
    @Test func aFailedCommitIsTakenOutWithoutARestart() async throws {
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await guest.set(commitFails: true)
        let log = ProgressLog()
        let error = await #expect(throws: GoogleAppsInstallError.self) {
            try await installer(guest, log: log).run(GoogleAppsPackage(url: folder))
        }
        guard case .restored(let reason)? = error else { Issue.record("not restored: \(String(describing: error))"); return }
        #expect(reason.contains("No space left on device"))
        // One sentence of its own, not "Installation failed: copying …".
        #expect(reason.hasPrefix("Copying into the system partitions failed"))
        #expect(error?.errorDescription?.hasPrefix("Google apps were not installed; Android was restored.") == true)
        #expect(await guest.steps == ["remount", "stage", "committing", "commit", "rollback", "restored"])
        #expect(await guest.system.isEmpty)
        #expect(log.items.last?.phase == .restoring)
    }

    /// The boot with Google apps never gets ready (system_server loops on a
    /// missing allowlist): taken out over adbd, then Android starts as it was.
    @Test func aBootThatNeverGetsReadyIsRescuedOverADB() async throws {
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await guest.set(bootLoops: true)
        await #expect(throws: GoogleAppsInstallError.self) {
            try await installer(guest, log: ProgressLog()).run(GoogleAppsPackage(url: folder))
        }
        #expect(await guest.steps == ["remount", "stage", "committing", "commit", "restart", "rescue", "restart", "restored"])
        #expect(await guest.system.isEmpty)
        #expect(await guest.ready)
        #expect(await !guest.packages.contains(GoogleApps.playStore))
    }

    /// Settings › Google services flips only once Android lists Google Play;
    /// files Android does not take come out again.
    @Test func playStoreMissingAfterwardsIsTakenOut() async throws {
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A package without the Play Store: copied, but Android does not list it.
        try FileManager.default.removeItem(at: folder.appending(path: "system/product/priv-app/Phonesky"))
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await #expect(throws: GoogleAppsInstallError.self) {
            try await installer(guest, log: ProgressLog()).run(GoogleAppsPackage(url: folder))
        }
        let steps = await guest.steps
        #expect(steps == ["remount", "stage", "committing", "commit", "restart", "rollback", "restart", "restored"])
        #expect(!steps.contains("committed"))
        #expect(await guest.system.isEmpty)
    }

    /// Android was stopped by force mid-commit: nothing restarts it and
    /// nothing is taken out now; the next start sees it through.
    @Test func anInterruptedCommitWaitsForTheNextStart() async throws {
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await guest.set(holdCommit: true)
        let stopped = Flag()
        let run = Task { try await installer(guest, log: ProgressLog(), interrupted: { stopped.value }).run(GoogleAppsPackage(url: folder)) }
        #expect(await eventually { await guest.commitIsHeld })
        stopped.set()
        await guest.releaseCommit(failing: true)
        await #expect(throws: GoogleAppsInstallError.interrupted) { try await run.value }
        #expect(await guest.steps == ["remount", "stage", "committing", "commit"])
        #expect(await guest.manifest == .partial)

        // The next start: the half-done commit comes out.
        try await installer(guest, log: ProgressLog()).recoverExpectingRestore()
        #expect(await guest.steps.suffix(3) == ["rollback", "restart", "restored"])
        #expect(await guest.system.isEmpty)
        #expect(await guest.manifest == .none)
    }

    /// Stopped by force before the commit (here after the push): nothing
    /// to finish or undo, and the message does not promise otherwise.
    @Test func aForcedStopBeforeTheCommitSaysSo() async throws {
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await #expect(throws: GoogleAppsInstallError.stoppedBeforeCommit) {
            try await installer(guest, log: ProgressLog(), interrupted: { await guest.steps.contains("stage") }).run(GoogleAppsPackage(url: folder))
        }
        #expect(await guest.steps == ["remount", "stage"])
    }

    /// A second package over a finished install could not be undone.
    @Test func aFinishedInstallIsNotInstalledOver() async throws {
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        try await installer(guest, log: ProgressLog()).run(GoogleAppsPackage(url: folder))
        let steps = await guest.steps
        await #expect(throws: AvoError.internalError(GoogleAppsInstaller.alreadyInstalled)) {
            try await installer(guest, log: ProgressLog()).run(GoogleAppsPackage(url: folder))
        }
        #expect(await guest.steps == steps)
    }

    @Test func aCompleteCommitIsKeptAtTheNextStart() async throws {
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await installer(guest, log: ProgressLog()).run(GoogleAppsPackage(url: folder))
        // As if the daemon had quit before it saw Google Play listed.
        try await installer(guest, log: ProgressLog()).recover()
        #expect(await guest.steps.last == "committed")
        #expect(await guest.system.keys.sorted() == Self.installed)

        let untouched = FakeSystemApps(verity: false, overlayReady: true)
        await #expect(throws: GoogleAppsInstallError.untouched) { try await installer(untouched, log: ProgressLog()).recover() }
        #expect(await untouched.steps == ["restored"])
    }

    /// A guest step that never answers gives up instead of holding Android's controls.
    @Test func aHangingStepTimesOut() async throws {
        let folder = try googleAppsPackageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let guest = FakeSystemApps(verity: false, overlayReady: true)
        await guest.set(holdCommit: true)
        var configured = installer(guest, log: ProgressLog())
        configured.limits.commit = .milliseconds(300)
        let slow = configured
        let started = ContinuousClock.now
        let error = await #expect(throws: GoogleAppsInstallError.self) { try await slow.run(GoogleAppsPackage(url: folder)) }
        #expect(ContinuousClock.now - started < .seconds(5))
        guard case .restored(let reason)? = error else { Issue.record("not restored: \(String(describing: error))"); return }
        #expect(reason.contains("timed out"))
        #expect(await guest.steps.contains("rollback"))
        await guest.releaseCommit()
    }
}

extension GoogleAppsInstaller {
    func recoverExpectingRestore() async throws {
        do {
            try await recover()
            Issue.record("recovered without a rollback")
        } catch GoogleAppsInstallError.restored {
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

@Suite struct GoogleAppsDecisionTests {
    @Test func restartsOnlyWhenAndroidLoadedTheFiles() {
        #expect(!GoogleAppsRecovery.restartsAndroid(after: .committing, rescued: false))
        #expect(GoogleAppsRecovery.restartsAndroid(after: .committing, rescued: true))
        #expect(GoogleAppsRecovery.restartsAndroid(after: .booting, rescued: false))
        #expect(GoogleAppsRecovery.restartsAndroid(after: .verifying, rescued: false))
    }

    @Test func anInterruptedInstallIsKeptOnlyWhenCompleteAndListed() {
        #expect(GoogleAppsRecovery.decide(commit: .none, listed: false) == .nothingToUndo)
        #expect(GoogleAppsRecovery.decide(commit: .partial, listed: true) == .rollBack)
        #expect(GoogleAppsRecovery.decide(commit: .complete, listed: false) == .rollBack)
        #expect(GoogleAppsRecovery.decide(commit: .complete, listed: true) == .keep)
    }

    @Test func androidControlsWaitWhileTheInstallChangesAndroid() {
        for action in [GoogleAppsGuard.Action.stop, .restart, .reset, .snapshot] {
            #expect(GoogleAppsGuard.decide(action, installing: false, cancellable: false, force: false) == .allow)
            #expect(GoogleAppsGuard.decide(action, installing: true, cancellable: false, force: false) == .refuse)
            #expect(GoogleAppsGuard.decide(action, installing: true, cancellable: false, force: true) == .allow)
        }
        // Still downloading or reading the package: Android is not touched yet.
        #expect(GoogleAppsGuard.decide(.stop, installing: true, cancellable: true, force: false) == .allow)
        #expect(GoogleAppsGuard.decide(.restart, installing: true, cancellable: true, force: false) == .allow)
        #expect(GoogleAppsGuard.decide(.reset, installing: true, cancellable: true, force: false) == .cancelInstall)
    }

    @Test func onlyTheUsersOwnStopIsACancel() {
        let id = UUID()
        let cancelled = DaemonCore.googleAppsEnd(CancellationError(), id: id, cancelRequested: true)
        #expect(cancelled.phase == .cancelled)
        #expect(cancelled.message == "Install stopped. Android was not changed.")
        let stopped = DaemonCore.googleAppsEnd(CancellationError(), id: id, cancelRequested: false)
        #expect(stopped.phase == .failed)
        let restored = DaemonCore.googleAppsEnd(GoogleAppsInstallError.restored(reason: "x"), id: id, cancelRequested: true)
        #expect(restored.phase == .failed)
        #expect(restored.message?.hasPrefix("Google apps were not installed; Android was restored.") == true)
    }

    @Test func restoreReasonsReadAsSentences() {
        #expect(GoogleAppsInstaller.describe(AvoError.installFailed("the install did not finish")) == "the install did not finish")
        #expect(GoogleAppsInstaller.sentence("the install did not finish") == "The install did not finish.")
        #expect(GoogleAppsInstaller.sentence("Android’s answer timed out.") == "Android’s answer timed out.")
        #expect(GoogleAppsInstaller.sentence("") == "")
    }

    @Test func progressSaysWhenAndroidIsBeingChanged() {
        let id = UUID()
        #expect(!GoogleAppsProgress(id: id, phase: .downloading).changesAndroid)
        #expect(GoogleAppsProgress(id: id, phase: .installing).changesAndroid)
        #expect(GoogleAppsProgress(id: id, phase: .restoring).changesAndroid)
        #expect(!GoogleAppsProgress(id: id, phase: .cancelled).changesAndroid)
        #expect(GoogleAppsProgress(id: id, phase: .cancelled).isDone)
    }
}

@Suite struct DeadlineTests {
    @Test func passesTheResultOn() async throws {
        #expect(try await Deadline.run(.seconds(5), what: "x") { 42 } == 42)
        await #expect(throws: AvoError.installFailed("no")) {
            try await Deadline.run(.seconds(5), what: "x") { throw AvoError.installFailed("no") }
        }
    }

    @Test func leavesAStepThatIgnoresCancellationBehind() async throws {
        let started = ContinuousClock.now
        await #expect(throws: AvoError.timedOut("the step")) {
            try await Deadline.run(.milliseconds(200), what: "the step") {
                await Task.detached { try? await Task.sleep(for: .seconds(5)) }.value
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func countsFromTheLastHeartbeat() async throws {
        let heartbeat = Heartbeat()
        // 2 s of work against a 1 s deadline: only the beats keep it going
        // (wide margins: the suite runs this beside heavy tests).
        try await Deadline.run(.seconds(1), what: "push", heartbeat: heartbeat) {
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(250))
                heartbeat.beat()
            }
        }
        await #expect(throws: AvoError.timedOut("push")) {
            try await Deadline.run(.seconds(1), what: "push", heartbeat: heartbeat) {
                heartbeat.beat()
                try await Task.sleep(for: .seconds(3))
            }
        }
    }
}

@Suite struct GoogleAppsGuestParsingTests {
    @Test func readsVerityState() {
        #expect(HostAgent.verityEnabled(in: "verity is enabled on slot with suffix _a.\n") == true)
        #expect(HostAgent.verityEnabled(in: "verity is disabled on slot with suffix _a.\n") == false)
        #expect(HostAgent.verityEnabled(in: "avbctl: not found") == nil)
    }

    @Test func noticesRemountWantsAReboot() {
        let first = """
            Disabling verity for /system
            Using overlayfs for /product
            Now reboot your device for settings to take effect
            """
        #expect(HostAgent.remountWantsReboot(first))
        #expect(!HostAgent.remountWantsReboot("Using overlayfs for /product\nremount succeeded\n"))
    }

    @Test func readsFreeSpace() {
        let df = """
            Filesystem      1K-blocks   Used Available Use% Mounted on
            overlay           8386560 910100   7476460  11% /product
            """
        #expect(HostAgent.availableBytes(df: df) == 7_476_460 * 1024)
        #expect(HostAgent.availableBytes(df: "df: /nope: No such file or directory") == nil)
    }

    @Test func readsVersionNames() {
        #expect(HostAgent.versionName(dumpsys: "    versionName=53.5.48-34 [0] [PR] 995634172\n") == "53.5.48-34")
        #expect(HostAgent.versionName(dumpsys: "    versionName=26.40.32 (260400-995630914)\n") == "26.40.32")
        #expect(HostAgent.versionName(dumpsys: "") == nil)
    }

    @Test func readsTheAndroidID() {
        #expect(HostAgent.androidID(contentQuery: "Row: 0 name=android_id, value=3641621413558569340\n") == "3641621413558569340")
        #expect(HostAgent.androidID(contentQuery: "No result found.\n") == nil)
        #expect(HostAgent.androidID(value: "3641621413558569340\n") == "3641621413558569340")
        #expect(HostAgent.androidID(value: "0") == nil)
        #expect(HostAgent.androidID(value: "Error: no such table: main") == nil)
    }
}

@Suite struct GoogleAppsDaemonTests {
    @Test func onlyTheCacheIsRead() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "avo-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = AvoPaths(home: home).googleAppsCache
        let copy = cache.appending(path: "\(UUID().uuidString)/MindTheGapps.zip")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: copy)

        #expect(try DaemonCore.cachedItem(copy.path, in: cache).lastPathComponent == "MindTheGapps.zip")
        #expect(throws: AvoError.self) { try DaemonCore.cachedItem(home.appending(path: "Downloads/MindTheGapps.zip").path, in: cache) }
        #expect(throws: AvoError.self) { try DaemonCore.cachedItem(cache.path + "/../../Downloads/x.zip", in: cache) }
        #expect(throws: AvoError.self) { try DaemonCore.cachedItem(cache.appending(path: "missing.zip").path, in: cache) }

        // The copy goes with its folder; downloads stay apart.
        DaemonCore.removeCopy(copy, cache: cache)
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: cache.path))

        // Leftovers of an install that never finished go; downloads and the current copy stay.
        let stale = cache.appending(path: "stale")
        let current = cache.appending(path: "current/MindTheGapps.zip")
        let download = cache.appending(path: "downloads/MindTheGapps.zip")
        for file in [stale.appending(path: "x.zip"), current, download] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        DaemonCore.pruneCopies(in: cache, keeping: current)
        #expect(FileManager.default.fileExists(atPath: stale.path)) // not an hour old yet
        DaemonCore.pruneCopies(in: cache, keeping: current, now: Date() + 7200)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: download.path))
    }

    @Test func enginesWithoutSystemAccessSayNotSupported() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        let (panel, _) = await harness.connect(.controlPanel)
        let status = try await harness.core.googleAppsStatus(client: panel)
        #expect(status == GoogleAppsStatus(supported: false))
        let request = GoogleAppsInstallRequest(source: .github(url: GoogleAppsDownloaderTests.link))
        await #expect(throws: AvoError.self) { try await harness.core.installGoogleApps(request, client: panel) }
        let (shim, _) = await harness.connect(.shim(package: "dev.avo.hello"))
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.googleAppsStatus(client: shim) }
    }
}

/// GitHub without the network: the API's release answer, the asset and its
/// `.sha256sum`, served to the downloader's URLSession.
final class FakeGitHub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (Int, Data)] = [:]

    static func serve(_ url: String, status: Int = 200, _ body: Data) { lock.withLock { responses[url] = (status, body) } }
    static func reset() { lock.withLock { responses.removeAll() } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeGitHub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let (status, body) = Self.lock.withLock { Self.responses[url.absoluteString] } ?? (404, Data("Not Found".utf8))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct GoogleAppsDownloaderTests {
    /// A release link as people paste it.
    static let link = "https://github.com/MindTheGapps/17.0.0-arm64/releases/latest"
    static let api = "https://api.github.com/repos/MindTheGapps/17.0.0-arm64/releases/latest"
    static let base = "https://github.com/MindTheGapps/17.0.0-arm64/releases/download/T1/"
    static let package = Data((0..<300_000).map { UInt8($0 % 251) })

    static func release(digest: String?, sums: Bool = false) -> Data {
        var assets = [#"{"name": "MindTheGapps-T1.zip", "size": \#(package.count), "digest": \#(digest.map { "\"\($0)\"" } ?? "null"), "browser_download_url": "\#(base)MindTheGapps-T1.zip"}"#]
        if sums { assets.append(#"{"name": "MindTheGapps-T1.zip.sha256sum", "size": 90, "browser_download_url": "\#(base)MindTheGapps-T1.zip.sha256sum"}"#) }
        return Data(#"{"tag_name": "T1", "assets": [\#(assets.joined(separator: ","))]}"#.utf8)
    }

    static var sha: String { SHA256Hex.of(package) }

    private func downloader() throws -> (GoogleAppsDownloader, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "avo-download-\(UUID().uuidString)")
        return (GoogleAppsDownloader(directory: directory, session: FakeGitHub.session()), directory)
    }

    @Test func downloadsAndChecksTheDigest() async throws {
        FakeGitHub.reset()
        FakeGitHub.serve(Self.api, Self.release(digest: "sha256:" + Self.sha))
        FakeGitHub.serve(Self.base + "MindTheGapps-T1.zip", Self.package)
        let (downloader, directory) = try downloader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let verified = ProgressLog()
        let file = try await downloader.download(Self.link, verifying: {
            verified.append(GoogleAppsProgress(id: UUID(), phase: .verifying))
        }) { _, _ in }
        #expect(file.lastPathComponent == "MindTheGapps-T1.zip")
        #expect(try Data(contentsOf: file) == Self.package)
        #expect(verified.items.count == 1)

        // Already there and intact: not downloaded again.
        FakeGitHub.serve(Self.base + "MindTheGapps-T1.zip", status: 500, Data())
        #expect(try await downloader.download(Self.link, verifying: {}) { _, _ in } == file)
    }

    @Test func usesTheSumFileWithoutADigest() async throws {
        FakeGitHub.reset()
        FakeGitHub.serve(Self.api, Self.release(digest: nil, sums: true))
        FakeGitHub.serve(Self.base + "MindTheGapps-T1.zip", Self.package)
        FakeGitHub.serve(Self.base + "MindTheGapps-T1.zip.sha256sum", Data("\(Self.sha)  MindTheGapps-T1.zip\n".utf8))
        let (downloader, directory) = try downloader()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await downloader.download(Self.link, verifying: {}) { _, _ in }
        #expect(try Data(contentsOf: file) == Self.package)
    }

    @Test func refusesWhatDoesNotMatchOrCannotBeChecked() async throws {
        FakeGitHub.reset()
        FakeGitHub.serve(Self.api, Self.release(digest: "sha256:" + String(repeating: "0", count: 64)))
        FakeGitHub.serve(Self.base + "MindTheGapps-T1.zip", Self.package)
        let (downloader, directory) = try downloader()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: GoogleAppsError.checksumMismatch("MindTheGapps-T1.zip")) {
            try await downloader.download(Self.link, verifying: {}) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "MindTheGapps-T1.zip").path))

        FakeGitHub.serve(Self.api, Self.release(digest: nil))
        await #expect(throws: GoogleAppsError.noChecksum("MindTheGapps-T1.zip")) {
            try await downloader.download(Self.link, verifying: {}) { _, _ in }
        }

        FakeGitHub.reset()
        await #expect(throws: GoogleAppsError.download(GoogleAppsDownloader.describe(status: 404, url: Self.link))) {
            try await downloader.download(Self.link, verifying: {}) { _, _ in }
        }
    }
}
