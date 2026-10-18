import Foundation

/// The Control Panel's System Status: what Android and its apps use, from
/// the daemon every 2 seconds while a Control Panel watches
/// (`systemActivity(watch:)`, `DaemonEvent.systemActivity`) and never
/// otherwise. Android's processes come from one shell call that rides along
/// with the daemon's own look at Android (HostAgent's `lookAround`); a paused
/// Android is not woken for it.
public struct SystemActivity: Codable, Equatable, Sendable {
    /// When the daemon put it together.
    public var date: Date
    /// The engine process on the Mac (avo-vmm, which runs Android and, in
    /// GPU mode, its renderer): CPU in percent of one core, as Activity
    /// Monitor shows it, and its resident memory.
    public var engineCPU: Double?
    public var engineMemory: UInt64?
    /// The engine's share of the Mac's GPU time in percent (IOKit's
    /// per-process GPU time, what Activity Monitor's % GPU shows); nil
    /// before a second sample or when macOS does not say.
    public var engineGPU: Double?
    /// How busy the Mac's GPU is, all apps together (IOAccelerator's
    /// "Device Utilization %"), 0...100.
    public var macGPU: Double?
    /// Android's CPU: how busy all its cores are together, 0...100, and how
    /// many it has.
    public var androidCPU: Double?
    public var androidCores: Int?
    /// Android's memory in bytes (MemTotal, and MemTotal - MemAvailable).
    public var androidMemoryUsed: UInt64?
    public var androidMemoryTotal: UInt64?
    /// Android's processes (empty while it is not running or paused).
    public var processes: [AndroidProcess]

    public init(date: Date = Date(), engineCPU: Double? = nil, engineMemory: UInt64? = nil, engineGPU: Double? = nil,
                macGPU: Double? = nil, androidCPU: Double? = nil, androidCores: Int? = nil, androidMemoryUsed: UInt64? = nil,
                androidMemoryTotal: UInt64? = nil, processes: [AndroidProcess] = []) {
        self.date = date
        self.engineCPU = engineCPU
        self.engineMemory = engineMemory
        self.engineGPU = engineGPU
        self.macGPU = macGPU
        self.androidCPU = androidCPU
        self.androidCores = androidCores
        self.androidMemoryUsed = androidMemoryUsed
        self.androidMemoryTotal = androidMemoryTotal
        self.processes = processes
    }
}

/// One of Android's processes, as System Status lists it.
public struct AndroidProcess: Codable, Equatable, Sendable, Identifiable {
    /// What Android's ActivityManager makes of it (its `oom_score_adj`), or
    /// what an Avo window shows of it.
    public enum State: String, Codable, Sendable, Comparable, CaseIterable {
        /// An Avo window shows it (an app's main process).
        case window
        /// Android's top app (adj 0).
        case foreground
        /// Visible or perceptible: on a display, playing, a foreground service (adj 1...299).
        case visible
        /// Services and recently used apps (adj 300...899).
        case background
        /// Kept for a quick start; Android may end it for memory (adj 900...).
        case cached
        /// Cached and frozen by Android: it uses no CPU at all.
        case frozen
        /// Android's own: daemons, system_server, persistent apps (adj < 0).
        case system

        /// Busiest first.
        public static func < (lhs: State, rhs: State) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }

        /// From `oom_score_adj` (ProcessList's levels).
        public init(oomScoreAdj adj: Int) {
            switch adj {
            case ..<0: self = .system
            case 0: self = .foreground
            case 1..<300: self = .visible
            case 300..<900: self = .background
            default: self = .cached
            }
        }
    }

    public var pid: Int
    /// Android's name for it: the package for an app's main process,
    /// `package:name` for its others, a daemon's name (`surfaceflinger`).
    public var name: String
    public var uid: Int
    /// The installed app it belongs to (nil for Android's own).
    public var package: String?
    /// CPU in percent of one core, since the previous sample.
    public var cpu: Double
    /// Resident memory (RSS: pages it shares are counted in each process).
    public var memory: UInt64
    public var state: State
    /// Frames per second its Avo windows show (an app's main process only).
    /// GPU time per app is not known: all of Android's graphics run in the
    /// engine's one renderer (SystemMonitor.swift).
    public var fps: Double?

    public var id: Int { pid }

    public init(pid: Int, name: String, uid: Int, package: String? = nil, cpu: Double = 0, memory: UInt64 = 0,
                state: State = .background, fps: Double? = nil) {
        self.pid = pid
        self.name = name
        self.uid = uid
        self.package = package
        self.cpu = cpu
        self.memory = memory
        self.state = state
        self.fps = fps
    }

    /// `com.example.app:remote` → `com.example.app`.
    public static func packageName(ofProcess name: String) -> String {
        String(name.split(separator: ":", maxSplits: 1).first ?? Substring(name))
    }
}

/// An installed app with its processes added up (System Status' Apps view).
public struct AppActivityTotal: Equatable, Sendable, Identifiable {
    public var package: String
    public var processes: Int
    public var cpu: Double
    public var memory: UInt64
    /// The busiest state of its processes.
    public var state: AndroidProcess.State
    public var fps: Double?

    public var id: String { package }

    /// One total per installed app that has a process.
    public static func totals(of processes: [AndroidProcess]) -> [AppActivityTotal] {
        var totals: [String: AppActivityTotal] = [:]
        for process in processes {
            guard let package = process.package else { continue }
            var total = totals[package] ?? AppActivityTotal(package: package, processes: 0, cpu: 0, memory: 0, state: process.state)
            total.processes += 1
            total.cpu += process.cpu
            total.memory += process.memory
            total.state = min(total.state, process.state)
            if let fps = process.fps { total.fps = max(total.fps ?? 0, fps) }
            totals[package] = total
        }
        return Array(totals.values)
    }
}

/// The last minute of a figure for System Status' sparklines (30 samples, 2 s apart).
public struct ActivityHistory: Equatable, Sendable {
    public static let length = 30
    public private(set) var values: [Double] = []

    public init() {}

    /// Adds a sample (nil: unknown, drawn as a gap at 0); the oldest goes once full.
    public mutating func append(_ value: Double?) {
        values.append(value ?? 0)
        if values.count > Self.length { values.removeFirst(values.count - Self.length) }
    }

    public mutating func removeAll() {
        values = []
    }
}
