import AppKit
import Foundation

/// Launches user-facing terminal takeover sessions (`omp -r` / `codex resume` / `bz config`)
/// and handles safe clipboard copy + Feishu activation without self-triggering sensors.
public enum TerminalLauncher {
    public enum TerminalApp: String, CaseIterable, Codable, Sendable, Identifiable {
        case ghostty
        case iterm
        case warp
        case kitty
        case wezterm
        case alacritty
        case cmux
        case terminal

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .ghostty: return "Ghostty"
            case .iterm: return "iTerm2"
            case .warp: return "Warp"
            case .kitty: return "Kitty"
            case .wezterm: return "WezTerm"
            case .alacritty: return "Alacritty"
            case .cmux: return "cmux"
            case .terminal: return "系统终端 (Terminal)"
            }
        }

        public var bundleIdentifier: String {
            switch self {
            case .ghostty: return "com.mitchellh.ghostty"
            case .iterm: return "com.googlecode.iterm2"
            case .warp: return "dev.warp.Warp-Stable"
            case .kitty: return "net.kovidgoyal.kitty"
            case .wezterm: return "com.github.wez.wezterm"
            case .alacritty: return "org.alacritty"
            case .cmux: return "com.cmuxterm.app"
            case .terminal: return "com.apple.Terminal"
            }
        }

        public var isInstalled: Bool {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        }
    }

    public static func detectTerminal(preference: String = "auto") -> TerminalApp {
        switch preference.lowercased() {
        case "ghostty": return .ghostty
        case "iterm", "iterm2": return .iterm
        case "warp": return .warp
        case "kitty": return .kitty
        case "wezterm": return .wezterm
        case "alacritty": return .alacritty
        case "cmux": return .cmux
        case "terminal": return .terminal
        default:
            for candidate in TerminalApp.allCases {
                if candidate.isInstalled {
                    return candidate
                }
            }
            return .terminal
        }
    }

    /// Executes `command` inside the user's preferred terminal application by writing a self-cleaning launcher script.
    @discardableResult
    public static func launchCommand(_ command: String, preferredTerminal: String = "auto") -> Bool {
        let terminal = detectTerminal(preference: preferredTerminal)
        let tmpDir = FileManager.default.temporaryDirectory
        let scriptURL = tmpDir.appendingPathComponent("bianzhong-launch-\(UUID().uuidString.prefix(8)).command")

        let script = """
        #!/bin/zsh
        rm -f \(shellQuote(scriptURL.path))
        \(command)
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            return false
        }

        var launched = false
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) {
            launched = runOpenProcess(arguments: ["-a", appURL.path, scriptURL.path])
        }
        if !launched {
            launched = runOpenProcess(arguments: [scriptURL.path])
        }
        if !launched {
            try? FileManager.default.removeItem(at: scriptURL)
        }
        return launched
    }

    /// Opens an interactive shell rooted at `directory` in the user's preferred terminal.
    @discardableResult
    public static func openInteractiveShell(at directory: String, preferredTerminal: String = "auto") -> Bool {
        let expanded = NSString(string: directory).expandingTildeInPath
        let cmd = "cd \(shellQuote(expanded)) && clear && pwd && exec /bin/zsh -l"
        return launchCommand(cmd, preferredTerminal: preferredTerminal)
    }

    public enum IDEApp: String, CaseIterable, Codable, Sendable, Identifiable {
        case t3code
        case cursor
        case zed
        case vscode

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .t3code: return "T3 Code"
            case .cursor: return "Cursor"
            case .zed: return "Zed"
            case .vscode: return "VS Code"
            }
        }

        public var appURL: URL? {
            let fm = FileManager.default
            switch self {
            case .t3code:
                for p in ["/Applications/T3 Code (Beta).app", "/Applications/T3 Code.app"] where fm.fileExists(atPath: p) {
                    return URL(fileURLWithPath: p)
                }
                return nil
            case .cursor:
                if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") { return u }
                return fm.fileExists(atPath: "/Applications/Cursor.app") ? URL(fileURLWithPath: "/Applications/Cursor.app") : nil
            case .zed:
                if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.zed.Zed") { return u }
                return fm.fileExists(atPath: "/Applications/Zed.app") ? URL(fileURLWithPath: "/Applications/Zed.app") : nil
            case .vscode:
                return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
            }
        }

        public var isInstalled: Bool { appURL != nil }
    }

    public static var installedIDEs: [IDEApp] {
        IDEApp.allCases.filter(\.isInstalled)
    }

    @discardableResult
    public static func openInIDE(_ ide: IDEApp, directory: String) -> Bool {
        guard let appURL = ide.appURL else { return false }
        let expanded = NSString(string: directory).expandingTildeInPath
        return runOpenProcess(arguments: ["-a", appURL.path, expanded])
    }

    private static func runOpenProcess(arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = arguments
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Writes `text` to the macOS pasteboard tagged with `org.nspasteboard.TransientType`
    /// so compliant clipboard watchers ignore the writeback, then activates Feishu (`com.electron.lark`).
    public static func copyAndOpenFeishu(text: String, registerEchoHash: ((String) -> Void)? = nil) {
        let hash = "sha256:" + EventEnvelope.sha256Hex(text)
        registerEchoHash?(hash)

        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])

        if let larkURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.lark") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: larkURL, configuration: config)
        }
    }

    /// Creates an isolated Git worktree for Phase 2 execution when the target path is inside a Git repository.
    public static func prepareWorktreeIfGitRepo(repoPath: String, runID: String, worktreesDir: URL) -> String {
        let gitCheck = Process()
        gitCheck.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitCheck.arguments = ["-C", repoPath, "rev-parse", "--is-inside-work-tree"]
        let outPipe = Pipe()
        gitCheck.standardOutput = outPipe
        gitCheck.standardError = Pipe()
        guard (try? gitCheck.run()) != nil else { return repoPath }
        gitCheck.waitUntilExit()
        guard gitCheck.terminationStatus == 0 else { return repoPath }

        let targetURL = worktreesDir.appendingPathComponent(runID, isDirectory: true)
        let branch = "bianzhong/\(runID.prefix(12))"
        let addProc = Process()
        addProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        addProc.arguments = ["-C", repoPath, "worktree", "add", "-b", branch, targetURL.path]
        addProc.standardOutput = Pipe()
        addProc.standardError = Pipe()
        guard (try? addProc.run()) != nil else { return repoPath }
        addProc.waitUntilExit()
        return addProc.terminationStatus == 0 ? targetURL.path : repoPath
    }
}
