// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MusicPlayer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MusicPlayer",
            targets: ["MusicPlayer"]
        ),
        .executable(
            name: "musicplayerctl",
            targets: ["MusicPlayerCLI"]
        )
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "MusicPlayerIPC",
            dependencies: []
        ),
        .executableTarget(
            name: "MusicPlayer",
            dependencies: ["MusicPlayerIPC"],
            linkerSettings: [
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "MusicPlayerCLI",
            dependencies: ["MusicPlayerIPC"]
        )
    ]
)
