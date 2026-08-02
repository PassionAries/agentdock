import Foundation

@main
struct InstallerConfigurationTests {
    static func main() throws {
        let local = InstallRequest(mode: .local, serverURL: "", tunnelToken: "")
        let localArguments = try local.installerArguments(
            scriptPath: "/Applications/AgentDock.app/Contents/Resources/install-macos-platform.sh",
            version: "0.5.4",
            resultPath: "/tmp/result.json",
            tokenPath: nil
        )
        precondition(localArguments.contains("--tunnel"))
        precondition(localArguments.contains("none"))
        precondition(!localArguments.contains("--server-url"))
        precondition(!localArguments.contains("--tunnel-token-file"))

        let named = InstallRequest(
            mode: .named,
            serverURL: "https://mini.example.com/",
            tunnelToken: "secret-token"
        )
        let normalizedURL = try named.validatedServerURL()
        precondition(normalizedURL == "https://mini.example.com")
        let namedArguments = try named.installerArguments(
            scriptPath: "/installer.sh",
            version: "v0.5.4",
            resultPath: "/tmp/result.json",
            tokenPath: "/tmp/token-file"
        )
        precondition(namedArguments.contains("https://mini.example.com"))
        precondition(namedArguments.contains("/tmp/token-file"))
        precondition(!namedArguments.contains("secret-token"))

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
