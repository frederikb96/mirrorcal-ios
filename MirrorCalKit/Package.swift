// swift-tools-version: 6.2
import PackageDescription

// Nearly all of the app lives here rather than in the Xcode project.
//
// A Package.swift is plainly reviewable where a project file is not, it builds and tests on any
// macOS runner without an Apple credential, and it keeps the app target thin — the app holds
// views and wiring, and everything worth testing without an app host lives here.
//
// `platforms` names macOS as well as iOS deliberately: a Package manifest runs on the build
// host, so declaring macOS is what lets this package build and test on Linux CI and on a plain
// Linux machine at all. Dropping it would make the package iOS-only and un-testable off a Mac.

let package = Package(
    name: "MirrorCalKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MirrorCalKit", targets: ["MirrorCalKit"])
    ],
    targets: [
        .target(name: "MirrorCalKit"),
        .testTarget(name: "MirrorCalKitTests", dependencies: ["MirrorCalKit"]),
    ]
)
