import Foundation

@main
struct InstallerConfigurationTests {
    static func main() throws {
        let offlinePayload = OfflinePayloadPaths(
            agentDockArchive: "/payload/agentdock_darwin_arm64.tar.gz",
            agentDockChecksum: "/payload/agentdock_darwin_arm64.tar.gz.sha256",
            cloudflaredBinary: "/payload/cloudflared_darwin_arm64",
            cloudflaredChecksum: "/payload/cloudflared_darwin_arm64.sha256"
        )
        let local = InstallRequest(mode: .local, serverURL: "", tunnelToken: "")
        let localArguments = try local.installerArguments(
            scriptPath: "/Applications/AgentDock.app/Contents/Resources/install-macos-platform.sh",
            version: "0.6.0",
            resultPath: "/tmp/result.json",
            tokenPath: nil,
            offlinePayload: offlinePayload
        )
        precondition(localArguments.contains("--tunnel"))
        precondition(localArguments.contains("none"))
        precondition(!localArguments.contains("--server-url"))
        precondition(!localArguments.contains("--tunnel-token-file"))
        precondition(localArguments.contains("--offline"))
        precondition(localArguments.contains(offlinePayload.agentDockArchive))
        precondition(localArguments.contains(offlinePayload.agentDockChecksum))
        precondition(localArguments.contains(offlinePayload.cloudflaredBinary))
        precondition(localArguments.contains(offlinePayload.cloudflaredChecksum))

        let named = InstallRequest(
            mode: .named,
            serverURL: "https://mini.example.com/",
            tunnelToken: "secret-token"
        )
        let normalizedURL = try named.validatedServerURL()
        precondition(normalizedURL == "https://mini.example.com")
        let namedArguments = try named.installerArguments(
            scriptPath: "/installer.sh",
            version: "v0.6.0",
            resultPath: "/tmp/result.json",
            tokenPath: "/tmp/token-file",
            offlinePayload: offlinePayload
        )
        precondition(namedArguments.contains("https://mini.example.com"))
        precondition(namedArguments.contains("/tmp/token-file"))
        precondition(!namedArguments.contains("secret-token"))

        let reuseNamed = InstallRequest(
            mode: .named,
            serverURL: "https://mini.example.com",
            tunnelToken: "",
            reuseExistingTunnelToken: true
        )
        let reusedToken = try reuseNamed.validatedTunnelToken()
        precondition(reusedToken == nil)
        let reuseArguments = try reuseNamed.installerArguments(
            scriptPath: "/installer.sh",
            version: "v0.6.0",
            resultPath: "/tmp/result.json",
            tokenPath: nil,
            offlinePayload: offlinePayload
        )
        precondition(reuseArguments.contains("https://mini.example.com"))
        precondition(!reuseArguments.contains("--tunnel-token-file"))

        let environmentText = """
        # preserved comment
        AGENTDOCK_PORT=8765
        AGENTDOCK_AUTH_TOKEN='secret-token'
        AGENTDOCK_NEXUS_ENDPOINT=https://nexus.example.com
        AGENTDOCK_PORT=9999
        """
        let environment = ManagedEnvironment(
            originalText: environmentText,
            values: ManagedEnvironment.parseValues(environmentText)
        )
        precondition(environment.values["AGENTDOCK_PORT"] == "9999")
        precondition(environment.values["AGENTDOCK_NEXUS_ENDPOINT"] == "https://nexus.example.com")
        let updatedData = try environment.dataByUpdating([
            "AGENTDOCK_PORT": "8877",
            "AGENTDOCK_LOG_LEVEL": "debug",
            "AGENTDOCK_NEXUS_TOKEN": "quote'and space",
        ])
        let updatedText = String(decoding: updatedData, as: UTF8.self)
        let updatedValues = ManagedEnvironment.parseValues(updatedText)
        precondition(updatedValues["AGENTDOCK_PORT"] == "8877")
        precondition(updatedValues["AGENTDOCK_AUTH_TOKEN"] == "secret-token")
        precondition(updatedValues["AGENTDOCK_LOG_LEVEL"] == "debug")
        precondition(updatedValues["AGENTDOCK_NEXUS_TOKEN"] == "quote'and space")
        precondition(updatedText.components(separatedBy: "AGENTDOCK_PORT=").count == 2)

        expectFailure("不允许") {
            _ = try environment.dataByUpdating(["AGENTDOCK_OAUTH_TOKEN_SECRET": "nope"])
        }

        expectFailure("不能包含路径") {
            _ = try InstallRequest(mode: .named, serverURL: "https://mini.example.com/mcp", tunnelToken: "x").validatedServerURL()
        }
        expectFailure("必须使用 https") {
            _ = try InstallRequest(mode: .named, serverURL: "http://mini.example.com", tunnelToken: "x").validatedServerURL()
        }
        expectFailure("不能使用 localhost 或 IP") {
            _ = try InstallRequest(mode: .named, serverURL: "https://127.0.0.1", tunnelToken: "x").validatedServerURL()
        }
        expectFailure("请填写 Cloudflare Tunnel Token") {
            _ = try InstallRequest(mode: .named, serverURL: "https://mini.example.com", tunnelToken: " ").validatedTunnelToken()
        }

        print("installer configuration tests passed")
    }

    private static func expectFailure(_ message: String, _ operation: () throws -> Void) {
        do {
            try operation()
            fputs("expected failure: \(message)\n", stderr)
            exit(1)
        } catch {
            guard error.localizedDescription.contains(message) else {
                fputs("unexpected error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }
}
