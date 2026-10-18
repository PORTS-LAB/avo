import AvoKit
import Foundation

/// Android's side of System Status: one shell call's worth of what its
/// processes use, read along with HostAgent's 2-second look while a Control
/// Panel watches (SystemMonitor.swift), and the arithmetic that turns two
/// such samples into CPU percentages. No `dumpsys`: toybox `ps` and one
/// `grep` over /proc, both as the shell user.
enum GuestActivity {
    /// The commands, after the look's own (their outputs between `echo
    /// <marker>` lines): the processes with their CPU time and memory, then
    /// Android's CPU and memory, every process's `oom_score_adj` and the
    /// freezer's state of every app process (cgroup v2: under `apps/` since
    /// Android 16, at the top before), in one grep with the file name before
    /// each line. About 13 ms of Android's CPU and 35 KB (140 processes).
    static func command(marker: String) -> String {
        "ps -A -o PID,PPID,UID,TIME+,RSS,NAME; echo \(marker); "
            + "grep -sE '^(cpu|MemTotal:|MemAvailable:|-?[0-9]+$)' /proc/stat /proc/meminfo /proc/[0-9]*/oom_score_adj "
            + "/sys/fs/cgroup/apps/uid_*/pid_*/cgroup.freeze /sys/fs/cgroup/uid_*/pid_*/cgroup.freeze"
    }

    /// How many sections `command` adds to the look's output.
    static let sections = 2

    struct Process: Equatable, Sendable {
        var pid: Int
        var ppid: Int
        var uid: Int
        /// CPU time used so far, in hundredths of a second (`TIME+`).
        var cpuTime: Int
        var residentKiB: UInt64
        var name: String
        var oomScoreAdj: Int?
        var frozen = false
    }

    /// One look at Android's processes.
    struct Sample: Equatable, Sendable {
        var at: ContinuousClock.Instant
        var processes: [Process] = []
        /// The `cpu` line's busy and total jiffies, and the `cpuN` lines.
        var cpuBusy: UInt64 = 0
        var cpuTotal: UInt64 = 0
        var cores = 0
        var memoryTotal: UInt64?
        var memoryAvailable: UInt64?
    }

