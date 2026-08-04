import Foundation
import ServiceManagement

final class MenuLoginAgentController {
    private let helperIdentifier = "com.uvwt.agentdock.login-helper"
    private let preferenceKey = "menuLoginEnabled"
    private let preferenceInitializedKey = "menuLoginPreferenceInitialized"
    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let paths: AppPaths

    init(defaults: UserDefaults = .standard, paths: AppPaths = AppPaths()) {
        self.defaults = defaults
        self.paths = paths
    }

    private var loginItem: SMAppService {
        SMAppService.loginItem(identifier: helperIdentifier)
    }

    func configureOnLaunch() throws {
        removeLegacyLaunchAgent()
        migrateLegacyMainAppLoginItem()
        if !defaults.bool(forKey: preferenceInitializedKey) {
            defaults.set(true, forKey: preferenceInitializedKey)
            defaults.set(true, forKey: preferenceKey)
        }
        if defaults.bool(forKey: preferenceKey) {
            try register()
        } else {
            try unregister()
        }
    }

    var isEnabled: Bool {
        loginItem.status == .enabled || loginItem.status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try register()
        } else {
            try unregister()
        }
        defaults.set(true, forKey: preferenceInitializedKey)
        defaults.set(enabled, forKey: preferenceKey)
    }

    func register() throws {
        removeLegacyLaunchAgent()
        migrateLegacyMainAppLoginItem()
        switch loginItem.status {
        case .enabled, .requiresApproval:
            return
        case .notFound:
            throw ValidationError("应用包缺少标准菜单栏登录项。")
        case .notRegistered:
            try loginItem.register()
        @unknown default:
            try loginItem.register()
        }
    }

    func unregister() throws {
        removeLegacyLaunchAgent()
        if loginItem.status == .enabled || loginItem.status == .requiresApproval {
            try loginItem.unregister()
        }
    }

    private func migrateLegacyMainAppLoginItem() {
        let legacy = SMAppService.mainApp
        if legacy.status == .enabled || legacy.status == .requiresApproval {
            try? legacy.unregister()
        }
    }

    private func removeLegacyLaunchAgent() {
        let domain = "gui/\(getuid())"
        _ = try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootout", "\(domain)/com.uvwt.agentdock.menu"]
        )
        if fileManager.fileExists(atPath: paths.menuLaunchAgent.path) {
            try? fileManager.removeItem(at: paths.menuLaunchAgent)
        }
    }
}
