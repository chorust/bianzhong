import Darwin
import Foundation

public struct CLIIntegrationStatus: Sendable, Equatable {
    public let bundledBZPath: String?
    public let linkedPaths: [String]
    public let isCLIInstalled: Bool
    public let isZshHookInstalled: Bool

    public init(
        bundledBZPath: String?,
        linkedPaths: [String],
        isCLIInstalled: Bool,
        isZshHookInstalled: Bool
    ) {
        self.bundledBZPath = bundledBZPath
        self.linkedPaths = linkedPaths
        self.isCLIInstalled = isCLIInstalled
        self.isZshHookInstalled = isZshHookInstalled
    }
}

/// Manages zero-friction CLI symlink installation (`~/.local/bin/bz`, `/opt/homebrew/bin/bz`)
/// and idempotent `~/.zshrc` shell-hook integration from inside `Bianzhong.app` or `bz install-cli`.
public enum CLIIntegration {
    public static let blockStartMarker = "# >>> bianzhong >>>"
    public static let blockEndMarker = "# <<< bianzhong <<<"

    /// Returns true only when `bundleURL` is an installed `.app` bundle (not mounted `.dmg`, AppTranslocation, or `.build/`).
    public static func shouldAutoInstallOnLaunch(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        let path = bundleURL.standardizedFileURL.path
        if path.hasPrefix("/Volumes/") { return false }
        if path.contains("/AppTranslocation/") { return false }
        if path.contains("/.build/") { return false }
        return true
    }

    /// Auto-symlinks the embedded `bz` binary when running from an installed `Bianzhong.app`.
    @discardableResult
    public static func autoInstallOnLaunchIfEligible(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        candidateDirs: [URL]? = nil
    ) -> [String] {
        guard shouldAutoInstallOnLaunch(bundleURL: bundleURL) else { return [] }
        let bundledBZ = bundleURL.appendingPathComponent("Contents/MacOS/bz").path
        guard FileManager.default.isExecutableFile(atPath: bundledBZ) else { return [] }
        return ensureCLISymlinks(
            sourceBZPath: bundledBZ,
            homeDir: homeDir,
            candidateDirs: candidateDirs,
            force: false
        )
    }

    public static func isManagedSymlinkTarget(_ rawTarget: String, resolvedTarget: String) -> Bool {
        let markers = ["Bianzhong.app/Contents/MacOS/bz", "/bianzhong/.build/"]
        return markers.contains { marker in
            rawTarget.contains(marker) || resolvedTarget.contains(marker)
        }
    }

    /// Resolves the `bz` executable embedded inside `Bianzhong.app` (or adjacent in `.build/`).
    public static func resolveBundledBZPath(
        bundleURL: URL = Bundle.main.bundleURL,
        executablePath: String? = CommandLine.arguments.first
    ) -> String? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if shouldAutoInstallOnLaunch(bundleURL: bundleURL) {
            candidates.append(bundleURL.appendingPathComponent("Contents/MacOS/bz"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/Bianzhong.app/Contents/MacOS/bz"))
        if bundleURL.pathExtension == "app" {
            candidates.append(bundleURL.appendingPathComponent("Contents/MacOS/bz"))
        }
        if let executablePath, !executablePath.isEmpty {
            let exeURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            if exeURL.lastPathComponent == "bz" {
                candidates.append(exeURL)
            } else {
                candidates.append(exeURL.deletingLastPathComponent().appendingPathComponent("bz"))
            }
        }
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url.resolvingSymlinksInPath().path
        }
        return nil
    }

    public static func defaultCandidateDirs(
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDir.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        ]
    }

