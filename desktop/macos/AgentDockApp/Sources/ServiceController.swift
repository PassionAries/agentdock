import AppKit
import Foundation

struct HealthPayload: Decodable {
    let ok: Bool
    let version: String
}

private struct NativeServiceStatus: Decodable {
    let running: Bool
    let healthy: Bool
    let startupEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case running
        case healthy
        case startupEnabled = "startup_enabled"
    }
}

struct ServiceStatus {
    let installed: Bool
    let loaded: Bool
    let healthy: Bool
    let version: String?
    let configuration: ServiceConfiguration?
    let autostartEnabled: Bool

    static let missing = ServiceStatus(
        installed: false,
        loaded: false,
        healthy: false,
        version: nil,
        configuration: nil,
        autostartEnabled: false
    )
}

final class ServiceController: @unchecked Sendable {
    let paths: AppPaths
    let label = "com.uvwt.agentdock"

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
    }

    func status() async -> ServiceStatus {
        let fileManager = FileManager.default
        let installed = fileManager.isExecutableFile(atPath: paths.binary.path)
            && fileManager.fileExists(atPath: paths.environment.path)
            && fileManager.fileExists(atPath: paths.launchAgent.path)
        guard installed else { return .missing }

        let configuration = ServiceConfiguration.load(from: paths.environment)
        let nativeStatus = try? await runInBackground { try self.readNativeStatus() }
        let loaded = nativeStatus?.running ?? isLoaded()
        let autostart = nativeStatus?.startupEnabled ?? isAutostartEnabled()
        let healthy = nativeStatus?.healthy ?? false
        guard loaded, healthy, let healthURL = configuration?.healthURL else {
            return ServiceStatus(
                installed: true,
                loaded: loaded,
                healthy: healthy,
                version: nil,
                configuration: configuration,
                autostartEnabled: autostart
            )
        }

        let health = await fetchHealth(url: healthURL)
        return ServiceStatus(
            installed: true,
            loaded: true,
            healthy: health?.ok == true,
            version: health?.version,
            configuration: configuration,
            autostartEnabled: autostart
        )
    }

    func start() async throws {
        try await runInBackground {
            try self.runNativeService(arguments: ["start"])
        }
    }

    func stop() async throws {
        try await runInBackground {
            try self.runNativeService(arguments: ["stop"])
        }
    }

    func restart() async throws {
        try await runInBackground {
            try self.runNativeService(arguments: ["restart"])
        }
    }

    func setAutostart(enabled: Bool) async throws {
        try await runInBackground {
            try self.runNativeService(arguments: [
                "autostart",
                "--component", "core",
                "--enabled", enabled ? "true" : "false"
            ])
        }
    }

    private func runNativeService(arguments: [String]) throws {
        let result = try runProcess(
            executable: paths.binary.path,
            arguments: ["service"] + arguments + ["--runtime-root", paths.appSupport.path]
        )
        guard result.status == 0 else {
            throw ValidationError(commandError(result.output, action: arguments.first ?? "管理"))
        }
    }

    private func readNativeStatus() throws -> NativeServiceStatus {
        let result = try runProcess(
            executable: paths.binary.path,
            arguments: ["service", "status", "--runtime-root", paths.appSupport.path]
        )
        guard result.status == 0,
              let data = result.output.data(using: .utf8) else {
            throw ValidationError(commandError(result.output, action: "读取状态"))
        }
        return try JSONDecoder().decode(NativeServiceStatus.self, from: data)
    }

    func isAutostartEnabled() -> Bool {
        guard let result = try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["print-disabled", serviceDomain]
        ), result.status == 0 else {
            return true
        }
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = "[\\\"']?\(escaped)[\\\"']?\\s*=>\\s*true"
        return result.output.range(of: pattern, options: .regularExpression) == nil
    }

    func isLoaded() -> Bool {
        (try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["print", serviceTarget]
        ).status) == 0
    }

    func waitForHealth(configuration: ServiceConfiguration, timeout: TimeInterval = 30) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.waitForHealthSynchronously(configuration: configuration, timeout: timeout))
            }
        }
    }

    func update() async throws -> String {
        try await runInBackground {
            let result = try runUpdateProcess(
                executable: self.paths.binary.path,
                arguments: ["update"],
                environment: ["AGENTDOCK_DESKTOP_APP_PATH": Bundle.main.bundlePath],
                outputURL: self.paths.updateLog
            )
            guard result.status == 0 else {
                throw ValidationError(self.commandError(result.output, action: "更新"))
            }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func openLogs() {
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.logs)
    }

    func openConfiguration() {
        try? FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.appSupport)
    }

    private var serviceDomain: String { "gui/\(getuid())" }
    private var serviceTarget: String { "\(serviceDomain)/\(label)" }

    private func bootstrapIfNeeded() throws {
        guard !isLoaded() else { return }
        let result = try runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", serviceDomain, paths.launchAgent.path]
        )
        guard result.status == 0 else {
            throw ValidationError(commandError(result.output, action: "加载"))
        }
    }

    private func kickstart() throws {
        let result = try runProcess(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "-k", serviceTarget]
        )
        guard result.status == 0 else {
            throw ValidationError(commandError(result.output, action: "启动"))
        }
    }

    private func stopSynchronously() throws {
        guard isLoaded() else { return }
        let result = try runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootout", serviceTarget]
        )
        guard result.status == 0 else {
            throw ValidationError(commandError(result.output, action: "停止"))
        }
    }

    private func setLaunchctlDisabled(_ disabled: Bool) throws {
        let action = disabled ? "disable" : "enable"
        let result = try runProcess(
            executable: "/bin/launchctl",
            arguments: [action, serviceTarget]
        )
        guard result.status == 0 else {
            throw ValidationError(commandError(result.output, action: disabled ? "关闭登录启动" : "开启登录启动"))
        }
    }

    private func waitForHealthSynchronously(configuration: ServiceConfiguration, timeout: TimeInterval) -> Bool {
        guard let url = configuration.healthURL else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let semaphore = DispatchSemaphore(value: 0)
            var healthy = false
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.5
            URLSession.shared.dataTask(with: request) { data, response, _ in
                defer { semaphore.signal() }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let data,
                      let payload = try? JSONDecoder().decode(HealthPayload.self, from: data) else { return }
                healthy = payload.ok
            }.resume()
            _ = semaphore.wait(timeout: .now() + 2)
            if healthy { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func fetchHealth(url: URL) async -> HealthPayload? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2.5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(HealthPayload.self, from: data)
        } catch {
            return nil
        }
    }

    private func commandError(_ output: String, action: String) -> String {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "AgentDock \(action)失败。" : message
    }

    func runInBackground<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
