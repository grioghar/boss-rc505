import Foundation

// rc505 [--root <folder containing public/ and config.json>] [--port <n>]
// The root defaults to the current directory.

var rootPath = FileManager.default.currentDirectoryPath
var portOverride: Int?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--root" where !args.isEmpty: rootPath = args.removeFirst()
    case "--port" where !args.isEmpty: portOverride = Int(args.removeFirst())
    case "--help", "-h":
        log("usage: rc505 [--root <folder>] [--port <number>]")
        exit(0)
    default:
        log("Unknown option \(flag). Try --help.")
        exit(2)
    }
}

let root = URL(fileURLWithPath: rootPath)
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("public/overlay.html").path) else {
    log("No public/overlay.html under \(root.path). Run from the project folder or pass --root.")
    exit(1)
}

let bridge = Bridge(root: root, portOverride: portOverride)
guard bridge.start() else {
    log("Could not listen on the HTTP port. Is another copy already running?")
    exit(1)
}
while true { Thread.sleep(forTimeInterval: 3600) }
