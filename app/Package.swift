// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "LOQControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LOQControl", targets: ["LOQControl"]),
        .executable(name: "LOQCoreChecks", targets: ["LOQCoreChecks"]),
        .library(name: "LOQCore", targets: ["LOQCore"])
    ],
    targets: [
        .target(name: "CSensors", path: "Sources/CSensors", publicHeadersPath: "include"),
        .target(name: "LOQCore", path: "Sources/LOQCore"),
        .executableTarget(name: "LOQControl",
                          dependencies: ["CSensors", "LOQCore"],
                          path: "Sources/LOQControl"),
        .executableTarget(name: "LOQCoreChecks", dependencies: ["LOQCore"], path: "Sources/LOQCoreChecks")
    ]
)
