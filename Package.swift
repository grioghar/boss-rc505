// swift-tools-version:5.9
import PackageDescription

// One dependency-free executable. MIDI goes through the platform's own API:
// CoreMIDI on macOS, ALSA rawmidi on Linux, WinMM on Windows.
let package = Package(
    name: "rc505",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "rc505",
            dependencies: [.target(name: "CALSA", condition: .when(platforms: [.linux]))],
            path: "Sources/rc505",
            linkerSettings: [
                .linkedLibrary("winmm", .when(platforms: [.windows])),
                .linkedLibrary("ws2_32", .when(platforms: [.windows])),
            ]
        ),
        .systemLibrary(name: "CALSA", path: "Sources/CALSA", providers: [.apt(["libasound2-dev"])]),
    ]
)
