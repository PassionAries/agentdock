import Foundation

enum ACPAgentPreset: String, CaseIterable {
    case codex
    case claude
    case grok

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok Build"
        }
    }

    var executableNames: [String] {
        switch self {
        case .codex: return ["codex-acp"]
        case .claude: return ["claude-agent-acp"]
        case .grok: return ["grok"]
        }
    }

    var arguments: [String] {
        switch self {
        case .grok: return ["agent", "stdio"]
        case .codex, .claude: return []
        }
    }

    var missingExecutableMessage: String {
        switch self {
        case .codex: return "未找到 codex-acp"
        case .claude: return "未找到 claude-agent-acp"
        case .grok: return "未找到 grok"
        }
    }

    static func parse(_ raw: String) -> ACPAgentPreset {
        ACPAgentPreset(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .codex
    }

    func resolveExecutable(
        configuredCommand: String = "",
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        var candidates: [String] = []
        let configured = configuredCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            candidates.append(configured)
        }

        var directories = [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
        if let path = environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }

        for directory in directories {
            for executableName in executableNames {
                candidates.append(URL(fileURLWithPath: directory).appendingPathComponent(executableName).path)
            }
        }

        var seen = Set<String>()
        for candidate in candidates {
            let normalized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(normalized).inserted,
                  FileManager.default.isExecutableFile(atPath: normalized) else {
                continue
            }
            let resolved = URL(fileURLWithPath: normalized).resolvingSymlinksInPath().path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            return resolved
        }
        return nil
    }
}

struct ACPDesktopConfiguration {
    static func parseAllowedRoots(_ raw: String) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func validateAllowedRoots(_ roots: [String]) throws -> [String] {
        guard !roots.isEmpty else {
            throw ValidationError("请至少选择一个 Coding Agent 可访问的目录。")
        }

        var validated: [String] = []
        var seen = Set<String>()
        for rawRoot in roots {
            let root = rawRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            guard root.hasPrefix("/") else {
                throw ValidationError("Coding Agent 允许目录必须是绝对路径。")
            }
            let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved != "/" else {
                throw ValidationError("不能把整个文件系统作为 Coding Agent 允许目录。")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw ValidationError("Coding Agent 允许目录不存在：\(root)")
            }
            if seen.insert(resolved).inserted {
                validated.append(resolved)
            }
        }
        return validated
    }

    static func encodeArguments(_ arguments: [String]) throws -> String {
        let data = try JSONEncoder().encode(arguments)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ValidationError("无法编码 Coding Agent 启动参数。")
        }
        return value
    }
}
