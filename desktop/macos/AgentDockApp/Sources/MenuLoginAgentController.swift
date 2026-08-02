import Foundation
import ServiceManagement

final class MenuLoginAgentController {
    private let label = "com.uvwt.agentdock.menu"
    private let fileManager = FileManager.default

    func register() throws {
        migrateLegacyMainAppLoginItem()

        guard let helperPath = Bundle.main.path(forAuxiliaryExecutable: "AgentDockLoginHelper"),
              fileManager.isExecutableFile(atPath: helperPath) else {
            throw ValidationError("应用包缺少菜单栏登录代理。")
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = launchAgents.appendingPathComponent("\(label).plist")
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)

        if let attributes = try? fileManager.attributesOfItem(atPath: plistURL.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ValidationError("菜单栏登录项不能写入符号链接：\(plistURL.path)")
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperPath],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let currentData = try? Data(contentsOf: plistURL)
        let changed = currentData != data

        if changed {
            let domain = "gui/\(getuid())"
            if isLoaded(domain: domain) {
                _ = try? runProcess(
                    executable: "/bin/launchctl",
                    arguments: ["bootout", "\(domain)/\(label)"]
                )
            }
            try data.write(to: plistURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
        }

        let domain = "gui/\(getuid())"
        guard changed || !isLoaded(domain: domain) else { return }
        let result = try runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", domain, plistURL.path]
        )
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ValidationError(message.isEmpty ? "菜单栏登录项注册失败。" : message)
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
}
