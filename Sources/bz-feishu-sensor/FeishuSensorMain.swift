import BianzhongCore
import CoreServices
import Foundation

private func parseArg(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

let paths = BianzhongPaths()
let defaultDB = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
let dbURL = parseArg("--db-path").map { URL(fileURLWithPath: $0) } ?? defaultDB
let onceMode = CommandLine.arguments.contains("--once")
let dryRun = CommandLine.arguments.contains("--dry-run")
let fromStart = CommandLine.arguments.contains("--from-start")

let sensor = FeishuSensorRunner(
    dbURL: dbURL,
    cursorURL: paths.feishuCursorURL,
    socketURL: paths.socketURL,
    skipExistingOnFirstRun: !fromStart
)

if onceMode {
    do {
        _ = try sensor.pollOnce(dryRun: dryRun)
        exit(0)
    } catch {
        fputs("bz-feishu-sensor error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// Initial check before starting FSEvents watch
_ = try? sensor.pollOnce(dryRun: dryRun)

// Periodic retry timer ensures records queued while Bianzhong.app was restarting get delivered promptly.
let retryTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
retryTimer.schedule(deadline: .now() + 15.0, repeating: 15.0)
retryTimer.setEventHandler {
    _ = try? sensor.pollOnce(dryRun: false)
}
retryTimer.resume()

let watchDir = dbURL.deletingLastPathComponent().path as CFString
let pathsToWatch = [watchDir] as CFArray
var context = FSEventStreamContext(
    version: 0,
    info: Unmanaged.passUnretained(sensor).toOpaque(),
    retain: nil,
    release: nil,
    copyDescription: nil
)

let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
    guard let info else { return }
    let runner = Unmanaged<FeishuSensorRunner>.fromOpaque(info).takeUnretainedValue()
    _ = try? runner.pollOnce(dryRun: false)
}

guard let stream = FSEventStreamCreate(
    kCFAllocatorDefault,
    callback,
    &context,
    pathsToWatch,
    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
    0.4,
    FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
) else {
    fputs("Failed to create FSEventStream on \(watchDir)\n", stderr)
    exit(1)
}

FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
FSEventStreamStart(stream)
fputs("bz-feishu-sensor watching \(dbURL.path) -> \(paths.socketURL.path)\n", stderr)
dispatchMain()
