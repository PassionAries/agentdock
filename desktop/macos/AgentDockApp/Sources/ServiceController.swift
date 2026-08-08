import AppKit
import Foundation
import ServiceManagement

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
    let requiresApproval: Bool
    let migrationRequired: Bool

    static let missing = ServiceStatus(
        installed: false,
        loaded: false,
        healthy: false,
        version: nil,
        configuration: nil,
        autostartEnabled: false,
        requiresApproval: false,
        migrationRequired: false
    )
}

final class ServiceController: @unchecked Sendable {
    static let coreLabel = "com.uvwt.agentdock.core"
    static let tunnelLabel = "com.uvwt.agentdock.tunnel"
    static let corePlistName = "com.uvwt.agentdock.core.plist"
    static let tunnelPlistName = "com.uvwt.agentdock.tunnel.plist"

    let paths: AppPaths

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
    }

    func status() async -> ServiceStatus {
        let fileManager = FileManager.default
        let migrationRequired = LegacyDesktopRuntimeMigration.isPresent(paths: paths)
        let installed = fileManager.isExecutableFile(atPath: paths.binary.path)
            && fileManager.isExecutableFile(atPath: paths.cloudflared.path)
            && fileManager.fileExists(atPath: paths.coreSkillBundle.appendingPathComponent("manifest.json").path)
            && fileManager.fileExists(atPath: paths.environment.path)
        guard installed else { return .missing }

        let configuration = ServiceConfiguration.load(from: paths.environment)
        let registration = coreService.status
        let requiresApproval = registration == .requiresApproval
        let enabled = registration == .enabled
        let registered = enabled || requiresApproval
        let loaded = enabled && isLoaded(label: Self.coreLabel)

        guard loaded, let healthURL = configuration?.healthURL else {
            return ServiceStatus(
                installed: true,
                loaded: loaded,
                healthy: false,
                version: nil,
                configuration: configuration,
                autostartEnabled: registered,
                requiresApproval: requiresApproval,
                migrationRequired: migrationRequired
            )
        }

        let health = await fetchHealth(url: healthURL)
        return ServiceStatus(
            installed: true,
            loaded: true,
            healthy: health?.ok == true,
            version: health?.version,
            configuration: configuration,
            autostartEnabled: registered,
            requiresApproval: requiresApproval,
            migrationRequired: migrationRequired
        )
    }

    func start() async throws {
        try registerCoreIfNeeded()
        guard let configuration = ServiceConfiguration.load(from: paths.environment),
              await waitForHealth(configuration: configuration) else {
            throw ValidationError("AgentDock 后台服务已启用，但健康检查没有通过。")
        }
    }

    func stop() async throws {
        try unregister(service: coreService, label: Self.coreLabel)
    }

    func restart() async throws {
        try reregister(service: coreService, label: Self.coreLabel, displayName: "AgentDock Core")
        guard let configuration = ServiceConfiguration.load(from: paths.environment),
              await waitForHealth(configuration: configuration) else {
            throw ValidationError("AgentDock Core 已重新注册，但健康检查没有通过。")
        }
    }

    func setAutostart(enabled: Bool) async throws {
        if enabled {
            try await start()
        } else {
            try await stop()
        }
    }

    func tunnelEnabled() -> Bool {
        tunnelService.status == .enabled
    }

    func setTunnelEnabled(_ enabled: Bool) throws {
        if enabled {
            try register(service: tunnelService, displayName: "AgentDock Tunnel")
        } else {
            try unregister(service: tunnelService, label: Self.tunnelLabel)
        }
    }

    func restartTunnel() throws {
        try reregister(service: tunnelService, label: Self.tunnelLabel, displayName: "AgentDock Tunnel")
    }

    func reregisterBackgroundServices(coreEnabled: Bool, tunnelEnabled: Bool) async throws {
        if coreEnabled {
            try restoreRegistration(service: coreService, label: Self.coreLabel, displayName: "AgentDock Core")
        } else {
            try unregister(service: coreService, label: Self.coreLabel)
        }
        if tunnelEnabled {
            try restoreRegistration(service: tunnelService, label: Self.tunnelLabel, displayName: "AgentDock Tunnel")
        } else {
            try unregister(service: tunnelService, label: Self.tunnelLabel)
        }
        if tunnelEnabled,
           tunnelService.status == .enabled,
           !(await waitForTunnelProcess()) {
            throw ValidationError("重新注册新版 AgentDock Tunnel 后进程没有稳定运行。")
        }
        if coreService.status == .enabled,
           let configuration = ServiceConfiguration.load(from: paths.environment),
           !(await waitForHealth(configuration: configuration)) {
            throw ValidationError("重新注册新版 AgentDock Core 后健康检查没有通过。")
        }
    }

    func openBackgroundItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func waitForTunnelProcess(timeout: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.waitForStableLaunchdProcess(
                    label: Self.tunnelLabel,
                    timeout: timeout
                ))
            }
        }
    }

    func isLoaded() -> Bool {
        isLoaded(label: Self.coreLabel)
    }

    func waitForHealth(configuration: ServiceConfiguration, timeout: TimeInterval = 30) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.waitForHealthSynchronously(configuration: configuration, timeout: timeout))
            }
        }
    }

    func update() async throws -> String {
        try validatePersistentAppLocation()
        let currentStatus = await status()
        let serviceState = DesktopUpdateServiceState(
            coreEnabled: currentStatus.autostartEnabled,
            tunnelEnabled: tunnelEnabled()
        )
        try serviceState.write(to: paths.updateServiceState)

        do {
            try setTunnelEnabled(false)
            try await stop()
            return try await runInBackground {
                let result = try runUpdateProcess(
                    executable: self.paths.binary.path,
                    arguments: ["update"],
                    environment: ["AGENTDOCK_DESKTOP_APP_PATH": self.paths.appBundle.path],
                    outputURL: self.paths.updateLog
                )
                guard result.status == 0 else {
                    throw ValidationError(self.commandError(result.output, action: "更新"))
                }
                return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            let updateError = error
            do {
                try await reregisterBackgroundServices(
                    coreEnabled: serviceState.coreEnabled,
                    tunnelEnabled: serviceState.tunnelEnabled
                )
                DesktopUpdateServiceState.remove(at: paths.updateServiceState)
            } catch {
                throw ValidationError("更新没有应用，而且后台服务恢复失败：\(updateError.localizedDescription)；\(error.localizedDescription)")
            }
            throw updateError
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

    private var coreService: SMAppService {
        SMAppService.agent(plistName: Self.corePlistName)
    }

    private var tunnelService: SMAppService {
        SMAppService.agent(plistName: Self.tunnelPlistName)
    }

    private func registerCoreIfNeeded() throws {
        try register(service: coreService, displayName: "AgentDock Core")
    }

    private func register(service: SMAppService, displayName: String) throws {
        try validatePersistentAppLocation()
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            throw ValidationError("\(displayName) 已注册，但需要你在“系统设置 → 通用 → 登录项与扩展”中允许后台运行。")
        case .notRegistered:
            try service.register()
        case .notFound:
            throw ValidationError("AgentDock.app 缺少 \(displayName) 的后台服务定义，请重新安装应用。")
        @unknown default:
            throw ValidationError("无法确认 \(displayName) 的后台服务状态。")
        }
        if service.status == .requiresApproval {
            throw ValidationError("\(displayName) 需要你在“系统设置 → 通用 → 登录项与扩展”中允许后台运行。")
        }
        guard service.status == .enabled else {
            throw ValidationError("\(displayName) 注册完成，但系统没有将它标记为可运行。")
        }
    }

    private func unregister(service: SMAppService, label: String) throws {
        switch service.status {
        case .notRegistered, .notFound:
            return
        case .enabled, .requiresApproval:
            try service.unregister()
            guard waitUntilUnloaded(label: label, timeout: 5) else {
                throw ValidationError("后台服务 \(label) 注销后仍未退出。")
            }
        @unknown default:
            return
        }
    }

    private func reregister(service: SMAppService, label: String, displayName: String) throws {
        try unregister(service: service, label: label)
        try register(service: service, displayName: displayName)
    }

    private func restoreRegistration(service: SMAppService, label: String, displayName: String) throws {
        try validatePersistentAppLocation()
        try unregister(service: service, label: label)
        if service.status == .notRegistered {
            try service.register()
        }
        guard service.status == .enabled || service.status == .requiresApproval else {
            throw ValidationError("无法恢复 \(displayName) 的后台注册状态。")
        }
    }

    private var serviceDomain: String { "gui/\(getuid())" }

    func validatePersistentAppLocation() throws {
        let path = paths.appBundle.resolvingSymlinksInPath().path
        if path == "/Volumes" || path.hasPrefix("/Volumes/") {
            throw ValidationError("请先把 AgentDock 拖到“应用程序”文件夹，再启用后台服务。")
        }
        if LegacyDesktopRuntimeMigration.isPresent(paths: paths) {
            throw ValidationError("检测到旧版 AgentDock 后台结构，请先在主面板应用当前设置完成迁移。")
        }
    }

    private func isLoaded(label: String) -> Bool {
        (try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["print", "\(serviceDomain)/\(label)"]
        ).status) == 0
    }

    private func launchdProcessID(label: String) -> Int? {
        guard let result = try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["print", "\(serviceDomain)/\(label)"]
        ), result.status == 0 else { return nil }
        for rawLine in result.output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("pid = "),
                  let pid = Int(line.dropFirst("pid = ".count)),
                  pid > 0 else { continue }
            return pid
        }
        return nil
    }

    private func waitForStableLaunchdProcess(label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previousPID: Int?
        var stableChecks = 0
        while Date() < deadline {
            if let pid = launchdProcessID(label: label) {
                if pid == previousPID {
                    stableChecks += 1
                } else {
                    previousPID = pid
                    stableChecks = 1
                }
                if stableChecks >= 4 { return true }
            } else {
                previousPID = nil
                stableChecks = 0
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func waitUntilUnloaded(label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isLoaded(label: label) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !isLoaded(label: label)
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
