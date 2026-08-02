import Foundation

struct AppPaths {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var binary: URL { home.appendingPathComponent(".local/bin/agentdock") }
    var appSupport: URL { home.appendingPathComponent("Library/Application Support/AgentDock") }
    var environment: URL { appSupport.appendingPathComponent("agentdock.env") }
    var launchAgent: URL { home.appendingPathComponent("Library/LaunchAgents/com.uvwt.agentdock.plist") }
    var tunnelLaunchAgent: URL { home.appendingPathComponent("Library/LaunchAgents/com.uvwt.agentdock.cloudflared.plist") }
    var logs: URL { home.appendingPathComponent("Library/Logs/AgentDock") }
    var workDirectory: URL { home.appendingPathComponent("AgentDock") }
}

struct RuntimeConfiguration {
    let host: String
    let port: Int
    let publicURL: String?

    var healthHost: String {
        switch host {
        case "0.0.0.0", "": return "127.0.0.1"
        case "::", "[::]": return "::1"
        default: return host
        }
    }

    var localMCPURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = healthHost
        components.port = port
        components.path = "/mcp"
        return components.url
    }

    var healthURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = healthHost
        components.port = port
        components.path = "/healthz"
        return components.url
    }

    var publicMCPURL: URL? {
        guard let publicURL, !publicURL.isEmpty else { return nil }
        return URL(string: publicURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/mcp")
    }

    static func load(from path: URL) -> RuntimeConfiguration? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard ["AGENTDOCK_HOST", "AGENTDOCK_PORT", "AGENTDOCK_SERVER_URL"].contains(key) else { continue }
            let value = String(line[line.index(after: separator)...])
            values[key] = decodeShellValue(value)
        }
        let host = values["AGENTDOCK_HOST"] ?? "127.0.0.1"
        guard let port = Int(values["AGENTDOCK_PORT"] ?? "8765"), (1...65535).contains(port) else { return nil }
        return RuntimeConfiguration(host: host, port: port, publicURL: values["AGENTDOCK_SERVER_URL"])
    }

    private static func decodeShellValue(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast())
        }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }
}
