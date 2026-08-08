import Foundation

@main
struct InstallerConfigurationTests {
    static func main() async throws {
        let local = InstallRequest(mode: .local, serverURL: "", tunnelToken: "")
        let localURL = try local.validatedServerURL()
        let localToken = try local.validatedTunnelToken()
        precondition(localURL == nil)
        precondition(localToken == nil)

        let named = InstallRequest(
            mode: .named,
            serverURL: "https://mini.example.com/",
            tunnelToken: "secret-token"
        )
        let namedURL = try named.validatedServerURL()
        let namedToken = try named.validatedTunnelToken()
        precondition(namedURL == "https://mini.example.com")
        precondition(namedToken == "secret-token")

        let reuseNamed = InstallRequest(
            mode: .named,
            serverURL: "https://mini.example.com",
            tunnelToken: ""
        )
        let reusedToken = try reuseNamed.validatedTunnelToken()
        precondition(reusedToken == nil)

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

        let acpEnvironmentData = try environment.dataByUpdating([
            "AGENTDOCK_ACP_ENABLED": "true",
            "AGENTDOCK_ACP_AGENT": "grok",
            "AGENTDOCK_ACP_COMMAND": "/Users/test/.local/bin/grok",
            "AGENTDOCK_ACP_ARGS_JSON": "[\"agent\",\"stdio\"]",
            "AGENTDOCK_ACP_ALLOWED_ROOTS": "/Users/test/Project",
        ])
        let acpValues = ManagedEnvironment.parseValues(String(decoding: acpEnvironmentData, as: UTF8.self))
        precondition(acpValues["AGENTDOCK_ACP_AGENT"] == "grok")
        precondition(acpValues["AGENTDOCK_ACP_ARGS_JSON"] == "[\"agent\",\"stdio\"]")
        precondition(ACPAgentPreset.grok.arguments == ["agent", "stdio"])
        precondition(ACPAgentPreset.parse("GROK") == .grok)
        precondition(ACPDesktopConfiguration.parseAllowedRoots("/one, /two") == ["/one", "/two"])
        let encodedGrokArguments = try ACPDesktopConfiguration.encodeArguments(ACPAgentPreset.grok.arguments)
        precondition(encodedGrokArguments == "[\"agent\",\"stdio\"]")
        try testACPExecutableResolution()

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
        let blankTunnelToken = try InstallRequest(
            mode: .named,
            serverURL: "https://mini.example.com",
            tunnelToken: " "
        ).validatedTunnelToken()
        precondition(blankTunnelToken == nil)
        try ServicePortValidation.validate(1024)
        try ServicePortValidation.validate(65535)
        expectFailure("1024 到 65535") {
            try ServicePortValidation.validate(8)
        }

        precondition(AppVersion.matchesCoreVersion(
            "AgentDock v0.7.2\ncommit: test\n",
            expectedDisplayVersion: "v0.7.2"
        ))
        precondition(!AppVersion.matchesCoreVersion(
            "AgentDock v0.7.1\ncommit: test\n",
            expectedDisplayVersion: "v0.7.2"
        ))

        try testTunnelTokenStore()
        try testDesktopUpdateResult()
        try testDesktopUpdateServiceState()
        try await testPublicEndpointChecker()
        print("installer configuration tests passed")
    }

