import Foundation
import Testing
@testable import AvoKit

/// System Status' model: apps added up from their processes, the
/// sparklines' minute, and the XPC payload.
@Suite struct SystemActivityTests {
    @Test func anAppIsItsProcessesAddedUp() {
        let processes = [
            AndroidProcess(pid: 10, name: "com.example.game", uid: 10123, package: "com.example.game", cpu: 40, memory: 300,
                           state: .window, fps: 59.8),
            AndroidProcess(pid: 11, name: "com.example.game:remote", uid: 10123, package: "com.example.game", cpu: 2.5, memory: 50,
                           state: .visible),
            AndroidProcess(pid: 20, name: "com.example.mail", uid: 10124, package: "com.example.mail", cpu: 0, memory: 90, state: .frozen),
            // Android's own: in no app.
            AndroidProcess(pid: 30, name: "surfaceflinger", uid: 1000, cpu: 12, memory: 40, state: .system),
        ]
        let totals = Dictionary(uniqueKeysWithValues: AppActivityTotal.totals(of: processes).map { ($0.package, $0) })
        #expect(totals.count == 2)
        let game = totals["com.example.game"]
        #expect(game?.processes == 2)
        #expect(game?.cpu == 42.5)
        #expect(game?.memory == 350)
        #expect(game?.state == .window, "the busiest state of its processes")
        #expect(game?.fps == 59.8)
        #expect(totals["com.example.mail"]?.fps == nil)
        #expect(totals["com.example.mail"]?.state == .frozen)
    }

    @Test func processesNameTheirPackage() {
        #expect(AndroidProcess.packageName(ofProcess: "com.example.game:remote") == "com.example.game")
        #expect(AndroidProcess.packageName(ofProcess: "surfaceflinger") == "surfaceflinger")
    }

    @Test func theSparklinesKeepAMinute() {
        var history = ActivityHistory()
        for value in 0..<40 { history.append(Double(value)) }
        #expect(history.values.count == ActivityHistory.length)
        #expect(history.values.first == 10)
        #expect(history.values.last == 39)
        history.append(nil)
        #expect(history.values.last == 0)
        history.removeAll()
        #expect(history.values.isEmpty)
    }

    @Test func travelsAsJSON() throws {
        let activity = SystemActivity(date: Date(timeIntervalSince1970: 1_792_000_000), engineCPU: 37.5, engineMemory: 4 << 30,
                                      engineGPU: 12, macGPU: 54, androidCPU: 20, androidCores: 4, androidMemoryUsed: 2 << 30,
                                      androidMemoryTotal: 4 << 30,
                                      processes: [AndroidProcess(pid: 1, name: "init", uid: 0, state: .system)])
        let event = DaemonEvent.systemActivity(activity)
        #expect(try AvoXPC.decode(DaemonEvent.self, from: AvoXPC.encode(event)) == event)
    }
}
