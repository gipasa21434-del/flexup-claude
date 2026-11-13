// swift-tools-version:5.9
// FlexCore — platform-independent business logic of FLEX UP.
// Builds and tests on macOS, iOS and Linux (no UIKit/SwiftUI/AVFoundation here).
import PackageDescription

let package = Package(
    name: "FlexCore",
    defaultLocalization: "ru",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "FlexCore", targets: ["FlexCore"])
    ],
    targets: [
        .target(name: "FlexCore", path: "Sources/FlexCore"),
        .testTarget(name: "FlexCoreTests", dependencies: ["FlexCore"], path: "Tests/FlexCoreTests")
    ]
)
