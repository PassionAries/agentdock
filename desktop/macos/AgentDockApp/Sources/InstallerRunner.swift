import Foundation

struct InstallResult: Decodable {
    let schemaVersion: Int
    let ok: Bool
    let version: String
    let healthy: Bool
    let localMCPURL: String
    let tunnelMode: String
    let publicURL: String
    let publicMCPURL: String
    let authToken: String
    let oauthPassword: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ok
        case version
        case healthy
        case localMCPURL = "local_mcp_url"
        case tunnelMode = "tunnel_mode"
        case publicURL = "public_url"
        case publicMCPURL = "public_mcp_url"
        case authToken = "auth_token"
        case oauthPassword = "oauth_password"
    }
}

final class InstallerRunner {
    func run(request: InstallRequest) async throws -> InstallResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.runSynchronously(request: request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSynchronously(request: InstallRequest) throws -> InstallResult {
        guard let scriptPath = Bundle.main.path(forResource: "install-macos-platform", ofType: "sh") else {
            throw ValidationError("应用包缺少 macOS 安装脚本。")
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "latest"
        let installedBinary = AppPaths().binary
        if FileManager.default.isExecutableFile(atPath: installedBinary.path) {
            let installedVersion = try runProcess(executable: installedBinary.path, arguments: ["--version"])
            guard installedVersion.status == 0 else {
                throw ValidationError("无法确认当前 AgentDock 核心版本，已取消配置变更。")
            }
            try InstallerVersionGuard.validate(
                bundleVersion: version,
                installedVersionOutput: installedVersion.output
            )
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDockInstaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryDirectory.path)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let tokenStore = TunnelTokenStore()
        // 切换到临时或本机模式前，先从当前 Named Tunnel 配置迁移 Token；
        // 后续安装脚本可以安全重写或删除活动 cloudflared.env。
        try tokenStore.captureExistingTokenIfPresent()

        let resultURL = temporaryDirectory.appendingPathComponent("result.json")
        let offlinePayload = try requiredOfflinePayload()
        let providedTunnelToken = try request.validatedTunnelToken()
        var tokenURL: URL?
        if request.mode == .named {
            let token = try tokenStore.tokenForNamedTunnel(providedToken: providedTunnelToken)
            let url = temporaryDirectory.appendingPathComponent("tunnel-token")
            guard FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw ValidationError("无法创建安全的 Tunnel Token 临时文件。")
            }
            tokenURL = url
        }

        let arguments = try request.installerArguments(
            scriptPath: scriptPath,
            version: version,
            resultPath: resultURL.path,
            tokenPath: tokenURL?.path,
            offlinePayload: offlinePayload
        )
        let execution = try runProcess(executable: "/bin/zsh", arguments: arguments)
        if execution.status != 0 {
            throw ValidationError(extractInstallerError(from: execution.output))
        }
        guard FileManager.default.fileExists(atPath: resultURL.path) else {
            throw ValidationError("安装器执行完成，但没有生成安装结果。")
        }
        let data = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(InstallResult.self, from: data)
        guard result.schemaVersion == 1, result.ok else {
            throw ValidationError("安装结果格式不受支持。")
        }

        // 用户输入的新 Token 只有在安装和健康检查均成功后才覆盖保存值。
        if let providedTunnelToken {
            try tokenStore.persist(providedTunnelToken)
        }
        return result
    }

    private static func requiredOfflinePayload() throws -> OfflinePayloadPaths {
#if arch(arm64)
        let architecture = "arm64"
#elseif arch(x86_64)
        let architecture = "amd64"
#else
        throw ValidationError("当前 Mac 架构不受离线安装包支持。")
#endif

        guard let resources = Bundle.main.resourceURL else {
            throw ValidationError("应用包缺少资源目录。")
        }
        let payloadDirectory = resources.appendingPathComponent("offline-payload", isDirectory: true)
        let archive = payloadDirectory.appendingPathComponent("agentdock_darwin_\(architecture).tar.gz")
        let archiveChecksum = payloadDirectory.appendingPathComponent("agentdock_darwin_\(architecture).tar.gz.sha256")
        let cloudflared = payloadDirectory.appendingPathComponent("cloudflared_darwin_\(architecture)")
        let cloudflaredChecksum = payloadDirectory.appendingPathComponent("cloudflared_darwin_\(architecture).sha256")

        for (url, label) in [
            (archive, "AgentDock 核心载荷"),
            (archiveChecksum, "AgentDock 核心校验文件"),
            (cloudflared, "cloudflared 载荷"),
            (cloudflaredChecksum, "cloudflared 校验文件"),
        ] {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ValidationError("应用包缺少有效的\(label)：\(url.lastPathComponent)")
            }
        }
        guard FileManager.default.isExecutableFile(atPath: cloudflared.path) else {
            throw ValidationError("应用包中的 cloudflared 载荷不可执行。")
        }

        return OfflinePayloadPaths(
            agentDockArchive: archive.path,
            agentDockChecksum: archiveChecksum.path,
            cloudflaredBinary: cloudflared.path,
            cloudflaredChecksum: cloudflaredChecksum.path
        )
    }

    private static func extractInstallerError(from output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        if let errorLine = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return String(errorLine.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? "安装失败，请打开日志目录查看详情。"
    }
}

struct ProcessExecution {
    let status: Int32
    let output: String
}

func runProcess(
    executable: String,
    arguments: [String],
    environment: [String: String] = [:]
) throws -> ProcessExecution {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if !environment.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessExecution(
        status: process.terminationStatus,
        output: String(data: outputData, encoding: .utf8) ?? ""
    )
}

func runUpdateProcess(
    executable: String,
    arguments: [String],
    environment: [String: String],
    outputURL: URL
) throws -> ProcessExecution {
    let outputDirectory = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: outputDirectory.path
    )
    guard FileManager.default.createFile(
        atPath: outputURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
    ) else {
        throw ValidationError("无法创建更新日志文件。")
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: outputURL.path
    )
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    defer { try? outputHandle.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }
    process.standardOutput = outputHandle
    process.standardError = outputHandle
    try process.run()
    process.waitUntilExit()
    try outputHandle.synchronize()

    let outputData = (try? Data(contentsOf: outputURL)) ?? Data()
    return ProcessExecution(
        status: process.terminationStatus,
        output: String(data: outputData, encoding: .utf8) ?? ""
    )
}
