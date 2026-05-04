// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "recorder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "recorder",
            path: "Sources/recorder",
            linkerSettings: [
                // Strip the LC_UUID load command so rebuilds produce a stable
                // cdhash. Otherwise every `swift build` changes the binary's
                // UUID, which changes the cdhash, which invalidates TCC's
                // recorded Screen Recording grant under ad-hoc signing.
                .unsafeFlags(["-Xlinker", "-no_uuid"])
            ]
        )
    ]
)
