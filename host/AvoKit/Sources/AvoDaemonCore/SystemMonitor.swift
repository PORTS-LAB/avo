import AvoKit
import Foundation
import IOKit

// System Status (Control Panel › System Status): what Android and its apps
// use, like Activity Monitor. Sampled only while a Control Panel watches
// (`systemActivity(watch:)`), every 2 seconds:
//
// - Android's processes ride along with HostAgent's own look (`lookAround`,
//   one shell call every 2 s anyway): toybox `ps` and one `grep` over /proc
//   (GuestActivity.swift). Nothing is asked of a paused Android, which keeps
//   it paused; the list is empty meanwhile.
// - The engine's CPU and memory (proc_pidinfo), the Mac's GPU and the
//   engine's GPU time (IOKit, no entitlement needed), and the frames each
//   app's windows show come from the Mac.
//
// GPU time per Android app is not measured: every app's graphics run in the
// engine's one renderer (gfxstream), and their commands reach it through
// shared-memory rings that the virtio-gpu queue never sees. Per guest
// context, fences and SUBMIT_3D counts follow frames and wake-ups, not GPU
// work (measured with glbench: the same 580 submits/s at 2.7 times the
// load), and gfxstream's threads carry no names to tell them apart.

/// An engine that can say what Android's processes use.
protocol ActivityEngine: VMEngine {
    /// While `sink` is set, Android's processes are sampled with the agent's
    /// 2-second look and handed to it (also after Android restarts).
    func sampleProcesses(_ sink: (@Sendable (GuestActivity.Sample) -> Void)?) async
    /// Frames published so far for each package with an Avo window (its windows together).
    func windowFrames() async -> [String: UInt64]
    /// The engine process, for its GPU time.
    var engineProcessID: pid_t? { get }
}

/// The daemon's side of System Status (`DaemonCore.systemMonitor`).
struct SystemMonitorState: Sendable {
    /// Android's processes are being sampled.
    var sampling = false
    var timer: Task<Void, Never>?
    /// The newest guest sample and what came of it.
    var guest: GuestActivity.Sample?
    var processes: [AndroidProcess] = []
    var androidCPU: Double?
    /// The previous readings of the counters that only make sense as rates.
    var engineCPU: (time: Duration, at: ContinuousClock.Instant)?
    var engineGPU: (time: UInt64, at: ContinuousClock.Instant)?
    var frames: (counts: [String: UInt64], at: ContinuousClock.Instant)?

    /// A sample this recent stands for `ps` (DaemonCore's running apps).
    func hasFreshProcesses(now: ContinuousClock.Instant = .now) -> Bool {
        guest.map { now - $0.at < .seconds(5) } ?? false
    }
}

extension DaemonCore {
    /// What Android and its apps use now; `watch`: the caller hears it every
    /// 2 seconds (`DaemonEvent.systemActivity`) until it says false or goes.
    /// Control Panels only.
    public func systemActivity(watch: Bool, client: ClientID) async throws -> SystemActivity {
        guard role(of: client) == .controlPanel else { throw AvoError.unauthorizedCaller }
        if watch { activityWatchers.insert(client) } else { activityWatchers.remove(client) }
        await updateSampling()
        return await composeActivity()
    }