    /// Creates or repairs `bz` symlinks pointing at `sourceBZPath`.
    @discardableResult
    public static func ensureCLISymlinks(
        sourceBZPath: String,
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        candidateDirs: [URL]? = nil,
        force: Bool = false
    ) -> [String] {
        let fm = FileManager.default
        let resolvedSource = URL(fileURLWithPath: sourceBZPath).resolvingSymlinksInPath().path
        guard fm.isExecutableFile(atPath: resolvedSource) else { return [] }

        let dirs = candidateDirs ?? defaultCandidateDirs(homeDir: homeDir)
        let localBinPath = homeDir.appendingPathComponent(".local/bin", isDirectory: true).standardizedFileURL.path
        var activeLinks: [String] = []

        for dir in dirs {
            let dirStd = dir.standardizedFileURL.path
            if dirStd == localBinPath || candidateDirs != nil {
                if !fm.fileExists(atPath: dir.path) {
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
            }
            guard fm.fileExists(atPath: dir.path), fm.isWritableFile(atPath: dir.path) else {
                continue
            }

            let linkPath = dir.appendingPathComponent("bz").path
            var st = stat()
            if Darwin.lstat(linkPath, &st) == 0 {
                let isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
                if isSymlink {
                    let currentTarget = (try? fm.destinationOfSymbolicLink(atPath: linkPath)) ?? ""
                    let resolvedCurrent = URL(fileURLWithPath: currentTarget, relativeTo: dir).resolvingSymlinksInPath().path
                    if resolvedCurrent == resolvedSource {
                        activeLinks.append(linkPath)
                        continue
                    }
                    if !force,
                       resolvedCurrent.contains("Bianzhong.app/Contents/MacOS/bz"),
                       resolvedSource.contains("/.build/") {
                        continue
                    }
                    let managed = isManagedSymlinkTarget(currentTarget, resolvedTarget: resolvedCurrent)
                    guard force || managed else { continue }
                    guard Darwin.unlink(linkPath) == 0 else { continue }
                } else {
                    guard force else { continue }
                    guard Darwin.unlink(linkPath) == 0 else { continue }
                }
            }

            if Darwin.symlink(resolvedSource, linkPath) == 0 {
                activeLinks.append(linkPath)
            }
        }
        return activeLinks
    }

    /// Removes `bz` symlinks created by Bianzhong (leaving custom non-symlink binaries unless `force: true`).
    @discardableResult
    public static func removeCLISymlinks(
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        candidateDirs: [URL]? = nil,
        force: Bool = false
    ) -> [String] {
        let fm = FileManager.default
        let dirs = candidateDirs ?? defaultCandidateDirs(homeDir: homeDir)
        var removed: [String] = []
        for dir in dirs {
            let linkPath = dir.appendingPathComponent("bz").path
            var st = stat()
            guard Darwin.lstat(linkPath, &st) == 0 else { continue }
            let isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
            if isSymlink {
                let target = (try? fm.destinationOfSymbolicLink(atPath: linkPath)) ?? ""
                let resolvedTarget = URL(fileURLWithPath: target, relativeTo: dir).resolvingSymlinksInPath().path
                if force || isManagedSymlinkTarget(target, resolvedTarget: resolvedTarget) {
                    if Darwin.unlink(linkPath) == 0 {
                        removed.append(linkPath)
                    }
                }
            } else if force {
                if Darwin.unlink(linkPath) == 0 {
                    removed.append(linkPath)
                }
            }
        }
        return removed
    }

    public static func defaultZshrcURL(
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDir.appendingPathComponent(".zshrc")
    }

    public static func isZshHookInstalled(zshrcURL: URL? = nil) -> Bool {
        let url = zshrcURL ?? defaultZshrcURL()
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return content.contains(blockStartMarker) && content.contains(blockEndMarker)
    }

    /// Idempotently adds or removes the `# >>> bianzhong >>>` block in `~/.zshrc`.
    @discardableResult
    public static func setZshHook(enabled: Bool, zshrcURL: URL? = nil) throws -> Bool {
        let url = zshrcURL ?? defaultZshrcURL()
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        var keptLines: [String] = []
        var skipping = false
        for line in existing.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == blockStartMarker {
                skipping = true
                continue
            }
            if trimmed == blockEndMarker {
                skipping = false
                continue
            }
            if !skipping {
                keptLines.append(line)
            }
        }

        while keptLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            keptLines.removeLast()
        }

        var output = keptLines.joined(separator: "\n")
        if enabled {
            if !output.isEmpty {
                output += "\n\n"
            }
            output += """
            \(blockStartMarker)
            export PATH="$HOME/.local/bin:$PATH"
            command -v bz >/dev/null 2>&1 && eval "$(bz shell-hook zsh)"
            \(blockEndMarker)
            """
        }
        if !output.isEmpty && !output.hasSuffix("\n") {
            output += "\n"
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: url, atomically: true, encoding: .utf8)
        return enabled
    }

    public static func currentStatus(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        candidateDirs: [URL]? = nil,
        zshrcURL: URL? = nil
    ) -> CLIIntegrationStatus {
        let fm = FileManager.default
        let bundled = resolveBundledBZPath(bundleURL: bundleURL)
        var inspectDirs = candidateDirs ?? defaultCandidateDirs(homeDir: homeDir)
        if candidateDirs == nil {
            inspectDirs.append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))
        }

        var found: [String] = []
        for dir in inspectDirs {
            let candidate = dir.appendingPathComponent("bz").path
            if fm.isExecutableFile(atPath: candidate) {
                found.append(candidate)
            }
        }
        return CLIIntegrationStatus(
            bundledBZPath: bundled,
            linkedPaths: found,
            isCLIInstalled: !found.isEmpty,
            isZshHookInstalled: isZshHookInstalled(zshrcURL: zshrcURL)
        )
    }
}
