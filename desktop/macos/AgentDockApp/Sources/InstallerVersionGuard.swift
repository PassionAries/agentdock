import Foundation

enum InstallerVersionGuard {
    static func validate(bundleVersion: String, installedVersionOutput: String) throws {
        guard let bundled = semanticVersion(bundleVersion) else {
            throw ValidationError("无法识别控制面板内嵌版本：\(bundleVersion)")
        }
        guard let installed = versionFromAgentDockOutput(installedVersionOutput) else {
            throw ValidationError("无法确认当前 AgentDock 核心版本，已取消配置变更。")
        }
        guard installed <= bundled else {
            let firstLine = installedVersionOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let installedDisplay = firstLine.hasPrefix("AgentDock ")
                ? String(firstLine.dropFirst("AgentDock ".count))
                : AppVersion.display(firstLine)
            throw ValidationError(
                "当前控制面板 \(AppVersion.display(bundleVersion)) 低于核心 \(installedDisplay)，不能使用旧离线载荷覆盖。请先更新 AgentDock 应用。"
            )
        }
    }

    private static func versionFromAgentDockOutput(_ output: String) -> SemanticVersion? {
        guard let firstLine = output.split(whereSeparator: \.isNewline).first else { return nil }
        let prefix = "AgentDock v"
        guard firstLine.hasPrefix(prefix) else { return nil }
        return semanticVersion(String(firstLine.dropFirst(prefix.count)))
    }

    private static func semanticVersion(_ raw: String) -> SemanticVersion? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("AgentDock ")
            .trimmingPrefix("v")
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0 else {
            return nil
        }
        return SemanticVersion(major: major, minor: minor, patch: patch)
    }
}

private struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
