import AppKit
import Foundation

final class SetupWindowController: NSWindowController {
    private let installer = InstallerRunner()
    private let onInstalled: () -> Void

    private let titleLabel = NSTextField(labelWithString: "安装 AgentDock")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let localButton = NSButton(radioButtonWithTitle: TunnelMode.local.title, target: nil, action: nil)
    private let quickButton = NSButton(radioButtonWithTitle: TunnelMode.quick.title, target: nil, action: nil)
    private let namedButton = NSButton(radioButtonWithTitle: TunnelMode.named.title, target: nil, action: nil)
    private let modeDescription = NSTextField(labelWithString: TunnelMode.local.detail)
    private let serverURLField = NSTextField(string: "")
    private let tokenField = NSSecureTextField(string: "")
    private let namedFields = NSStackView()
    private let installButton = NSButton(title: "安装并启动", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let resultStack = NSStackView()
    private let localResult = NSTextField(labelWithString: "")
    private let publicResult = NSTextField(labelWithString: "")
    private let tokenResult = NSTextField(labelWithString: "")
    private let oauthResult = NSTextField(labelWithString: "")
    private let revealSecretsButton = NSButton(title: "显示凭据", target: nil, action: nil)
    private var authTokenValue = ""
    private var oauthPasswordValue = ""
    private var secretsVisible = false

    init(onInstalled: @escaping () -> Void) {
        self.onInstalled = onInstalled
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentDock"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(status: ServiceStatus) {
        resetForPresentation(status: status)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureUI() {
        guard let contentView = window?.contentView else { return }

        titleLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor

        for button in [localButton, quickButton, namedButton] {
            button.target = self
            button.action = #selector(modeChanged(_:))
            button.setButtonType(.radio)
        }
        localButton.state = .on

        let modeStack = NSStackView(views: [localButton, quickButton, namedButton])
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 10

        modeDescription.textColor = .secondaryLabelColor
        modeDescription.lineBreakMode = .byWordWrapping

        let serverLabel = NSTextField(labelWithString: "公网地址")
        serverLabel.font = .systemFont(ofSize: 13, weight: .medium)
        serverURLField.placeholderString = "https://mini.example.com"
        let tokenLabel = NSTextField(labelWithString: "Cloudflare Tunnel Token")
        tokenLabel.font = .systemFont(ofSize: 13, weight: .medium)
        tokenField.placeholderString = "粘贴 Tunnel Token"

        namedFields.orientation = .vertical
        namedFields.alignment = .leading
        namedFields.spacing = 6
        namedFields.addArrangedSubview(serverLabel)
        namedFields.addArrangedSubview(serverURLField)
        namedFields.addArrangedSubview(tokenLabel)
        namedFields.addArrangedSubview(tokenField)
        namedFields.isHidden = true
        serverURLField.widthAnchor.constraint(equalToConstant: 500).isActive = true
        tokenField.widthAnchor.constraint(equalToConstant: 500).isActive = true

        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        installButton.target = self
        installButton.action = #selector(installPressed)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true

        resultStack.orientation = .vertical
        resultStack.alignment = .leading
        resultStack.spacing = 8
        resultStack.isHidden = true
        resultStack.addArrangedSubview(resultRow(title: "本地 MCP", valueField: localResult, action: #selector(copyLocalResult)))
        resultStack.addArrangedSubview(resultRow(title: "公网 MCP", valueField: publicResult, action: #selector(copyPublicResult)))
        resultStack.addArrangedSubview(resultRow(title: "Bearer Token", valueField: tokenResult, action: #selector(copyTokenResult)))
        resultStack.addArrangedSubview(resultRow(title: "OAuth 登录密码", valueField: oauthResult, action: #selector(copyOAuthResult)))
        revealSecretsButton.bezelStyle = .inline
        revealSecretsButton.target = self
        revealSecretsButton.action = #selector(toggleSecrets)
        resultStack.addArrangedSubview(revealSecretsButton)

        let actionRow = NSStackView(views: [progress, installButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10

        let root = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            separator(),
            NSTextField(labelWithString: "连接方式"),
            modeStack,
            modeDescription,
            namedFields,
            separator(),
            actionRow,
            statusLabel,
            resultStack,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -28),
            subtitleLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            modeDescription.widthAnchor.constraint(equalTo: root.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return box
    }

    private func resultRow(title: String, valueField: NSTextField, action: Selector) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        valueField.lineBreakMode = .byTruncatingMiddle
        valueField.isSelectable = true
        valueField.widthAnchor.constraint(equalToConstant: 350).isActive = true
        let copyButton = NSButton(title: "复制", target: self, action: action)
        copyButton.bezelStyle = .inline
        let row = NSStackView(views: [label, valueField, copyButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        return row
    }

    private func resetForPresentation(status: ServiceStatus) {
        statusLabel.isHidden = true
        resultStack.isHidden = true
        installButton.isEnabled = true
        authTokenValue = ""
        oauthPasswordValue = ""
        secretsVisible = false
        revealSecretsButton.title = "显示凭据"

        if status.installed {
            titleLabel.stringValue = "AgentDock"
            if status.healthy {
                subtitleLabel.stringValue = "AgentDock 正在运行，版本 \(status.version ?? "未知")。可以在这里修改连接方式并重新应用配置。"
            } else if status.loaded {
                subtitleLabel.stringValue = "AgentDock 已安装，但当前服务状态异常。可以重新应用配置或从菜单栏重启服务。"
            } else {
                subtitleLabel.stringValue = "AgentDock 已安装但已停止。可以重新应用配置，或从菜单栏启动服务。"
            }
            installButton.title = "应用配置并重启"
            selectCurrentMode(configuration: status.configuration)
        } else {
            titleLabel.stringValue = "安装 AgentDock"
            subtitleLabel.stringValue = "选择连接方式后，AgentDock 会自动安装后台服务并在登录后持续运行。无需打开终端，也不需要管理员权限。"
            installButton.title = "安装并启动"
            select(mode: .local)
        }
    }

    private func selectCurrentMode(configuration: RuntimeConfiguration?) {
        guard let publicURL = configuration?.publicURL, !publicURL.isEmpty else {
            select(mode: .local)
            return
        }
        if publicURL.contains(".trycloudflare.com") {
            select(mode: .quick)
        } else {
            serverURLField.stringValue = publicURL
            select(mode: .named)
        }
    }

    private func select(mode: TunnelMode) {
        localButton.state = mode == .local ? .on : .off
        quickButton.state = mode == .quick ? .on : .off
        namedButton.state = mode == .named ? .on : .off
        modeDescription.stringValue = mode.detail
        namedFields.isHidden = mode != .named
    }

    @objc private func modeChanged(_ sender: NSButton) {
        for button in [localButton, quickButton, namedButton] where button !== sender {
            button.state = .off
        }
        sender.state = .on
        let mode = selectedMode
        modeDescription.stringValue = mode.detail
        namedFields.isHidden = mode != .named
    }

    @objc private func installPressed() {
        let request = InstallRequest(
            mode: selectedMode,
            serverURL: serverURLField.stringValue,
            tunnelToken: tokenField.stringValue
        )
        do {
            _ = try request.validatedServerURL()
            _ = try request.validatedTunnelToken()
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return
        }

        setInstalling(true)
        Task {
            do {
                let result = try await installer.run(request: request)
                await MainActor.run {
                    self.showResult(result)
                    self.onInstalled()
                }
            } catch {
                await MainActor.run {
                    self.setInstalling(false)
                    self.showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private var selectedMode: TunnelMode {
        if namedButton.state == .on { return .named }
        if quickButton.state == .on { return .quick }
        return .local
    }

    private func setInstalling(_ installing: Bool) {
        installButton.isEnabled = !installing
        localButton.isEnabled = !installing
        quickButton.isEnabled = !installing
        namedButton.isEnabled = !installing
        serverURLField.isEnabled = !installing
        tokenField.isEnabled = !installing
        if installing {
            progress.startAnimation(nil)
            showStatus("正在下载、校验并启动 AgentDock…", isError: false)
        } else {
            progress.stopAnimation(nil)
        }
    }

    private func showResult(_ result: InstallResult) {
        setInstalling(false)
        installButton.title = "重新配置"
        localResult.stringValue = result.localMCPURL
        publicResult.stringValue = result.publicMCPURL.isEmpty ? "未启用" : result.publicMCPURL
        authTokenValue = result.authToken
        oauthPasswordValue = result.oauthPassword
        secretsVisible = false
        revealSecretsButton.title = "显示凭据"
        refreshSecretFields()
        tokenField.stringValue = ""
        resultStack.isHidden = false
        showStatus("AgentDock \(result.version) 已安装并正常运行。", isError: false)
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = false
    }

    @objc private func copyLocalResult() { copy(localResult.stringValue) }
    @objc private func copyPublicResult() { copy(publicResult.stringValue == "未启用" ? "" : publicResult.stringValue) }
    @objc private func copyTokenResult() { copy(authTokenValue) }
    @objc private func copyOAuthResult() { copy(oauthPasswordValue) }

    @objc private func toggleSecrets() {
        secretsVisible.toggle()
        revealSecretsButton.title = secretsVisible ? "隐藏凭据" : "显示凭据"
        refreshSecretFields()
    }

    private func refreshSecretFields() {
        tokenResult.stringValue = displayedSecret(authTokenValue)
        oauthResult.stringValue = oauthPasswordValue.isEmpty ? "未启用" : displayedSecret(oauthPasswordValue)
    }

    private func displayedSecret(_ value: String) -> String {
        guard !value.isEmpty else { return "未生成" }
        return secretsVisible ? value : String(repeating: "•", count: min(max(value.count, 8), 24))
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
