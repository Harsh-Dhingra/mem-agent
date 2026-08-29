// swift-tools-version:6.0
import PackageDescription

let swift5 = [SwiftSetting.swiftLanguageMode(.v5)]

let package = Package(
    name: "memagent",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CLibProc"),
        .target(name: "MemAgentCore", dependencies: ["CLibProc"], swiftSettings: swift5),
        .executableTarget(name: "memagent", dependencies: ["MemAgentCore"], swiftSettings: swift5),
        .executableTarget(name: "memagent-menubar", dependencies: ["MemAgentCore"], swiftSettings: swift5),
        // The Command Line Tools toolchain ships neither XCTest nor swift-testing,
        // so unit tests are a plain executable: `swift run selftest`.
        .executableTarget(name: "selftest", dependencies: ["MemAgentCore"], swiftSettings: swift5),
    ]
)
