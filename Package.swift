// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AtomVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AtomVoice",
            dependencies: ["SherpaOnnxShim", "AudioTapShim"],
            path: "Sources/AtomVoice",
            exclude: [
                "Info.plist",
                "AppIcon.icns",
                "AppIcon.png",
                "AppIcon-1024.png",
                "AppIcon-source-chromakey.png",
                "AppIcon.iconset",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AtomVoice/Info.plist",
                ]),
            ]
        ),
        .target(
            name: "SherpaOnnxShim",
            path: "Sources/SherpaOnnxShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AudioTapShim",
            path: "Sources/AudioTapShim",
            publicHeadersPath: "include"
        ),
    ]
)
