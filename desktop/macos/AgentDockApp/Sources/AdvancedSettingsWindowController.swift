import AppKit
import Foundation

@MainActor
final class AdvancedSettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let service: ServiceController
    private let configurationController: ServiceConfigurationController
    private let browserSupport = BrowserSupportController()
    private let menuLoginAgent: MenuLoginAgentController
    private let onChanged: () -> Void

    private let serviceAutostart = NSButton(checkboxWithTitle: "登录后自动启动 AgentDock 服务", target: nil, action: nil)
    private let menuAutostart = NSButton(checkboxWithTitle: "登录后显示 AgentDock 菜单栏", target: nil, action: nil)
    private let portField = NSTextField(string: "8765")
    private let logLevel = NSPopUpButton(frame: .zero, pullsDown: false)
    private let browserEnabled = NSButton(checkboxWithTitle: "启用浏览器工具", target: nil, action: nil)
    private let browserStatus = NSTextField(wrappingLabelWithString: "")
    private let nexusEndpoint = NSTextField(string: "")
    private let nexusToken = NSSecureTextField(string: "")
    private let nexusTokenStatus = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "应用并重启", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    private var currentConfiguration: ServiceConfiguration?
    private var initialServiceAutostart = true
    private var initialMenuAutostart = true
    private var initialPort = 8765
    private var initialLogLevel = "info"
    private var initialNexusEndpoint = ""
    private var initialBrowserEnabled = false
    private var installedRunnerDir = ""
    private var installedNodePath = ""
    private var browserSupportInstalledThisSession = false
    private var isBusy = false

    init(
        service: ServiceController,
        menuLoginAgent: MenuLoginAgentController,
        onChanged: @escaping () -> Void
    ) {
        self.service = service
        self.configurationController = ServiceConfigurationController(service: service)
        self.menuLoginAgent = menuLoginAgent
        self.onChanged = onChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 590, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentDock 高级设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        configureUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(status: ServiceStatus) {
        guard let configuration = status.configuration else { return }
        currentConfiguration = configuration
        browserSupportInstalledThisSession = false
        installedRunnerDir = configuration.browserRunnerDir.isEmpty
            ? service.paths.browserRunner.path
            : configuration.browserRunnerDir
        installedNodePath = configuration.browserNodePath.isEmpty
            ? existingNodePath()
            : configuration.browserNodePath
        initialServiceAutostart = status.autostartEnabled
        initialMenuAutostart = menuLoginAgent.isEnabled
        initialPort = configuration.port
        initialLogLevel = configuration.logLevel
        initialNexusEndpoint = configuration.nexusEndpoint
        initialBrowserEnabled = configuration.browserEnabled

        serviceAutostart.state = status.autostartEnabled ? .on : .off
        menuAutostart.state = initialMenuAutostart ? .on : .off
        portField.integerValue = initialPort
        logLevel.selectItem(withTitle: initialLogLevel)
        browserEnabled.state = initialBrowserEnabled ? .on : .off
        nexusEndpoint.stringValue = initialNexusEndpoint
        nexusToken.stringValue = ""
        nexusToken.placeholderString = configuration.nexusTokenConfigured
            ? "留空表示保留现有 Token"
            : "可选 Nexus Token"
        nexusTokenStatus.stringValue = configuration.nexusTokenConfigured ? "当前已配置 Token" : "当前未配置 Token"
        refreshBrowserStatus()
        showStatus("", isError: false)
        setBusy(false)
        refreshApplyState()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if initialBrowserEnabled && !browserFilesInstalled {
            beginBrowserInstall()
        }
    }

    private func configureUI() {
        guard let contentView = window?.contentView else { return }

        serviceAutostart.target = self
        serviceAutostart.action = #selector(markChanged)
        menuAutostart.target = self
        menuAutostart.action = #selector(markChanged)

        portField.alignment = .right
        portField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        portField.target = self
        portField.action = #selector(markChanged)
        portField.delegate = self

        logLevel.addItems(withTitles: ["debug", "info", "warn", "error"])
        logLevel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        logLevel.target = self
        logLevel.action = #selector(markChanged)

        browserEnabled.target = self
        browserEnabled.action = #selector(browserToggled)
        browserStatus.textColor = .secondaryLabelColor
        browserStatus.font = .systemFont(ofSize: 12)

        nexusEndpoint.placeholderString = "https://nexus.example.com"
        nexusEndpoint.target = self
        nexusEndpoint.action = #selector(markChanged)
        nexusEndpoint.delegate = self
        nexusToken.target = self
        nexusToken.action = #selector(markChanged)
        nexusToken.delegate = self
        nexusTokenStatus.textColor = .secondaryLabelColor
        nexusTokenStatus.font = .systemFont(ofSize: 12)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true

        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyPressed)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        let openLogs = NSButton(title: "打开日志", target: self, action: #selector(openLogsPressed))
        openLogs.bezelStyle = .inline
        let openConfig = NSButton(title: "打开配置目录", target: self, action: #selector(openConfigurationPressed))
        openConfig.bezelStyle = .inline

        let startupStack = NSStackView(views: [serviceAutostart, menuAutostart])
        startupStack.orientation = .vertical
        startupStack.alignment = .leading
        startupStack.spacing = 8

        let serviceForm = NSStackView(views: [
            formRow(title: "服务端口", control: portField),
            formRow(title: "日志级别", control: logLevel),
        ])
        serviceForm.orientation = .vertical
        serviceForm.alignment = .leading
        serviceForm.spacing = 10

        let browserStack = NSStackView(views: [browserEnabled, browserStatus])
        browserStack.orientation = .vertical
        browserStack.alignment = .leading
        browserStack.spacing = 5
        browserStatus.widthAnchor.constraint(equalToConstant: 500).isActive = true

        let nexusStack = NSStackView(views: [
            formRow(title: "Endpoint", control: nexusEndpoint),
            formRow(title: "Token", control: nexusToken),
            nexusTokenStatus,
        ])
        nexusStack.orientation = .vertical
        nexusStack.alignment = .leading
        nexusStack.spacing = 8
        nexusEndpoint.widthAnchor.constraint(equalToConstant: 390).isActive = true
        nexusToken.widthAnchor.constraint(equalToConstant: 390).isActive = true

        let utilityRow = NSStackView(views: [openLogs, openConfig])
        utilityRow.orientation = .horizontal
        utilityRow.spacing = 14

        let actionRow = NSStackView(views: [progress, statusLabel, NSView(), cancelButton, applyButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [
            sectionTitle("启动"),
            startupStack,
            separator(),
            sectionTitle("服务"),
            serviceForm,
            separator(),
            sectionTitle("浏览器工具"),
            browserStack,
            separator(),
            sectionTitle("Nexus"),
            nexusStack,
            separator(),
            utilityRow,
            actionRow,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -22),
            actionRow.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 534).isActive = true
        return box
    }

    private func formRow(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    @objc private func markChanged() {
        refreshApplyState()
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshApplyState()
    }

    @objc private func browserToggled() {
        guard browserEnabled.state == .on else {
            refreshBrowserStatus()
            refreshApplyState()
            return
        }
        if browserFilesInstalled {
            refreshBrowserStatus()
            refreshApplyState()
            return
        }
        beginBrowserInstall()
    }

    private func beginBrowserInstall() {
        setBusy(true)
        browserStatus.stringValue = "正在自动安装 Node.js 运行时和 browser-runner…"
        Task {
            do {
                let result = try await browserSupport.install()
                installedRunnerDir = result.runnerDir
                installedNodePath = result.nodePath
                browserSupportInstalledThisSession = true
                browserStatus.stringValue = "已安装 · Node \(result.nodeVersion) · 使用本机 Chrome/Chromium"
                setBusy(false)
                refreshApplyState()
            } catch {
                browserEnabled.state = .off
                setBusy(false)
                showStatus(error.localizedDescription, isError: true)
                refreshBrowserStatus()
                refreshApplyState()
            }
        }
    }

    @objc private func applyPressed() {
        guard let configuration = currentConfiguration else { return }
        let tokenReplacement = nexusToken.stringValue.isEmpty ? nil : nexusToken.stringValue
        let settings = EditableServiceSettings(
            port: portField.integerValue,
            logLevel: logLevel.titleOfSelectedItem ?? "info",
            nexusEndpoint: nexusEndpoint.stringValue,
            nexusTokenReplacement: tokenReplacement,
            browserEnabled: browserEnabled.state == .on,
            browserRunnerDir: installedRunnerDir.isEmpty ? configuration.browserRunnerDir : installedRunnerDir,
            browserNodePath: installedNodePath.isEmpty ? configuration.browserNodePath : installedNodePath
        )
        setBusy(true)
        showStatus("正在保存配置并验证 AgentDock…", isError: false)
        Task {
            do {
                let validatedSettings = try settings.validated()
                try await configurationController.apply(validatedSettings)
                let serviceAutostartValue = serviceAutostart.state == .on
                if serviceAutostartValue != initialServiceAutostart {
                    try await service.setAutostart(enabled: serviceAutostartValue)
                }
                let menuAutostartValue = menuAutostart.state == .on
                if menuAutostartValue != initialMenuAutostart {
                    try menuLoginAgent.setEnabled(menuAutostartValue)
                }
                initialServiceAutostart = serviceAutostartValue
                initialMenuAutostart = menuAutostartValue
                initialPort = validatedSettings.port
                initialLogLevel = validatedSettings.logLevel
                initialNexusEndpoint = validatedSettings.nexusEndpoint
                initialBrowserEnabled = validatedSettings.browserEnabled
                browserSupportInstalledThisSession = false
                portField.integerValue = initialPort
                logLevel.selectItem(withTitle: initialLogLevel)
                nexusEndpoint.stringValue = initialNexusEndpoint
                nexusToken.stringValue = ""
                showStatus("设置已保存。", isError: false)
                setBusy(false)
                refreshApplyState()
                onChanged()
            } catch {
                setBusy(false)
                showStatus(error.localizedDescription, isError: true)
            }
        }
    }

    @objc private func cancelPressed() { close() }
    @objc private func openLogsPressed() { service.openLogs() }
    @objc private func openConfigurationPressed() { service.openConfiguration() }

    private var browserFilesInstalled: Bool {
        guard !installedRunnerDir.isEmpty, !installedNodePath.isEmpty else { return false }
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: installedRunnerDir + "/browser-runner.js")
            && fileManager.fileExists(atPath: installedRunnerDir + "/node_modules/playwright-core/package.json")
            && fileManager.isExecutableFile(atPath: installedNodePath)
    }

    private func refreshBrowserStatus() {
        if browserFilesInstalled {
            browserStatus.stringValue = browserEnabled.state == .on
                ? "已安装并启用 · 使用本机 Chrome/Chromium"
                : "已安装但未启用；再次勾选无需重新下载"
        } else {
            browserStatus.stringValue = browserEnabled.state == .on
                ? "等待安装浏览器支持"
                : "首次勾选后自动下载并安装所需运行环境"
        }
    }

    private func existingNodePath() -> String {
        var candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/node" }
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if let resolved = try? URL(fileURLWithPath: candidate).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]),
               resolved.isRegularFile == true {
                return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            }
        }
        return ""
    }

    private func refreshApplyState() {
        guard !isBusy, currentConfiguration != nil else {
            applyButton.isEnabled = false
            return
        }
        let pathsChanged = browserSupportInstalledThisSession
            && (browserEnabled.state == .on || initialBrowserEnabled)
        let changed = (serviceAutostart.state == .on) != initialServiceAutostart
            || (menuAutostart.state == .on) != initialMenuAutostart
            || portField.integerValue != initialPort
            || (logLevel.titleOfSelectedItem ?? "info") != initialLogLevel
            || nexusEndpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != initialNexusEndpoint
            || !nexusToken.stringValue.isEmpty
            || (browserEnabled.state == .on) != initialBrowserEnabled
            || pathsChanged
        applyButton.isEnabled = changed
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        for control in [serviceAutostart, menuAutostart, portField, logLevel, browserEnabled, nexusEndpoint, nexusToken] {
            control.isEnabled = !busy
        }
        cancelButton.isEnabled = !busy
        if busy {
            applyButton.isEnabled = false
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
            refreshApplyState()
        }
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = message.isEmpty
    }
}
