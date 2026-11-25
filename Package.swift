// swift-tools-version: 6.2
import Foundation
import PackageDescription

let cltFrameworksPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltDevUsrLibPath = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let activeDevDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? ""
let symlinkDevDir = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
let effectiveDevDir = activeDevDir.isEmpty ? symlinkDevDir : activeDevDir
let isUsingCLT = effectiveDevDir.hasPrefix("/Library/Developer/CommandLineTools")
    || (effectiveDevDir.isEmpty && !FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer"))
let hasCLTTestingFramework = isUsingCLT && FileManager.default.fileExists(atPath: "\(cltFrameworksPath)/Testing.framework")

var testSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
var testLinkerSettings: [LinkerSetting] = []
if hasCLTTestingFramework {
    testSwiftSettings.append(.unsafeFlags(["-F", cltFrameworksPath]))
    testLinkerSettings.append(.unsafeFlags([
        "-F", cltFrameworksPath,
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworksPath,
        "-Xlinker", "-rpath", "-Xlinker", cltDevUsrLibPath
    ]))
}

let package = Package(
    name: "Bianzhong",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "BianzhongCore", targets: ["BianzhongCore"]),
        .executable(name: "BianzhongApp", targets: ["BianzhongApp"]),
        .executable(name: "bz", targets: ["bz"])
    ],
    targets: [
        .target(
            name: "BianzhongCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "BianzhongApp",
            dependencies: ["BianzhongCore"],
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "bz",
            dependencies: ["BianzhongCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "BianzhongCoreTests",
            dependencies: ["BianzhongCore"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ]
)
