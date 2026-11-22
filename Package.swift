// swift-tools-version:5.9
import PackageDescription

// No third-party packages. MIDI goes through the platform's own API:
// CoreMIDI on macOS, ALSA rawmidi on Linux, WinMM on Windows.
//   RC505Core  the bridge (MIDI, looper model, HTTP + WebSocket server)
//   rc505      command-line bridge for all three platforms
//   RC505App   macOS app: the same bridge with the control page in a window
let package = Package(
    name: "rc505",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "RC505Core",
            dependencies: [.target(name: "CALSA", condition: .when(platforms: [.linux]))],
            linkerSettings: [
                .linkedLibrary("winmm", .when(platforms: [.windows])),
                .linkedLibrary("ws2_32", .when(platforms: [.windows])),
            ]
        ),
        .executableTarget(name: "rc505", dependencies: ["RC505Core"]),
        .executableTarget(name: "RC505App", dependencies: ["RC505Core"]),
        .systemLibrary(name: "CALSA", path: "Sources/CALSA", providers: [.apt(["libasound2-dev"])]),
    ]
)
