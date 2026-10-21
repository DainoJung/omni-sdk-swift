// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Omni",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
    ],
    products: [
        .library(name: "Omni", targets: ["Omni"]),
    ],
    targets: [
        .target(
            name: "Omni",
            path: "Sources/Omni",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "OmniTests",
            dependencies: ["Omni"],
            path: "Tests/OmniTests"
        ),
    ]
)
