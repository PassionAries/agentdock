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
    let configuration: RuntimeConfiguration?

    static let missing = ServiceStatus(installed: false, loaded: false, healthy: false, version: nil, configuration: nil)
}

final class ServiceController {
    private let paths = AppPaths()
    private let label = "com.uvwt.agentdock"

    func status() async -> ServiceStatus {
        let fileManager = FileManager.default
        let installed = fileManager.isExecutableFile(atPath: paths.binary.path)
            && fileManager.fileExists(atPath: paths.environment.path)
            && fileManager.fileExists(atPath: paths.launchAgent.path)
        guard installed else { return .missing }

        let loaded = isLoaded()
        let configuration = RuntimeConfiguration.load(from: paths.environment)
        guard loaded, let healthURL = configuration?.healthURL else {
            return ServiceStatus(installed: true, loaded: loaded, healthy: false, version: nil, configuration: configuration)
        }

        do {
            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 2.5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return ServiceStatus(installed: true, loaded: true, healthy: false, version: nil, configuration: configuration)
            }
            let payload = try JSONDecoder().decode(HealthPayload.self, from: data)
            return ServiceStatus(installed: true, loaded: true, healthy: payload.ok, version: payload.version, configuration: configuration)
        } catch {
            return ServiceStatus(installed: true, loaded: true, healthy: false, version: nil, configuration: configuration)
        }
    }

    func start() async throws {
        try await runInBackground {
            if !self.isLoaded() {
                let result = try runProcess(
                    executable: "/bin/launchctl",
                    arguments: ["bootstrap", "gui/\(getuid())", self.paths.launchAgent.path]
                )
                guard result.status == 0 else { throw ValidationError(self.commandError(result.output, action: "启动")) }
            }
            let result = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "gui/\(getuid())/\(self.label)"]
            )
            guard result.status == 0 else { throw ValidationError(self.commandError(result.output, action: "启动")) }
        }
    }

    func stop() async throws {
        try await runInBackground {
            guard self.isLoaded() else { return }
            let result = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["bootout", "gui/\(getuid())/\(self.label)"]
            )
            guard result.status == 0 else { throw ValidationError(self.commandError(result.output, action: "停止")) }
        }
    }

    func restart() async throws {
        try await runInBackground {
            let result = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "-k", "gui/\(getuid())/\(self.label)"]
            )
            guard result.status == 0 else { throw ValidationError(self.commandError(result.output, action: "重启")) }
        }
    }

    func update() async throws -> String {
        try await runInBackground {
            let result = try runProcess(executable: self.paths.binary.path, arguments: ["update"])
            guard result.status == 0 else { throw ValidationError(self.commandError(result.output, action: "更新")) }
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

    private func isLoaded() -> Bool {
        (try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/\(label)"]
        ).status) == 0
    }

    private func commandError(_ output: String, action: String) -> String {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "AgentDock \(action)失败。" : message
    }

    private func runInBackground<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