    /// Starts or stops the sampling as watchers come and go.
    func updateSampling() async {
        let wanted = !activityWatchers.isEmpty
        guard wanted != systemMonitor.sampling else { return }
        let engine = dependencies.engine as? any ActivityEngine
        guard wanted else {
            systemMonitor.timer?.cancel()
            systemMonitor = SystemMonitorState()
            await engine?.sampleProcesses(nil)
            return
        }
        systemMonitor.sampling = true
        // Without guest samples (Android paused, stopped or starting) the
        // Mac's side still updates.
        systemMonitor.timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.monitorTick()
            }
        }
        await engine?.sampleProcesses { [weak self] sample in
            Task { await self?.ingest(sample) }
        }
    }

    private func ingest(_ sample: GuestActivity.Sample) async {
        guard systemMonitor.sampling else {
            // Watching stopped while it started (the agent heard the two in
            // the other order): it stops sampling now.
            await (dependencies.engine as? any ActivityEngine)?.sampleProcesses(nil)
            return
        }
        let packages = Set(await registry.all().map(\.package))
        let windows = Set(appActivity().filter { $0.value == .open }.keys)
        let previous = systemMonitor.guest.flatMap { sample.at - $0.at < .seconds(10) ? $0 : nil }
        systemMonitor.processes = GuestActivity.processes(from: previous, to: sample, packages: packages, windows: windows)
        systemMonitor.androidCPU = previous.flatMap { GuestActivity.androidCPU(from: $0, to: sample) }
        systemMonitor.guest = sample
        // The same answer `ps -A` gives the running apps' poll, which waits meanwhile.
        processesSampled(Set(systemMonitor.processes.compactMap(\.package)))
        publishSystemActivity(await composeActivity())
    }

    /// Every 2 s: the Mac's side alone, unless the guest's samples bring it.
    private func monitorTick() async {
        guard systemMonitor.sampling else { return }
        if let guest = systemMonitor.guest, ContinuousClock.now - guest.at < .milliseconds(2500) { return }
        publishSystemActivity(await composeActivity())
    }

    private func publishSystemActivity(_ activity: SystemActivity) {
        for id in activityWatchers { send(.systemActivity(activity), toClient: id) }
    }

    /// Everything System Status shows, with rates since the last time.
    private func composeActivity() async -> SystemActivity {
        let now = ContinuousClock.now
        let engine = dependencies.engine as? any ActivityEngine
        var activity = SystemActivity(date: Date())
        if let usage = await (dependencies.engine as? any PausableEngine)?.activity(), let time = usage.cpuTime {
            if let last = systemMonitor.engineCPU, now > last.at { activity.engineCPU = max(0, (time - last.time) / (now - last.at) * 100) }
            systemMonitor.engineCPU = (time, now)
            activity.engineMemory = usage.residentBytes
        } else {
            systemMonitor.engineCPU = nil
        }
        let gpu = MacGPU.read(processTimeOf: engine?.engineProcessID)
        activity.macGPU = gpu.utilization
        if let time = gpu.processTime {
            if let last = systemMonitor.engineGPU, now > last.at, time >= last.time {
                activity.engineGPU = min(100, Double(time - last.time) / 1e9 / ((now - last.at) / .seconds(1)) * 100)
            }
            systemMonitor.engineGPU = (time, now)
        } else {
            systemMonitor.engineGPU = nil
        }

        guard await vm.status.state == .running, systemMonitor.hasFreshProcesses(now: now), let guest = systemMonitor.guest else {
            systemMonitor.frames = nil
            return activity
        }
        activity.androidCPU = systemMonitor.androidCPU
        activity.androidCores = guest.cores > 0 ? guest.cores : nil
        if let total = guest.memoryTotal, let available = guest.memoryAvailable, available <= total {
            activity.androidMemoryTotal = total
            activity.androidMemoryUsed = total - available
        }
        var processes = systemMonitor.processes
        if let counts = await engine?.windowFrames() {
            if let previous = systemMonitor.frames, now > previous.at {
                let seconds = (now - previous.at) / .seconds(1)
                for index in processes.indices {
                    let name = processes[index].name
                    guard processes[index].package == name, let count = counts[name], let old = previous.counts[name],
                          count >= old else { continue }
                    processes[index].fps = (Double(count - old) / seconds * 10).rounded() / 10
                }
            }
            systemMonitor.frames = (counts, now)
        }
        activity.processes = processes
        return activity
    }
}

/// The Mac's GPU from IOKit, without entitlements: how busy it is
/// (IOAccelerator's `PerformanceStatistics`), and a process's GPU time so
/// far (the `AppUsage` of its AGXDeviceUserClients, nanoseconds; what
/// Activity Monitor's % GPU is made of). About a millisecond.
enum MacGPU {
    struct Reading: Equatable {
        var utilization: Double?
        var processTime: UInt64?
    }

    static func read(processTimeOf pid: pid_t?) -> Reading {
        var reading = Reading()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return reading
        }
        defer { IOObjectRelease(iterator) }
        let creator = pid.map { "pid \($0)," }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            if let stats = property(service, "PerformanceStatistics") as? [String: Any],
               let busy = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                reading.utilization = max(reading.utilization ?? 0, min(100, busy))
            }
            guard let creator else { continue }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            var child = IOIteratorNext(children)
            while child != 0 {
                if (property(child, "IOUserClientCreator") as? String)?.hasPrefix(creator) == true {
                    reading.processTime = (reading.processTime ?? 0) + gpuTime(in: property(child, "AppUsage"))
                }
                IOObjectRelease(child)
                child = IOIteratorNext(children)
            }
            IOObjectRelease(children)
        }
        return reading
    }

    /// `AppUsage`: `[{API, accumulatedGPUTime, lastSubmittedTime}]`.
    static func gpuTime(in usage: Any?) -> UInt64 {
        guard let entries = usage as? [[String: Any]] else { return 0 }
        return entries.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }.reduce(0, &+)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