    private static func testDesktopUpdateResult() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDockUpdateResultTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("update-result.json")
        let json = """
        {"schema_version":1,"ok":true,"current_version":"v0.6.9","target_version":"v0.7.0","message":"更新完成"}
        """
        try Data(json.utf8).write(to: path)
        let loaded = DesktopUpdateResult.load(from: path)
        precondition(loaded?.ok == true)
        precondition(FileManager.default.fileExists(atPath: path.path))
        let result = DesktopUpdateResult.consume(from: path)
        precondition(result?.ok == true)
        precondition(result?.targetVersion == "v0.7.0")
        precondition(!FileManager.default.fileExists(atPath: path.path))
    }

    private static func testDesktopUpdateServiceState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDockUpdateServiceStateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("update-services.json")
        let expected = DesktopUpdateServiceState(coreEnabled: true, tunnelEnabled: false)
        try expected.write(to: path)
        let loaded = try DesktopUpdateServiceState.load(from: path)
        precondition(loaded?.coreEnabled == true)
        precondition(loaded?.tunnelEnabled == false)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        precondition(permissions & 0o077 == 0)
        DesktopUpdateServiceState.remove(at: path)
        precondition(!FileManager.default.fileExists(atPath: path.path))
    }

    private static func testACPExecutableResolution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDockACPExecutableTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("grok")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = ACPAgentPreset.grok.resolveExecutable(home: root, environment: [:])
        precondition(resolved == executable.resolvingSymlinksInPath().path)
        precondition(ACPAgentPreset.codex.resolveExecutable(home: root, environment: [:]) == nil)

        let workspace = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let roots = try ACPDesktopConfiguration.validateAllowedRoots([workspace.path, workspace.path])
        precondition(roots == [workspace.resolvingSymlinksInPath().path])
        expectFailure("整个文件系统") {
            _ = try ACPDesktopConfiguration.validateAllowedRoots(["/"])
        }
    }

    private static func testTunnelTokenStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDockTunnelTokenStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(home: root)
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        let namedEnvironment = """
        AGENTDOCK_TUNNEL_MODE='named'
        AGENTDOCK_TUNNEL_TARGET='http://127.0.0.1:8765'
        TUNNEL_TOKEN='saved-token'
        """
        try Data(namedEnvironment.utf8).write(to: paths.tunnelEnvironment)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: paths.tunnelEnvironment.path
        )

        let store = TunnelTokenStore(paths: paths)
        try store.captureExistingTokenIfPresent()
        let migratedToken = try store.storedToken()
        precondition(migratedToken == "saved-token")

        let quickEnvironment = """
        AGENTDOCK_TUNNEL_MODE='quick'
        AGENTDOCK_TUNNEL_TARGET='http://127.0.0.1:8765'
        TUNNEL_TOKEN=''
        """
        try Data(quickEnvironment.utf8).write(to: paths.tunnelEnvironment)
        try store.captureExistingTokenIfPresent()
        let tokenAfterQuickSwitch = try store.storedToken()
        let reusedStoredToken = try store.tokenForNamedTunnel(providedToken: nil)
        let replacementToken = try store.tokenForNamedTunnel(providedToken: " replacement-token ")
        precondition(tokenAfterQuickSwitch == "saved-token")
        precondition(reusedStoredToken == "saved-token")
        precondition(replacementToken == "replacement-token")

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.tunnelTokenStore.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        precondition(permissions & 0o077 == 0)

        try store.persist("new-token")
        let updatedToken = try store.storedToken()
        precondition(updatedToken == "new-token")
        expectFailure("单行文本") {
            try store.persist("line-one\nline-two")
        }
    }

    private static func testPublicEndpointChecker() async throws {
        let publicMCPURL = URL(string: "https://temporary.example.com/mcp")!
        precondition(
            PublicEndpointChecker.healthURL(from: publicMCPURL)?.absoluteString
                == "https://temporary.example.com/healthz"
        )
        precondition(PublicEndpointChecker.healthURL(from: URL(string: "http://temporary.example.com/mcp")!) == nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let checker = PublicEndpointChecker(session: session)

        MockURLProtocol.handler = { request in
            precondition(request.url?.absoluteString == "https://temporary.example.com/healthz")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"ok\":true,\"version\":\"0.6.0\"}".utf8))
        }
        let success = await checker.check(publicMCPURL: publicMCPURL)
        precondition(success.isReachable)
        precondition(success.message == "可正常访问")
        precondition(success.latencyMilliseconds != nil)

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 502,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }
        let badGateway = await checker.check(publicMCPURL: publicMCPURL)
        precondition(!badGateway.isReachable)
        precondition(badGateway.message == "公网地址返回 HTTP 502")

        MockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let timeout = await checker.check(publicMCPURL: publicMCPURL)
        precondition(!timeout.isReachable)
        precondition(timeout.message == "公网访问超时")
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

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
