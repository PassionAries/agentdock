import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service = ServiceController()
    private let menuLoginAgent = MenuLoginAgentController()
    private let launchedInBackground = CommandLine.arguments.contains("--background")
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var currentStatus = ServiceStatus.missing
    private var timer: Timer?
    private lazy var setupWindow = SetupWindowController { [weak self] in
        self?.refreshStatus()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        registerLoginItemIfNeeded()
        refreshStatus(showWindow: !launchedInBackground)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func registerLoginItemIfNeeded() {
        do {
            try menuLoginAgent.register()
        } catch {
            // 登录项失败不影响核心 LaunchAgent；用户仍可手动打开菜单栏 App。
            NSLog("AgentDock 菜单栏登录项注册失败：%@", error.localizedDescription)
        }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "AgentDock")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func refreshStatus(showWindow: Bool = false) {
        Task {
            let status = await service.status()
            await MainActor.run {
                self.currentStatus = status
                self.rebuildMenu()
                if showWindow {
                    self.setupWindow.present(status: status)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setupWindow.present(status: currentStatus)
        return true
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let statusText: String
        if !currentStatus.installed {
            statusText = "未安装"
        } else if currentStatus.healthy {
            statusText = "运行正常 · \(currentStatus.version ?? "未知版本")"
        } else if currentStatus.loaded {
            statusText = "服务异常"
        } else {
            statusText = "已停止"
        }
        let statusMenuItem = NSMenuItem(title: "AgentDock：\(statusText)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        menu.addItem(item("安装或配置…", #selector(showSetup)))
        if currentStatus.installed {
            let local = item("复制本地 MCP 地址", #selector(copyLocalMCP))
            local.isEnabled = currentStatus.configuration?.localMCPURL != nil
            menu.addItem(local)
            let publicItem = item("复制公网 MCP 地址", #selector(copyPublicMCP))
            publicItem.isEnabled = currentStatus.configuration?.publicMCPURL != nil
            menu.addItem(publicItem)
            menu.addItem(.separator())

            if currentStatus.loaded {
                menu.addItem(item("停止 AgentDock", #selector(stopService)))
                menu.addItem(item("重启 AgentDock", #selector(restartService)))
            } else {
                menu.addItem(item("启动 AgentDock", #selector(startService)))
            }
            menu.addItem(item("检查更新…", #selector(updateService)))
            menu.addItem(.separator())
            menu.addItem(item("打开日志目录", #selector(openLogs)))
            menu.addItem(item("打开配置目录", #selector(openConfiguration)))
        }
        menu.addItem(item("打开使用文档", #selector(openDocumentation)))
        menu.addItem(.separator())
        menu.addItem(item("退出菜单栏", #selector(quit)))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func showSetup() { setupWindow.present(status: currentStatus) }
    @objc private func copyLocalMCP() { copy(currentStatus.configuration?.localMCPURL?.absoluteString) }
    @objc private func copyPublicMCP() { copy(currentStatus.configuration?.publicMCPURL?.absoluteString) }
    @objc private func openLogs() { service.openLogs() }
    @objc private func openConfiguration() { service.openConfiguration() }

    @objc private func openDocumentation() {
        if let url = URL(string: "https://github.com/uvwt/agentdock#readme") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func startService() { performServiceAction("启动") { try await self.service.start() } }
    @objc private func stopService() { performServiceAction("停止") { try await self.service.stop() } }
    @objc private func restartService() { performServiceAction("重启") { try await self.service.restart() } }

    @objc private func updateService() {
        Task {
            do {
                let output = try await service.update()
                await MainActor.run {
                    self.presentAlert(title: "AgentDock 更新完成", message: output.isEmpty ? "更新已完成。" : output)
                    self.refreshStatus()
                }
            } catch {
                await MainActor.run { self.presentAlert(title: "更新失败", message: error.localizedDescription) }
            }
        }
    }

    private func performServiceAction(_ action: String, operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
                try? await Task.sleep(nanoseconds: 800_000_000)
                await MainActor.run { self.refreshStatus() }
            } catch {
                await MainActor.run { self.presentAlert(title: "\(action)失败", message: error.localizedDescription) }
            }
        }
    }

    private func copy(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = title.contains("失败") ? .warning : .informational
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
