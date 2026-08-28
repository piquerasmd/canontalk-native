// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CanonTalkNative",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CanonTalkNative", targets: ["CanonTalkNative"])
    ],
    targets: [
        .executableTarget(
            name: "CanonTalkNative",
            path: "Sources/CanonTalkNative"
        ),
        .testTarget(
            name: "CanonTalkNativeTests",
            dependencies: ["CanonTalkNative"],
            path: "Tests/CanonTalkNativeTests"
        )
    ]
)
