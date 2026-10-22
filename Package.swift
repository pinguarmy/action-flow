// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ActionFlow",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ActionFlowCore", targets: ["ActionFlowCore"]), .executable(name: "ActionFlow", targets: ["ActionFlowApp"]), .executable(name: "actionflow-cli", targets: ["ActionFlowCLI"])],
    targets: [
        .target(name: "ActionFlowCore"),
        .executableTarget(name: "ActionFlowCLI", dependencies: ["ActionFlowCore"]),
        .executableTarget(name: "ActionFlowApp", dependencies: ["ActionFlowCore"], resources: [.copy("Resources/PrivacyInfo.xcprivacy"), .process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj")]),
        .executableTarget(name: "ActionFlowChecks", dependencies: ["ActionFlowCore"], path: "Tests/BehaviorHarness"),
        .testTarget(name: "ActionFlowCoreTests", dependencies: ["ActionFlowCore"])
    ],
    swiftLanguageModes: [.v5]
)
