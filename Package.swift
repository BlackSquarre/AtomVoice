// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AtomVoice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AtomVoice", targets: ["AtomVoice"]),
        .executable(name: "AtomVoiceArchitectureTests", targets: ["AtomVoiceArchitectureTests"]),
        .executable(name: "AtomVoiceDoctor", targets: ["AtomVoiceDoctor"]),
        .executable(name: "SherpaMemoryProbe", targets: ["SherpaMemoryProbe"]),
        .executable(name: "SherpaMemoryBenchmark", targets: ["SherpaMemoryBenchmark"]),
    ],
    targets: [
        .executableTarget(
            name: "AtomVoice",
            dependencies: ["AtomVoiceCore"],
            path: "Sources/AtomVoiceApp",
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
            name: "AtomVoiceCore",
            dependencies: ["SherpaOnnxShim", "AudioTapShim"],
            path: "Sources/AtomVoice",
            exclude: [
                "Info.plist",
                "AppIcon.icns",
                "AppIcon.svg",
                "AppIcon.png",
                "AppIcon-1024.png",
                "AppIcon-source-chromakey.png",
                "AppIcon.iconset",
                "Debug/SherpaMemoryProbe",
                "Debug/SherpaMemoryBenchmark",
                "Debug/AtomVoiceArchitectureTests",
                "Debug/AtomVoiceDoctor",
                "Debug/Tools",
                "Debug/Scripts",
            ]
        ),
        .executableTarget(
            name: "AtomVoiceArchitectureTests",
            dependencies: ["AtomVoiceCore"],
            path: "Sources/AtomVoice/Debug/AtomVoiceArchitectureTests"
        ),
        .executableTarget(
            name: "AtomVoiceDoctor",
            dependencies: ["AtomVoiceCore"],
            path: "Sources/AtomVoice/Debug/AtomVoiceDoctor"
        ),
        .executableTarget(
            name: "SherpaMemoryProbe",
            dependencies: ["SherpaOnnxShim"],
            path: "Sources/AtomVoice/Debug/SherpaMemoryProbe"
        ),
        .executableTarget(
            name: "SherpaMemoryBenchmark",
            dependencies: [],
            path: "Sources/AtomVoice/Debug/SherpaMemoryBenchmark"
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
