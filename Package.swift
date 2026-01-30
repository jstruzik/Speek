// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Speek",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Speek",
            dependencies: [
                "WhisperKit",
            ],
            path: "Sources",
            exclude: ["Info.plist"]
        ),
    ]
)
