// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ddc-mirror",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "ddc-mirror", targets: ["ddc-mirror"]),
        .library(name: "DDCMirrorCore", targets: ["DDCMirrorCore"]),
    ],
    targets: [
        .target(
            name: "DDCMirrorCore"
        ),
        .executableTarget(
            name: "ddc-mirror",
            dependencies: ["DDCMirrorCore"]
        ),
        .testTarget(
            name: "DDCMirrorCoreTests",
            dependencies: ["DDCMirrorCore"]
        ),
    ]
)
