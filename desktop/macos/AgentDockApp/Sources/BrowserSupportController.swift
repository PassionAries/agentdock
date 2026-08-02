import Foundation

struct BrowserSupportInstallResult: Decodable {
    let schemaVersion: Int
    let ok: Bool
    let runnerDir: String
    let nodePath: String
    let nodeVersion: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ok
        case runnerDir = "runner_dir"
        case nodePath = "node_path"
        case nodeVersion = "node_version"
    }
}

final class BrowserSupportController {
    func isInstalled(configuration: ServiceConfiguration?) -> Bool {
        guard let configuration,
              !configuration.browserRunnerDir.isEmpty,
              !configuration.browserNodePath.isEmpty else { return false }
        return Self.validateInstalled(
            runnerDir: configuration.browserRunnerDir,
            nodePath: configuration.browserNodePath
        )
    }

    func install() async throws -> BrowserSupportInstallResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.installSynchronously())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func installSynchronously() throws -> BrowserSupportInstallResult {
        guard let scriptPath = Bundle.main.path(forResource: "install-browser-runner-macos", ofType: "sh"),
              let runnerPath = Bundle.main.resourceURL?.appendingPathComponent("browser-runner", isDirectory: true).path else {
            throw ValidationError("应用包缺少浏览器支持资源。")
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDockBrowserInstaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryDirectory.path)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let resultURL = temporaryDirectory.appendingPathComponent("result.json")
        let execution = try runProcess(
            executable: "/bin/zsh",
            arguments: [
                scriptPath,
                "--source-dir", runnerPath,
                "--result-file", resultURL.path,
            ]
        )
        guard execution.status == 0 else {
            throw ValidationError(Self.extractInstallerError(execution.output))
        }
        let data = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(BrowserSupportInstallResult.self, from: data)
        guard result.schemaVersion == 1, result.ok else {
            throw ValidationError("浏览器支持安装结果格式不受支持。")
        }
        guard validateInstalled(runnerDir: result.runnerDir, nodePath: result.nodePath) else {
            throw ValidationError("浏览器支持安装完成，但文件验证失败。")
        }
        return result
    }

    private static func validateInstalled(runnerDir: String, nodePath: String) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: runnerDir, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.fileExists(atPath: runnerDir + "/browser-runner.js"),
              fileManager.fileExists(atPath: runnerDir + "/node_modules/playwright-core/package.json"),
              fileManager.isExecutableFile(atPath: nodePath) else { return false }
        return true
    }

    private static func extractInstallerError(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        if let errorLine = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return String(errorLine.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? "浏览器支持安装失败。"
    }
}
