import AvoKit
import Foundation

// avoctl: command-line control of the Avo Runtime Daemon, shipped inside
// Avo.app/Contents/MacOS so scripts and CI can drive Avo.
//
//   avoctl status
//   avoctl start | stop | restart | snapshot
//   avoctl apps
//   avoctl install <file.apk|.xapk|.apkm|.apks>
//   avoctl uninstall <package>
//   avoctl config [key=value ...]

let usage = """
usage: avoctl <command> [arguments]

commands:
  status                 Android state and version
  start | stop | restart Control the Android VM
  snapshot               Save a quick-boot snapshot
  apps                   List installed apps
  install <file>         Install an .apk, .xapk, .apkm or .apks
  uninstall <package>    Remove an app
  config [key=value ...] Show or change settings (memoryMiB, cpuCount, fpsLimit, renderer, rooted, …)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("avoctl: \(message)\n".utf8))
    exit(1)
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

/// Applies `key=value` to a configuration through its JSON form.
func apply(_ assignments: [String], to config: VMConfig) throws -> VMConfig {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
    for assignment in assignments {
        let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, object.keys.contains(parts[0]) else { fail("unknown setting \(assignment)") }
        let value = parts[1]
        if let int = Int(value) {
            object[parts[0]] = int
        } else if value == "true" || value == "false" {
            object[parts[0]] = value == "true"
        } else if value == "null" {
            object[parts[0]] = NSNull()
        } else {
            object[parts[0]] = value
        }
    }
    return try JSONDecoder().decode(VMConfig.self, from: JSONSerialization.data(withJSONObject: object))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}

let client = DaemonClient(role: .controlPanel, version: "avoctl")
do {
    _ = try await client.hello()
} catch {
    fail("cannot reach the Avo daemon: \(error.localizedDescription)")
}

do {
    switch command {
    case "status":
        printJSON(try await client.status())
    case "start":
        try await client.startVM()
        printJSON(try await client.status())
    case "stop":
        try await client.stopVM()
    case "restart":
        try await client.restartVM()
    case "snapshot":
        try await client.takeSnapshot()
    case "apps":
        for app in try await client.apps() {
            print("\(app.package)\t\(app.displayName)\t\(app.versionName)")
        }
    case "install":
        guard arguments.count == 2 else { fail("usage: avoctl install <file>") }
        let url = URL(filePath: arguments[1]).standardizedFileURL
        let request = InstallRequest(path: url.path)
        let progress = Task {
            for await event in client.events {
                if case .installProgress(let p) = event, p.id == request.id {
                    let percent = p.fraction.map { " \(Int($0 * 100))%" } ?? ""
                    print("\(p.phase.rawValue)\(percent)\(p.message.map { ": \($0)" } ?? "")")
                }
            }
        }
        try await client.install(request)
        progress.cancel()
    case "uninstall":
        guard arguments.count == 2 else { fail("usage: avoctl uninstall <package>") }
        try await client.uninstall(arguments[1])
    case "config":
        let snapshot = try await client.configuration()
        if arguments.count == 1 {
            printJSON(snapshot.config)
        } else {
            let result = try await client.updateConfiguration(try apply(Array(arguments.dropFirst()), to: snapshot.config))
            for issue in result.issues { print("\(issue.severity.rawValue): \(issue)") }
            print("effect: \(result.effect.rawValue)")
        }
    default:
        print(usage)
        exit(2)
    }
} catch {
    fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
}
