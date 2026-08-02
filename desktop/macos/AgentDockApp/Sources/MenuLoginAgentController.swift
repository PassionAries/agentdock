import Foundation
import ServiceManagement

final class MenuLoginAgentController {
    private let label = "com.uvwt.agentdock.menu"
    private let preferenceKey = "menuLoginEnabled"
    private let preferenceInitializedKey = "menuLoginPreferenceInitialized"
    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let paths: AppPaths

    init(defaults: UserDefaults = .standard, paths: AppPaths = AppPaths()) {
        self.defaults = defaults
        self.paths = paths
    }

    func configureOnLaunch() throws {
        migrateLegacyMainAppLoginItem()
        if !defaults.bool(forKey: preferenceInitializedKey) {
            defaults.set(true, forKey: preferenceInitializedKey)
            defaults.set(true, forKey: preferenceKey)
        }
        if isEnabled {
            try register()
        } else {
            try unregister()
        }
    }

    var isEnabled: Bool {
        if defaults.bool(forKey: preferenceInitializedKey) {
            return defaults.bool(forKey: preferenceKey)
        }
        return fileManager.fileExists(atPath: paths.menuLaunchAgent.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        let previous = isEnabled
        guard previous != enabled else { return }
        if enabled {
            try register()
        } else {
            try unregister()
        }
        defaults.set(true, forKey: preferenceInitializedKey)
        defaults.set(enabled, forKey: preferenceKey)
    }

    func register() throws {
        migrateLegacyMainAppLoginItem()
        guard let helperPath = Bundle.main.path(forAuxiliaryExecutable: "AgentDockLoginHelper"),
              fileManager.isExecutableFile(atPath: helperPath) else {
            throw ValidationError("应用包缺少菜单栏登录代理。")
        }

        let launchAgents = paths.menuLaunchAgent.deletingLastPathComponent()
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        if let values = try? paths.menuLaunchAgent.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw ValidationError("菜单栏登录项不能写入符号链接：\(paths.menuLaunchAgent.path)")
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperPath],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let currentData = try? Data(contentsOf: paths.menuLaunchAgent)
        let changed = currentData != data
        let domain = "gui/\(getuid())"

        if changed {
            if isLoaded(domain: domain) {
                _ = try? runProcess(executable: "/bin/launchctl", arguments: ["bootout", "\(domain)/\(label)"])
            }
            try data.write(to: paths.menuLaunchAgent, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.menuLaunchAgent.path)
        }

        guard changed || !isLoaded(domain: domain) else { return }
        let result = try runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", domain, paths.menuLaunchAgent.path]
        )
        guard result.status == 0 else {
            throw ValidationError(commandError(result.output, fallback: "菜单栏登录项注册失败。"))
        }
    }

    func unregister() throws {
        migrateLegacyMainAppLoginItem()
        let domain = "gui/\(getuid())"
        if isLoaded(domain: domain) {
            let result = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["bootout", "\(domain)/\(label)"]
            )
            guard result.status == 0 else {
                throw ValidationError(commandError(result.output, fallback: "菜单栏登录项停止失败。"))
            }
        }
        if fileManager.fileExists(atPath: paths.menuLaunchAgent.path) {
            try fileManager.removeItem(at: paths.menuLaunchAgent)
        }
    }

    private func migrateLegacyMainAppLoginItem() {
        let legacy = SMAppService.mainApp
        if legacy.status == .enabled || legacy.status == .requiresApproval {
            try? legacy.unregister()
        }
    }

    private func isLoaded(domain: String) -> Bool {
        (try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["print", "\(domain)/\(label)"]
        ).status) == 0
    }

    private func commandError(_ output: String, fallback: String) -> String {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }
}
