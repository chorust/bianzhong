import BianzhongCore
import Foundation

if CommandLine.arguments.contains("--daemon") || CommandLine.arguments.contains("--headless") {
    let paths = BianzhongPaths()
    _ = try? DefaultTemplates.installDefaultsIfMissing(paths: paths)
    CLIIntegration.autoInstallOnLaunchIfEligible()
    let orch = try Orchestrator(paths: paths)
    try orch.start(enableBuiltInSensors: true)
    fputs("Bianzhong daemon listening on \(paths.socketURL.path)\n", stderr)
    RunLoop.main.run()
} else {
    BianzhongMenuBarApp.main()
}
