import Foundation

/// Packages user-rejected notification/approval samples so an external `omp` or `codex`
/// session can tighten `chimes/*.md` exclude keywords and match rules without manual guesswork.
public enum RuleTuner {
    public static func prepareTuneSession(
        paths: BianzhongPaths,
        store: SQLiteStore,
        chimeID: String?
    ) throws -> (contextFile: URL, prompt: String, sampleCount: Int) {
        try paths.ensureDirectories()
        let samples = try store.listRejectedSamples(chimeID: chimeID, limit: 15)
        let contextURL = paths.stateDir.appendingPathComponent("tune-samples.md")

        var lines: [String] = [
            "# Bianzhong Rejected / False-Positive Samples",
            "",
            "Generated: \(ISO8601DateFormatter.bianzhong.string(from: Date()))",
            "Target chime filter: \(chimeID ?? "ALL")",
            ""
        ]

        if samples.isEmpty {
            lines.append("No rejected approval samples found yet.")
        } else {
            for (idx, s) in samples.enumerated() {
                lines.append("## Sample \(idx + 1): [\(s.chimeID)] \(s.title)")
                lines.append("- Provenance: \(s.provenance)")
                lines.append("- User comment: \(s.userComment ?? "(none)")")
                lines.append("- Payload summary: `\(s.payloadSummary)`")
                lines.append("")
            }
        }

        try lines.joined(separator: "\n").write(to: contextURL, atomically: true, encoding: .utf8)

        let prompt = """
        请阅读当前目录下的 AGENTS.md、chimes/*.md 规则，以及误报样本文件：\(contextURL.path)。
        基于这些被用户点「忽略/拒绝」的样本，建议并最小化修改对应的 chime 规则（例如补充 `exclude_keywords`、收紧 `keywords_any` 或调整 `triage` 提示），并在修改前先向我确认改动。
        """

        return (contextURL, prompt, samples.count)
    }
}
