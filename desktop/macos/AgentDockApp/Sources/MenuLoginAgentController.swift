import Foundation
import ServiceManagement

final class MenuLoginAgentController {
    private let helperIdentifier = "com.uvwt.agentdock.login-helper"
    private let preferenceKey = "menuLoginEnabled"
    private let preferenceInitializedKey = "menuLoginPreferenceInitialized"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var loginItem: SMAppService {
        SMAppService.loginItem(identifier: helperIdentifier)
    }

    func configureOnLaunch() throws {
        guard !isRunningFromTransientVolume else { return }
        let obsoleteMainApp = SMAppService.mainApp
        if obsoleteMainApp.status == .enabled || obsoleteMainApp.status == .requiresApproval {
            try? obsoleteMainApp.unregister()
        }
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
        guard !isRunningFromTransientVolume else {
            throw ValidationError("请先把 AgentDock 拖到“应用程序”文件夹，再启用登录启动。")
        }
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
        if loginItem.status == .enabled || loginItem.status == .requiresApproval {
            try loginItem.unregister()
        }
    }

    private var isRunningFromTransientVolume: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path == "/Volumes" || path.hasPrefix("/Volumes/")
    }
}
