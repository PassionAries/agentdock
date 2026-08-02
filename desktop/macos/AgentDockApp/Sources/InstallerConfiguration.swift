import Foundation

enum TunnelMode: String, CaseIterable {
    case local = "none"
    case quick
    case named

    var title: String {
        switch self {
        case .local: return "仅本机使用"
        case .quick: return "临时公网访问"
        case .named: return "使用自己的 Cloudflare 域名"
        }
    }

    var detail: String {
        switch self {
        case .local:
            return "只监听本机地址，不开放公网访问。"
        case .quick:
            return "自动生成 trycloudflare.com 临时地址，适合快速体验。"
        case .named:
            return "使用固定 HTTPS 地址，适合长期运行。"
        }
    }
}

struct InstallRequest {
    let mode: TunnelMode
    let serverURL: String
    let tunnelToken: String
    let reuseExistingTunnelToken: Bool

    init(mode: TunnelMode, serverURL: String, tunnelToken: String, reuseExistingTunnelToken: Bool = false) {
        self.mode = mode
        self.serverURL = serverURL
        self.tunnelToken = tunnelToken
        self.reuseExistingTunnelToken = reuseExistingTunnelToken
    }

    func validatedServerURL() throws -> String? {
        guard mode == .named else { return nil }
        let candidate = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw ValidationError("请填写固定 HTTPS 公网地址。")
        }
        guard var components = URLComponents(string: candidate) else {
            throw ValidationError("公网地址格式无效。")
        }
        guard components.scheme?.lowercased() == "https" else {
            throw ValidationError("公网地址必须使用 https://。")
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw ValidationError("公网地址缺少有效域名。")
        }
        guard host != "localhost", host.contains("."), !isIPAddress(host) else {
            throw ValidationError("公网地址必须填写域名，不能使用 localhost 或 IP。")
        }
        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ValidationError("公网地址只能填写 HTTPS Origin，不能包含账号、端口、查询参数或片段。")
        }
        let path = components.percentEncodedPath
        guard path.isEmpty || path == "/" else {
            throw ValidationError("公网地址不能包含路径，请不要填写 /mcp。")
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let normalized = components.string else {
            throw ValidationError("无法规范化公网地址。")
        }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    func validatedTunnelToken() throws -> String? {
        guard mode == .named else { return nil }
        let token = tunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty, reuseExistingTunnelToken {
            return nil
        }
        guard !token.isEmpty else {
            throw ValidationError("请填写 Cloudflare Tunnel Token。")
        }
        guard !token.contains("\n"), !token.contains("\r") else {
            throw ValidationError("Tunnel Token 必须是单行文本。")
        }
        return token
    }

    func installerArguments(
        scriptPath: String,
        version: String,
        resultPath: String,
        tokenPath: String?
    ) throws -> [String] {
        var arguments = [
            scriptPath,
            "--version", version.hasPrefix("v") ? version : "v\(version)",
            "--register-service",
            "--non-interactive",
            "--tunnel", mode.rawValue,
            "--result-file", resultPath,
        ]
        if mode == .named {
            arguments += ["--server-url", try validatedServerURL() ?? ""]
            if let tokenPath, !tokenPath.isEmpty {
                arguments += ["--tunnel-token-file", tokenPath]
            } else if !reuseExistingTunnelToken {
                throw ValidationError("缺少安全的 Tunnel Token 临时文件。")
            }
        }
        return arguments
    }

    private func isIPAddress(_ host: String) -> Bool {
        let ipv4Parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if ipv4Parts.count == 4 && ipv4Parts.allSatisfy({ part in
            guard let value = Int(part) else { return false }
            return value >= 0 && value <= 255
        }) {
            return true
        }
        return host.contains(":")
    }
}

struct ValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
