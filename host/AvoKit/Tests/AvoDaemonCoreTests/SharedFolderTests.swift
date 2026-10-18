import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct SharedFolderTests {
    struct Scratch {
        let root: URL
        let paths: AvoPaths

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "avo-shared-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
            try paths.createDirectories()
        }

        func folder(_ name: String) throws -> URL {
            let url = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func avoVMMServesTheFolderOnlyWhenSharingIsOn() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let image = scratch.root.appending(path: "image", directoryHint: .isDirectory)
        func arguments(_ config: VMConfig) -> [String] {
            let launch = EngineLaunch(config: config, paths: scratch.paths,
                                      image: AndroidImage(schema: 1, version: "v", sdk: 37, kernel: "boot.img", initrd: nil, partitions: [],
                                                          overlayStock: "", overlayRooted: "", files: [], directory: image),
                                      bootConfigDisk: scratch.paths.vm.appending(path: "avo_config.img"), profile: nil)
            return VMMEngine.arguments(images: image, launch: launch)
        }
        #expect(!arguments(VMConfig()).contains("--shared-dir"))
        #expect(!arguments(VMConfig(shareFolder: true)).contains("--shared-dir"), "no folder chosen")
        #expect(!arguments(VMConfig(shareFolder: false, sharedFolderPath: "/Users/me/Shared")).contains("--shared-dir"))
        let on = arguments(VMConfig(shareFolder: true, sharedFolderPath: "/Users/me/Avo Shared"))
        #expect(Array(on.suffix(2)) == ["--shared-dir", "/Users/me/Avo Shared"])
    }

    @Test func theSettingsNeedARestartAndSurviveOlderFiles() throws {
        let old = VMConfig()
        var new = old
        new.shareFolder = true
        new.sharedFolderPath = "/Users/me/Shared"
        #expect(new.effect(of: old) == .restartRequired)
        let decoded = try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(new))
        #expect(decoded.shareFolder && decoded.sharedFolderPath == "/Users/me/Shared")
        // A file from before the shared folder: off.
        let older = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"memoryMiB": 4096}"#.utf8))
        #expect(!older.shareFolder && older.sharedFolderPath == nil)
    }

    @Test func theDaemonSaysWhatIsWrongWithAFolder() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let paths = scratch.paths
        let good = try scratch.folder("Shared")
        var status = SharedFolderInspector.status(path: good.path, enabled: true, paths: paths, dataFolder: paths.vm)
        #expect(status.problem == nil)
        #expect(status.volume != nil)
        #expect(status.path == good.path)
        status = SharedFolderInspector.status(path: scratch.root.appending(path: "Gone").path, enabled: true, paths: paths, dataFolder: paths.vm)
        #expect(status.problem == .folderMissing(path: scratch.root.appending(path: "Gone").path))
        let file = scratch.root.appending(path: "file.txt")
        try Data("x".utf8).write(to: file)
        #expect(SharedFolderInspector.status(path: file.path, enabled: true, paths: paths, dataFolder: nil).problem == .notAFolder(path: file.path))
        // Avo's own folders, and a folder they are in, are not shared.
        let support = paths.applicationSupport
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        #expect(SharedFolderInspector.status(path: support.path, enabled: true, paths: paths, dataFolder: nil).problem == .avoData(path: support.path))
        let home = paths.home.standardizedFileURL.path
        #expect(SharedFolderInspector.status(path: home, enabled: true, paths: paths, dataFolder: nil).problem == .avoData(path: home))
        #expect(SharedFolderInspector.status(path: nil, enabled: false, paths: paths, dataFolder: nil) == SharedFolderStatus(path: nil, enabled: false))
    }

    @Test func androidHearsOfTheMacsChangesAFolderAtATime() {
        let root = "/Users/me/Avo Shared"
        let base = GuestSharedFolder.storagePath
        #expect(GuestSharedFolder.scanPaths(for: ["\(root)/Photos/", "\(root)/Photos/Trip", "\(root)/Music"], root: root)
            == ["\(base)/Music", "\(base)/Photos"])
        #expect(GuestSharedFolder.scanPaths(for: ["\(root)/"], root: root) == [base])
        #expect(GuestSharedFolder.scanPaths(for: ["/elsewhere"], root: root) == [base])
        let many = (0..<12).map { "\(root)/folder \($0)" }
        #expect(GuestSharedFolder.scanPaths(for: many, root: root) == [base])
        #expect(GuestSharedFolder.scanPaths(for: ["\(root)/a", "\(root)/ab"], root: root) == ["\(base)/a", "\(base)/ab"])
    }

    @Test func theGuestStepsSayWhatHappened() {
        #expect(GuestSharedFolder.mount(fromOutput: "mounted\n") == .mounted)
        #expect(GuestSharedFolder.mount(fromOutput: "unavailable") == .unavailable)
        #expect(GuestSharedFolder.mount(fromOutput: "mount: Invalid argument\nfailed\n") == .failed)
        #expect(GuestSharedFolder.mount(fromOutput: "") == .failed)
        // /proc/mounts writes the folder's space as \040.
        #expect(GuestSharedFolder.mountScript.contains(#"/data/media/0/Avo\\040Shared"#))
        #expect(GuestSharedFolder.mountScript.contains("mount -t virtiofs"))
        #expect(GuestSharedFolder.scanCommand("/storage/emulated/0/Avo Shared/it's")
            == #"content call --uri content://media/ --method scan_file --arg '/storage/emulated/0/Avo Shared/it'\''s'"#)
    }

    @Test func theBridgeMountsOnceAndroidIsUnlockedThenScans() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let folder = try scratch.folder("Shared")
        let commands = SharedFolderCommands()
        let unlocked = Flag()
        let bridge = SharedFolderBridge(folder: folder, run: { command in
            await commands.add(command)
            if command == GuestSharedFolder.unlockedCommand { return unlocked.value ? "true\n" : "false\n" }
            if command == GuestSharedFolder.mountScript { return "mounted\n" }
            return ""
        }, paused: { false })
        let start = Task { await bridge.start() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await bridge.mount == .waiting)
        unlocked.set()
        await start.value
        #expect(await bridge.mount == .mounted)
        // The whole folder is looked at once, for what the Mac changed while Android was off.
        try await Task.sleep(for: .milliseconds(1500))
        let scans = await commands.all.filter { $0.hasPrefix("content call") }
        #expect(scans == [GuestSharedFolder.scanCommand(GuestSharedFolder.storagePath)])
        // A new photo on the Mac: its folder is looked at again.
        try FileManager.default.createDirectory(at: folder.appending(path: "Photos"), withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: folder.appending(path: "Photos/new.jpg"))
        var later: [String] = []
        for _ in 0..<40 where later.count < 2 {
            try await Task.sleep(for: .milliseconds(250))
            later = await commands.all.filter { $0.hasPrefix("content call") }
        }
        #expect(later.count >= 2)
        await bridge.stop()
    }

    /// The real guest steps on the test VM (`AVO_SHARED_VM`: its directory
    /// with adb.sh; avo-vmm started with `--shared-dir AVO_SHARED_DIR`): the
    /// mount, then a photo made on the Mac reaching Android's media index.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AVO_SHARED_VM"] != nil))
    func mountsAndScansOnTheTestVM() async throws {
        let environment = ProcessInfo.processInfo.environment
        let vm = try #require(environment["AVO_SHARED_VM"])
        let folder = URL(filePath: try #require(environment["AVO_SHARED_DIR"]), directoryHint: .isDirectory)
        @Sendable func adb(_ command: String) -> String? {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/bash")
            process.arguments = ["\(vm)/adb.sh", "shell", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }
        let bridge = SharedFolderBridge(folder: folder, run: { adb("su 0 sh -c " + HostAgent.quote($0)) }, paused: { false })
        await bridge.start()
        #expect(await bridge.mount == .mounted)
        #expect(adb("su 0 sh -c " + HostAgent.quote(GuestSharedFolder.mountScript))?.contains("mounted") == true, "idempotent")
        let name = "vm-check-\(UUID().uuidString.prefix(6)).jpg"
        try FileManager.default.createDirectory(at: folder.appending(path: "Camera"), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: folder.appending(path: "Camera/\(name)"))
        let query = "content query --uri content://media/external/file --projection _data --where \"_data LIKE '%\(name)'\""
        var found = false
        for _ in 0..<40 where !found {
            try await Task.sleep(for: .milliseconds(500))
            found = adb(query)?.contains(name) == true
        }
        #expect(found, "the Mac's new photo is in Android's media index")
        #expect(adb("cat " + HostAgent.quote("\(SharedFolder.androidPath)/Camera/\(name)") + " | wc -c")?.trimmingCharacters(in: .whitespacesAndNewlines) == "4")
        await bridge.stop()
    }

    @Test func sharingOffCleansUpWhatAnEarlierStartLeft() async {
        let commands = SharedFolderCommands()
        let bridge = SharedFolderBridge(folder: nil, run: { await commands.add($0); return "" }, paused: { false })
        await bridge.start()
        #expect(await commands.all == [GuestSharedFolder.cleanUpScript])
        #expect(await bridge.mount == nil)
    }
}

actor SharedFolderCommands {
    private(set) var all: [String] = []
    func add(_ command: String) { all.append(command) }
}