    /// The two sections `command` printed.
    static func sample(ps: String, files: String, at: ContinuousClock.Instant) -> Sample {
        var sample = Sample(at: at)
        var processes = parseProcesses(ps)
        var adj: [Int: Int] = [:]
        var frozen: Set<Int> = []
        for line in files.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let file = line[..<colon]
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch file {
            case "/proc/stat":
                parseCPULine(value, into: &sample)
            case "/proc/meminfo":
                // "MemTotal:       4012345 kB" (the grep keeps the key's colon).
                let parts = value.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, let kib = UInt64(parts[1]) else { continue }
                if parts[0] == "MemTotal:" { sample.memoryTotal = kib * 1024 }
                if parts[0] == "MemAvailable:" { sample.memoryAvailable = kib * 1024 }
            default:
                if file.hasPrefix("/proc/"), file.hasSuffix("/oom_score_adj"),
                   let pid = Int(file.dropFirst("/proc/".count).dropLast("/oom_score_adj".count)), let value = Int(value) {
                    adj[pid] = value
                } else if file.hasSuffix("/cgroup.freeze"), value == "1", let range = file.range(of: "/pid_"),
                          let pid = Int(file[range.upperBound...].prefix { $0.isNumber }) {
                    frozen.insert(pid)
                }
            }
        }
        for index in processes.indices {
            processes[index].oomScoreAdj = adj[processes[index].pid]
            processes[index].frozen = frozen.contains(processes[index].pid)
        }
        // Gone before the grep (`ps` itself, a short-lived command).
        if !adj.isEmpty { processes.removeAll { $0.oomScoreAdj == nil } }
        sample.processes = processes
        return sample
    }

    /// `ps -A -o PID,PPID,UID,TIME+,RSS,NAME`, without the kernel's threads.
    static func parseProcesses(_ output: String) -> [Process] {
        var processes: [Process] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int(fields[0]), let ppid = Int(fields[1]), let uid = Int(fields[2]),
                  let time = centiseconds(fields[3]), let rss = UInt64(fields[4]) else { continue }
            // kthreadd and its children.
            guard pid != 2, ppid != 2 else { continue }
            let name = fields[5].trimmingCharacters(in: .whitespaces)
            processes.append(Process(pid: pid, ppid: ppid, uid: uid, cpuTime: time, residentKiB: rss, name: name))
        }
        return processes
    }

    /// toybox's `TIME+`: `mm:ss.hh` with the minutes going past 59, also
    /// `hh:mm:ss.hh` and `d-hh:mm:ss.hh`. Hundredths of a second.
    static func centiseconds(_ text: Substring) -> Int? {
        var days = 0
        var rest = text
        if let dash = text.firstIndex(of: "-") {
            guard let d = Int(text[..<dash]) else { return nil }
            days = d
            rest = text[text.index(after: dash)...]
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let last = parts.last else { return nil }
        let seconds = last.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = Int(seconds[0]) else { return nil }
        var hundredths = 0
        if seconds.count == 2 {
            let digits = seconds[1].prefix(2)
            guard let fraction = Int(digits) else { return nil }
            hundredths = digits.count == 1 ? fraction * 10 : fraction
        }
        var total = whole
        var scale = 60
        for part in parts.dropLast().reversed() {
            guard let value = Int(part) else { return nil }
            total += value * scale
            scale *= 60
        }
        return ((days * 86_400) + total) * 100 + hundredths
    }

    /// `cpu  user nice system idle iowait irq softirq steal …` and `cpuN …`.
    private static func parseCPULine(_ line: String, into sample: inout Sample) {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let label = fields.first, label.hasPrefix("cpu") else { return }
        if label != "cpu" {
            sample.cores += 1
            return
        }
        let values = fields.dropFirst().prefix(8).compactMap { UInt64($0) }
        guard values.count >= 5 else { return }
        let total = values.reduce(0, +)
        sample.cpuTotal = total
        sample.cpuBusy = total - values[3] - values[4] // idle, iowait
    }

    // MARK: Two samples

    /// Seconds between two samples by Android's own clock: its cores' jiffies
    /// (USER_HZ, 100 a second, the unit of `TIME+` too), which adb's delays
    /// do not shift; the Mac's clock without them.
    static func elapsed(from previous: Sample, to now: Sample) -> Double {
        if now.cores > 0, now.cpuTotal > previous.cpuTotal, previous.cpuTotal > 0 {
            return Double(now.cpuTotal - previous.cpuTotal) / Double(now.cores) / 100
        }
        return (now.at - previous.at) / .seconds(1)
    }

    /// Android's CPU from `previous` to `now`: busy share of all its cores, 0...100.
    static func androidCPU(from previous: Sample, to now: Sample) -> Double? {
        guard now.cpuTotal > previous.cpuTotal, now.cpuBusy >= previous.cpuBusy else { return nil }
        return min(100, Double(now.cpuBusy - previous.cpuBusy) / Double(now.cpuTotal - previous.cpuTotal) * 100)
    }

    /// The processes of `now` with their CPU since `previous` (percent of one
    /// core; 0 for a process `previous` did not have, or a pid reused since).
    /// `packages`: the installed apps; `windows`: packages an Avo window shows.
    static func processes(from previous: Sample?, to now: Sample, packages: Set<String>,
                          windows: Set<String>) -> [AndroidProcess] {
        let seconds = previous.map { elapsed(from: $0, to: now) } ?? 0
        let before = Dictionary((previous?.processes ?? []).map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return now.processes.map { process in
            var cpu = 0.0
            if seconds > 0, let old = before[process.pid], old.name == process.name, process.cpuTime >= old.cpuTime {
                cpu = Double(process.cpuTime - old.cpuTime) / 100 / seconds * 100
            }
            let package = AndroidProcess.packageName(ofProcess: process.name)
            let installed = packages.contains(package) ? package : nil
            var state = process.oomScoreAdj.map(AndroidProcess.State.init(oomScoreAdj:)) ?? .system
            if process.frozen { state = .frozen }
            if let installed, installed == process.name, windows.contains(installed) { state = .window }
            return AndroidProcess(pid: process.pid, name: process.name, uid: process.uid, package: installed,
                                  cpu: (cpu * 10).rounded() / 10, memory: process.residentKiB * 1024, state: state)
        }
    }
}
