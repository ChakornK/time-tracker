// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TimeTracker",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "TimeTrackerCore", targets: ["TimeTrackerCore"]),
    ],
    targets: [
        // ActivityKit is unavailable on macOS, where the package tests run.
        .target(name: "TimeTrackerCore", exclude: ["TimerActivityAttributes.swift"]),
        .testTarget(name: "TimeTrackerCoreTests", dependencies: ["TimeTrackerCore"]),
    ]
)
