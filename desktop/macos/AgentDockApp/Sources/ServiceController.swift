import AppKit
import Foundation

struct HealthPayload: Decodable {
    let ok: Bool
    let version: String
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

        let loaded = isLoaded()
        let configuration = ServiceConfiguration.load(from: paths.environment)
        let autostart = isAutostartEnabled()
        guard loaded, let healthURL = configuration?.healthURL else {
            return ServiceStatus(
                installed: true,
                loaded: loaded,
                healthy: false,
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
            let preserveDisabled = !self.isAutostartEnabled()
            if preserveDisabled {
                try self.setLaunchctlDisabled(false)
            }
            do {
                try self.bootstrapIfNeeded()
                try self.kickstart()
                guard let configuration = ServiceConfiguration.load(from: self.paths.environment),
                      self.waitForHealthSynchronously(configuration: configuration, timeout: 30) else {
                    throw ValidationError("AgentDock 已启动，但健康检查没有通过。")
                }
                if preserveDisabled {
                    try self.setLaunchctlDisabled(true)
                }
            } catch {
                if preserveDisabled { try? self.setLaunchctlDisabled(true) }
                throw error
            }
        }
    }

    func stop() async throws {
        try await runInBackground {
            guard self.isLoaded() else { return }
            let result = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["bootout", self.serviceTarget]
            )
            guard result.status == 0 else {
                throw ValidationError(self.commandError(result.output, action: "停止"))
            }
        }
    }

    func restart() async throws {
        if !isLoaded() {
            try await start()
            return
        }
        try await runInBackground {
            try self.kickstart()
            guard let configuration = ServiceConfiguration.load(from: self.paths.environment),
                  self.waitForHealthSynchronously(configuration: configuration, timeout: 30) else {
                throw ValidationError("AgentDock 重启后健康检查没有通过。")
            }
        }
    }

    func setAutostart(enabled: Bool) async throws {
        try await runInBackground {
            let previous = self.isAutostartEnabled()
            guard previous != enabled else { return }
            if enabled {
                do {
                    try self.setLaunchctlDisabled(false)
                    try self.bootstrapIfNeeded()
                    try self.kickstart()
                    guard let configuration = ServiceConfiguration.load(from: self.paths.environment),
                          self.waitForHealthSynchronously(configuration: configuration, timeout: 30) else {
                        throw ValidationError("已启用登录启动，但 AgentDock 健康检查没有通过。")
                    }
                } catch {
                    try? self.stopSynchronously()
                    try? self.setLaunchctlDisabled(true)
                    throw error
                }
            } else {
                do {
                    try self.setLaunchctlDisabled(true)
                    try self.stopSynchronously()
                } catch {
                    try? self.setLaunchctlDisabled(false)
                    throw error
                }
            }
        }
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
            let result = try runProcess(executable: self.paths.binary.path, arguments: ["update"])
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
