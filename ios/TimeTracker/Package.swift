// swift-tools-version: 6.2
import PackageDescription

var packageDependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/ChakornK/OpenSwiftData.git",
        revision: "078eba9c473900af3a3fe6c562a7048f6766f585"),
]
var swiftDataDependencies: [Target.Dependency] = [
    .product(name: "SwiftData", package: "OpenSwiftData"),
]
var predicateCompatibilitySettings: [SwiftSetting] = []
#if os(Linux)
packageDependencies.append(
    .package(
        url: "https://github.com/ChakornK/FoundationEssentialsShim.git",
        revision: "fb21c72878713a04602f584ada694ce19e37b929"))
swiftDataDependencies.append(
    .product(
        name: "FoundationEssentials",
        package: "FoundationEssentialsShim",
        condition: .when(platforms: [.iOS])))
predicateCompatibilitySettings.append(
    .unsafeFlags(
        ["-Xfrontend", "-import-module", "-Xfrontend", "FoundationEssentials"],
        .when(platforms: [.iOS])))
#endif
let package = Package(
    name: "TimeTracker",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "TimeTrackerCore", targets: ["TimeTrackerCore"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // ActivityKit is unavailable on macOS, where the package tests run.
        .target(
        name: "TimeTrackerCore",
        dependencies: swiftDataDependencies,
        path: ".",
        sources: ["Sources/TimeTrackerApp", "Sources/TimeTrackerCore"],
        swiftSettings: predicateCompatibilitySettings),
        .testTarget(
            name: "TimeTrackerCoreTests",
            dependencies: ["TimeTrackerCore", .product(name: "SwiftData", package: "OpenSwiftData")]),
    ]
)
