// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AtomVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AtomVoice",
            path: "Sources/AtomVoice",
            exclude: ["Info.plist", "AppIcon.icns"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AtomVoice/Info.plist",
                ]),
            ]
        ),
    ]
)
