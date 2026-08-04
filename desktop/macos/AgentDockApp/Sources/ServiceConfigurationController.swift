import Darwin
import Foundation

struct EditableServiceSettings {
    let port: Int
    let logLevel: String
    let nexusEndpoint: String
    let nexusTokenReplacement: String?
    let browserEnabled: Bool
    let browserRunnerDir: String
    let browserNodePath: String
    let acpEnabled: Bool
    let acpAgent: ACPAgentPreset
    let acpCommand: String
    let acpAllowedRoots: [String]

    func validated() throws -> EditableServiceSettings {
        try ServicePortValidation.validate(port)
        let normalizedLogLevel = ServiceConfiguration.normalizedLogLevel(logLevel)
        guard ["debug", "info", "warn", "error"].contains(normalizedLogLevel) else {
            throw ValidationError("日志级别必须是 debug、info、warn 或 error。")
        }

        let endpoint = try Self.normalizeNexusEndpoint(nexusEndpoint)
        if let nexusTokenReplacement,
           nexusTokenReplacement.contains("\n") || nexusTokenReplacement.contains("\r") {
            throw ValidationError("Nexus Token 必须是单行文本。")
        }

        let runner = browserRunnerDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = browserNodePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if browserEnabled {
            guard runner.hasPrefix("/"), node.hasPrefix("/") else {
                throw ValidationError("浏览器运行目录和 Node 路径必须是绝对路径。")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: runner, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ValidationError("浏览器运行目录不存在，请重新安装浏览器支持。")
            }
            guard FileManager.default.fileExists(atPath: runner + "/browser-runner.js"),
                  FileManager.default.isExecutableFile(atPath: node) else {
                throw ValidationError("浏览器支持文件不完整，请重新安装浏览器支持。")
            }
        }

        var command = ""
        var allowedRoots: [String] = []
        if acpEnabled {
            guard let resolved = acpAgent.resolveExecutable(configuredCommand: acpCommand) else {
                throw ValidationError("\(acpAgent.title) 不可用：\(acpAgent.missingExecutableMessage)。")
            }
            command = resolved
            allowedRoots = try ACPDesktopConfiguration.validateAllowedRoots(acpAllowedRoots)
        }

        return EditableServiceSettings(
            port: port,
            logLevel: normalizedLogLevel,
            nexusEndpoint: endpoint,
            nexusTokenReplacement: nexusTokenReplacement,
            browserEnabled: browserEnabled,
            browserRunnerDir: runner,
            browserNodePath: node,
            acpEnabled: acpEnabled,
            acpAgent: acpAgent,
            acpCommand: command,
            acpAllowedRoots: allowedRoots
        )
    }

    private static func normalizeNexusEndpoint(_ raw: String) throws -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return "" }
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            throw ValidationError("Nexus Endpoint 必须是有效的 HTTP(S) 地址。")
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ValidationError("Nexus Endpoint 不能包含账号、查询参数或片段。")
        }
        components.scheme = scheme
        guard var normalized = components.string else {
            throw ValidationError("无法规范化 Nexus Endpoint。")
        }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }
}

final class ServiceConfigurationController {
    private let service: ServiceController
    private let fileManager = FileManager.default

    init(service: ServiceController) {
        self.service = service
    }

    func apply(_ requested: EditableServiceSettings) async throws {
        let settings = try requested.validated()
        let environmentURL = service.paths.environment
        let originalData = try readPrivateRegularFile(environmentURL)
        let environment = try ManagedEnvironment.load(from: environmentURL)
        var replacements = [
            "AGENTDOCK_PORT": String(settings.port),
            "AGENTDOCK_LOG_LEVEL": settings.logLevel,
            "AGENTDOCK_NEXUS_ENDPOINT": settings.nexusEndpoint,
            "AGENTDOCK_BROWSER_ENABLED": settings.browserEnabled ? "true" : "false",
            "AGENTDOCK_BROWSER_RUNNER_DIR": settings.browserRunnerDir,
            "AGENTDOCK_BROWSER_NODE_PATH": settings.browserNodePath,
            "AGENTDOCK_ACP_ENABLED": settings.acpEnabled ? "true" : "false",
            "AGENTDOCK_ACP_AGENT": settings.acpAgent.rawValue,
            "AGENTDOCK_ACP_COMMAND": settings.acpCommand,
            "AGENTDOCK_ACP_ARGS_JSON": try ACPDesktopConfiguration.encodeArguments(settings.acpAgent.arguments),
            "AGENTDOCK_ACP_ALLOWED_ROOTS": settings.acpAllowedRoots.joined(separator: ","),
        ]
        if settings.acpEnabled {
            // 桌面预设依赖各 Agent 自己的登录状态，不继承上一个 Agent 的密钥映射。
            replacements["AGENTDOCK_ACP_ENV_FROM_ENV_JSON"] = "{}"
        }
        if let replacement = settings.nexusTokenReplacement {
            replacements["AGENTDOCK_NEXUS_TOKEN"] = replacement
        }
        let updatedData = try environment.dataByUpdating(replacements)
        let wasLoaded = service.isLoaded()

        try await service.runInBackground {
            try self.writePrivateAtomically(updatedData, to: environmentURL)
        }
        guard wasLoaded else { return }

        do {
            try await service.restart()
        } catch {
            let originalError = error
            do {
                try await service.runInBackground {
                    try self.writePrivateAtomically(originalData, to: environmentURL)
                }
                try await service.restart()
            } catch {
                throw ValidationError("新配置启动失败，而且旧配置恢复验证也失败：\(error.localizedDescription)")
            }
            throw ValidationError("新配置启动失败，已恢复旧配置：\(originalError.localizedDescription)")
        }
    }

    private func readPrivateRegularFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ValidationError("AgentDock 配置必须是普通文件，不能是符号链接。")
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let owner = attributes[.ownerAccountID] as? NSNumber,
           owner.uint32Value != getuid() {
            throw ValidationError("AgentDock 配置文件不属于当前用户。")
        }
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0 {
            throw ValidationError("AgentDock 配置文件权限过宽，请先恢复为 0600。")
        }
        return try Data(contentsOf: url)
    }

    private func writePrivateAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ValidationError("无法创建 AgentDock 配置临时文件。")
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if Darwin.rename(temporary.path, url.path) != 0 {
            throw ValidationError("无法原子替换 AgentDock 配置：\(String(cString: strerror(errno)))")
        }
    }
}
