#ifndef AppVersion
#define AppVersion "0.0.0"
#endif

#define AppIdValue "{D6788C7A-4104-48D4-B5C3-F4858B5606EA}"

#ifndef OutputDir
#define OutputDir "..\..\dist"
#endif

#ifndef OfflinePayloadDir
#define OfflinePayloadDir "..\..\dist\windows-offline-payload"
#endif

#ifdef WindowsARM64
#define PayloadArchitecture "arm64"
#define SetupBaseFilename "AgentDockSetup-arm64"
#else
#define PayloadArchitecture "amd64"
#define SetupBaseFilename "AgentDockSetup-amd64"
#endif

[Setup]
AppId={{D6788C7A-4104-48D4-B5C3-F4858B5606EA}
AppName=AgentDock
AppVersion={#AppVersion}
AppPublisher=AgentDock
AppPublisherURL=https://github.com/uvwt/agentdock
AppSupportURL=https://github.com/uvwt/agentdock/issues
AppUpdatesURL=https://github.com/uvwt/agentdock/releases
DefaultDirName={localappdata}\AgentDock
DefaultGroupName=AgentDock
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename={#SetupBaseFilename}
SetupIconFile=assets\agentdock.ico
UninstallDisplayIcon={app}\installer\agentdock.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UsePreviousAppDir=yes
UsePreviousLanguage=no
LanguageDetectionMethod=uilanguage
ShowLanguageDialog=no
#ifdef WindowsARM64
ArchitecturesAllowed=arm64
#else
ArchitecturesAllowed=x64
#endif
#ifdef SignedBuild
SignTool=agentdock-sign
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Default.isl, languages\ChineseSimplified.isl"


[CustomMessages]
english.DocsShortcut=AgentDock documentation
english.UninstallShortcut=Uninstall AgentDock
english.StartupPageCaption=Startup
english.StartupPageDescription=Choose how AgentDock starts with Windows
english.StartupPageSubCaption=Keep login startup enabled for normal use. AgentDock always runs with the current user's permissions.
english.StartupOption=Start AgentDock and the tray after signing in
english.ConnectionPageCaption=Connection
english.ConnectionPageDescription=Choose who can reach AgentDock
english.ConnectionPageSubCaption=Local-only access is the default. Public access is enabled only when you select it explicitly.
english.LocalMode=Local access only (recommended)
english.QuickMode=Create a temporary public URL
english.NamedMode=Use my Cloudflare domain
english.FixedPageCaption=Fixed public URL
english.FixedPageDescription=Enter the Cloudflare Tunnel settings
english.FixedPageSubCaption=Enter an HTTPS origin such as https://agent.example.com. The Tunnel Token never appears in process arguments.
english.ServerURLLabel=HTTPS public URL:
english.TunnelTokenLabel=Cloudflare Tunnel Token:
english.CopyLocal=Copy local MCP URL
english.CopyPublic=Copy public MCP URL
english.CopyBearer=Copy Bearer Token
english.CopyOAuth=Copy OAuth password
english.InvalidServerURL=The fixed public URL must start with https:// and must not contain quotes.
english.TokenRequired=Enter the Cloudflare Tunnel Token.
english.TokenFileFailed=Could not create the temporary Tunnel Token file.
english.InstallerStartFailed=Could not start the AgentDock installer.
english.InstallerExitCode=Installer exit code:
english.InstallFailed=AgentDock installation failed:
english.Health=Status:
english.LocalMCP=Local MCP URL:
english.PublicMCP=Public MCP URL:
english.BearerToken=Bearer Token:
english.OAuthPassword=OAuth login password:
english.PurgeStateQuestion=Also delete tasks, Skills, configuration, and the default working directory? Choose No to keep user data.
english.UninstallScriptMissing=The AgentDock uninstall script is missing.
english.UninstallScriptFailed=The AgentDock cleanup script failed with exit code:
english.UpgradeWelcome=AgentDock is already installed
english.UpgradeExistingVersion=Installed version:
english.UpgradeTargetVersion=Target version:
english.UpgradeSetupManaged=Setup will upgrade or repair AgentDock and preserve the current startup, connection, tasks, Skills, and configuration.
english.UpgradeLegacyManaged=An existing PowerShell installation was found. Setup will migrate it to the graphical installer and preserve the current startup, connection, tasks, Skills, and configuration.
english.ReadyUpgrade=Setup is ready to upgrade or repair AgentDock.
english.OfflineProgressCaption=Installing AgentDock
english.OfflineProgressDescription=All required components are included in this installer. No GitHub download is required.
english.OfflineProgressPreparing=Preparing the bundled installation files...
english.OfflineProgressApplying=Updating AgentDock and preserving the current configuration...
english.OfflineProgressFinishing=Starting AgentDock and checking its status...

chinesesimplified.DocsShortcut=AgentDock 使用文档
chinesesimplified.UninstallShortcut=卸载 AgentDock
chinesesimplified.StartupPageCaption=启动方式
chinesesimplified.StartupPageDescription=选择 AgentDock 如何随 Windows 启动
chinesesimplified.StartupPageSubCaption=普通用户建议保持自动启动。AgentDock 始终只使用当前用户权限。
chinesesimplified.StartupOption=登录 Windows 后自动启动 AgentDock 和托盘
chinesesimplified.ConnectionPageCaption=连接方式
chinesesimplified.ConnectionPageDescription=选择允许访问 AgentDock 的范围
chinesesimplified.ConnectionPageSubCaption=默认只允许本机访问。公网访问必须由你明确开启。
chinesesimplified.LocalMode=仅本机使用（推荐）
chinesesimplified.QuickMode=创建临时公网地址
chinesesimplified.NamedMode=使用自己的 Cloudflare 域名
chinesesimplified.FixedPageCaption=固定公网地址
chinesesimplified.FixedPageDescription=填写 Cloudflare Tunnel 信息
chinesesimplified.FixedPageSubCaption=公网地址只填写 HTTPS Origin，例如 https://agent.example.com。Tunnel Token 不会进入命令行。
chinesesimplified.ServerURLLabel=HTTPS 公网地址：
chinesesimplified.TunnelTokenLabel=Cloudflare Tunnel Token：
chinesesimplified.CopyLocal=复制本地 MCP 地址
chinesesimplified.CopyPublic=复制公网 MCP 地址
chinesesimplified.CopyBearer=复制 Bearer Token
chinesesimplified.CopyOAuth=复制 OAuth 登录密码
chinesesimplified.InvalidServerURL=固定公网地址必须以 https:// 开头，并且不能包含引号。
chinesesimplified.TokenRequired=请填写 Cloudflare Tunnel Token。
chinesesimplified.TokenFileFailed=无法创建临时 Tunnel Token 文件。
chinesesimplified.InstallerStartFailed=无法启动 AgentDock 安装器。
chinesesimplified.InstallerExitCode=安装脚本退出码：
chinesesimplified.InstallFailed=AgentDock 安装失败：
chinesesimplified.Health=状态：
chinesesimplified.LocalMCP=本地 MCP 地址：
chinesesimplified.PublicMCP=公网 MCP 地址：
chinesesimplified.BearerToken=Bearer Token：
chinesesimplified.OAuthPassword=OAuth 登录密码：
chinesesimplified.PurgeStateQuestion=是否同时删除任务、Skill、配置和默认工作目录？选择“否”将保留用户数据。
chinesesimplified.UninstallScriptMissing=AgentDock 卸载脚本不存在。
chinesesimplified.UninstallScriptFailed=AgentDock 清理脚本执行失败，退出码：
chinesesimplified.UpgradeWelcome=检测到已安装的 AgentDock
chinesesimplified.UpgradeExistingVersion=当前版本：
chinesesimplified.UpgradeTargetVersion=目标版本：
chinesesimplified.UpgradeSetupManaged=安装程序将升级或修复 AgentDock，并保留当前启动方式、连接方式、任务、Skill 和配置。
chinesesimplified.UpgradeLegacyManaged=检测到旧版 PowerShell 安装。安装程序将迁移为图形安装版，并保留当前启动方式、连接方式、任务、Skill 和配置。
chinesesimplified.ReadyUpgrade=安装程序已准备好升级或修复 AgentDock。
chinesesimplified.OfflineProgressCaption=正在安装 AgentDock
chinesesimplified.OfflineProgressDescription=所需组件均已包含在安装包中，安装过程不会从 GitHub 下载文件。
chinesesimplified.OfflineProgressPreparing=正在准备离线安装文件...
chinesesimplified.OfflineProgressApplying=正在更新 AgentDock 并保留现有配置...
chinesesimplified.OfflineProgressFinishing=正在启动 AgentDock 并检查运行状态...

[Files]
Source: "..\..\scripts\install.ps1"; Flags: dontcopy
Source: "{#OfflinePayloadDir}\agentdock_windows_{#PayloadArchitecture}.zip"; Flags: dontcopy
Source: "{#OfflinePayloadDir}\agentdock_windows_{#PayloadArchitecture}.zip.sha256"; Flags: dontcopy
Source: "{#OfflinePayloadDir}\cloudflared.exe"; Flags: dontcopy
Source: "..\..\scripts\install.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "..\..\scripts\uninstall-windows.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "assets\agentdock.ico"; DestDir: "{app}\installer"; Flags: ignoreversion

[UninstallDelete]
Type: filesandordirs; Name: "{app}\bin"

[Icons]
Name: "{group}\AgentDock"; Filename: "{app}\bin\agentdock-tray.exe"; WorkingDir: "{app}"
Name: "{group}\{code:GetLocalizedMessage|DocsShortcut}"; Filename: "https://uvwt.github.io/agentdock-docs/"
Name: "{group}\{code:GetLocalizedMessage|UninstallShortcut}"; Filename: "{uninstallexe}"

[Code]
var
  StartupPage: TInputOptionWizardPage;
  ConnectionPage: TInputOptionWizardPage;
  FixedTunnelPage: TInputQueryWizardPage;
  ResultMemo: TNewMemo;
  CopyLocalButton: TNewButton;
  CopyPublicButton: TNewButton;
  CopyBearerButton: TNewButton;
  CopyOAuthButton: TNewButton;
  PurgeState: Boolean;
  UninstallCleanupExecuted: Boolean;
  ResultFilePath: String;
  TemporaryTokenFilePath: String;
  LocalMCPURL: String;
  PublicMCPURL: String;
  BearerToken: String;
  OAuthPassword: String;
  ExistingInstallDetected: Boolean;
  ExistingInstallVersion: String;
  ExistingInstallSource: String;
  ResolvedInstallRoot: String;
  InstallProgressPage: TOutputProgressWizardPage;

function GetLocalizedMessage(Key: String): String;
begin
  Result := CustomMessage(Key);
end;

function ReadTrimmedTextFile(Path: String): String;
var
  Content: AnsiString;
begin
  Result := '';
  if FileExists(Path) then
  begin
    if LoadStringFromFile(Path, Content) then
      Result := Trim(String(Content));
  end;
end;

function ResolveInstallRoot(): String;
var
  UninstallKey: String;
  InstallLocation: String;
begin
  Result := Trim(ExpandConstant('{param:DIR|}'));
  if Result <> '' then
    Exit;

  UninstallKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppIdValue}_is1';
  if RegQueryStringValue(HKCU, UninstallKey, 'InstallLocation', InstallLocation) and
    (Trim(InstallLocation) <> '') then
  begin
    Result := RemoveBackslashUnlessRoot(Trim(InstallLocation));
    Exit;
  end;

  Result := ExpandConstant('{localappdata}\AgentDock');
end;

function ExistingInstallRoot(): String;
begin
  Result := ResolvedInstallRoot;
end;

function DetectExistingInstallation(): Boolean;
var
  UninstallKey: String;
  BinaryPath: String;
  VersionValue: String;
begin
  ExistingInstallVersion := '';
  ExistingInstallSource := '';
  UninstallKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppIdValue}_is1';

  if RegQueryStringValue(HKCU, UninstallKey, 'DisplayVersion', VersionValue) then
  begin
    ExistingInstallVersion := Trim(VersionValue);
    ExistingInstallSource := 'setup';
    Result := True;
    Exit;
  end;

  BinaryPath := AddBackslash(ExistingInstallRoot()) + 'bin\agentdock.exe';
  if FileExists(BinaryPath) or
    FileExists(AddBackslash(ExistingInstallRoot()) + 'runtime.json') or
    FileExists(AddBackslash(ExistingInstallRoot()) + 'start-agentdock.ps1') then
  begin
    if GetVersionNumbersString(BinaryPath, VersionValue) then
      ExistingInstallVersion := Trim(VersionValue);
    ExistingInstallSource := 'powershell';
    Result := True;
    Exit;
  end;

  Result := False;
end;

function LegacyAgentDockScheduledTaskExists(): Boolean;
var
  ExitCode: Integer;
begin
  Result :=
    Exec(
      ExpandConstant('{sys}\schtasks.exe'),
      '/Query /TN "\AgentDock"',
      '',
      SW_HIDE,
      ewWaitUntilTerminated,
      ExitCode) and
    (ExitCode = 0);
  if Result then
    Log('AgentDock legacy scheduled task detected.');
end;

procedure LoadExistingSettings();
var
  Mode: String;
  URL: String;
  RunKey: String;
begin
  if not ExistingInstallDetected then
    Exit;

  RunKey := 'Software\Microsoft\Windows\CurrentVersion\Run';
  StartupPage.Values[0] :=
    RegValueExists(HKCU, RunKey, 'AgentDock') or
    RegValueExists(HKCU, RunKey, 'AgentDockTray') or
    LegacyAgentDockScheduledTaskExists();

  Mode := Lowercase(ReadTrimmedTextFile(AddBackslash(ExistingInstallRoot()) + 'cloudflared-mode.txt'));
  if Mode = 'quick' then
    ConnectionPage.SelectedValueIndex := 1
  else if Mode = 'named' then
    ConnectionPage.SelectedValueIndex := 2
  else
    ConnectionPage.SelectedValueIndex := 0;

  URL := ReadTrimmedTextFile(AddBackslash(ExistingInstallRoot()) + 'server-url.txt');
  if URL <> '' then
    FixedTunnelPage.Values[0] := URL;
end;

procedure ApplyExistingInstallPresentation();
var
  Details: String;
begin
  if not ExistingInstallDetected then
    Exit;

  WizardForm.WelcomeLabel1.Caption := GetLocalizedMessage('UpgradeWelcome');
  Details := '';
  if ExistingInstallVersion <> '' then
    Details := GetLocalizedMessage('UpgradeExistingVersion') + ' ' + ExistingInstallVersion + #13#10;
  Details := Details + GetLocalizedMessage('UpgradeTargetVersion') + ' {#AppVersion}' + #13#10#13#10;
  if ExistingInstallSource = 'setup' then
    Details := Details + GetLocalizedMessage('UpgradeSetupManaged')
  else
    Details := Details + GetLocalizedMessage('UpgradeLegacyManaged');
  WizardForm.WelcomeLabel2.Caption := Details;
  Log('AgentDock existing installation detected: source=' + ExistingInstallSource +
    ', version=' + ExistingInstallVersion + ', root=' + ExistingInstallRoot());
end;

function QuoteArgument(const Value: String): String;
begin
  Result := '"' + Value + '"';
end;

function SelectedTunnelMode(): String;
begin
  case ConnectionPage.SelectedValueIndex of
    1: Result := 'quick';
    2: Result := 'named';
  else
    Result := 'none';
  end;
end;

procedure CopyTextToClipboard(Value: String);
var
  ValueFile: String;
  PowerShellPath: String;
  Parameters: String;
  ExitCode: Integer;
begin
  if Value = '' then
    Exit;
  ValueFile := ExpandConstant('{tmp}\agentdock-clipboard.txt');
  if not SaveStringToFile(ValueFile, Value, False) then
    Exit;
  try
    PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    Parameters :=
      '-NoLogo -NoProfile -NonInteractive -Command ' +
      QuoteArgument('$value=[IO.File]::ReadAllText($args[0]); Set-Clipboard -Value $value') +
      ' ' + QuoteArgument(ValueFile);
    Exec(PowerShellPath, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  finally
    DeleteFile(ValueFile);
  end;
end;

procedure CopyLocalClick(Sender: TObject);
begin
  if LocalMCPURL <> '' then
    CopyTextToClipboard(LocalMCPURL);
end;

procedure CopyPublicClick(Sender: TObject);
begin
  if PublicMCPURL <> '' then
    CopyTextToClipboard(PublicMCPURL);
end;

procedure CopyBearerClick(Sender: TObject);
begin
  if BearerToken <> '' then
    CopyTextToClipboard(BearerToken);
end;

procedure CopyOAuthClick(Sender: TObject);
begin
  if OAuthPassword <> '' then
    CopyTextToClipboard(OAuthPassword);
end;

procedure InitializeWizard();
var
  ModeParam: String;
  AutoStartParam: String;
begin
  Log('AgentDock active language: ' + ActiveLanguage());
  ResolvedInstallRoot := ResolveInstallRoot();
  ExistingInstallDetected := DetectExistingInstallation();

  StartupPage := CreateInputOptionPage(
    wpSelectDir,
    GetLocalizedMessage('StartupPageCaption'),
    GetLocalizedMessage('StartupPageDescription'),
    GetLocalizedMessage('StartupPageSubCaption'),
    False,
    False
  );
  StartupPage.Add(GetLocalizedMessage('StartupOption'));
  StartupPage.Values[0] := True;

  ConnectionPage := CreateInputOptionPage(
    StartupPage.ID,
    GetLocalizedMessage('ConnectionPageCaption'),
    GetLocalizedMessage('ConnectionPageDescription'),
    GetLocalizedMessage('ConnectionPageSubCaption'),
    True,
    False
  );
  ConnectionPage.Add(GetLocalizedMessage('LocalMode'));
  ConnectionPage.Add(GetLocalizedMessage('QuickMode'));
  ConnectionPage.Add(GetLocalizedMessage('NamedMode'));
  ConnectionPage.SelectedValueIndex := 0;

  FixedTunnelPage := CreateInputQueryPage(
    ConnectionPage.ID,
    GetLocalizedMessage('FixedPageCaption'),
    GetLocalizedMessage('FixedPageDescription'),
    GetLocalizedMessage('FixedPageSubCaption')
  );
  FixedTunnelPage.Add(GetLocalizedMessage('ServerURLLabel'), False);
  FixedTunnelPage.Add(GetLocalizedMessage('TunnelTokenLabel'), True);

  LoadExistingSettings();

  ModeParam := Lowercase(ExpandConstant('{param:MODE|}'));
  if ModeParam = 'quick' then
    ConnectionPage.SelectedValueIndex := 1
  else if ModeParam = 'named' then
    ConnectionPage.SelectedValueIndex := 2
  else if ModeParam = 'local' then
    ConnectionPage.SelectedValueIndex := 0;

  AutoStartParam := Lowercase(ExpandConstant('{param:AUTOSTART|}'));
  if (AutoStartParam = '0') or (AutoStartParam = 'false') then
    StartupPage.Values[0] := False
  else if (AutoStartParam = '1') or (AutoStartParam = 'true') then
    StartupPage.Values[0] := True;

  if ExpandConstant('{param:SERVERURL|}') <> '' then
    FixedTunnelPage.Values[0] := ExpandConstant('{param:SERVERURL|}');

  ApplyExistingInstallPresentation();

  InstallProgressPage := CreateOutputProgressPage(
    GetLocalizedMessage('OfflineProgressCaption'),
    GetLocalizedMessage('OfflineProgressDescription')
  );

  ResultMemo := TNewMemo.Create(WizardForm);
  ResultMemo.Parent := WizardForm.FinishedPage;
  ResultMemo.Left := ScaleX(0);
  ResultMemo.Top := WizardForm.FinishedLabel.Top + WizardForm.FinishedLabel.Height + ScaleY(12);
  ResultMemo.Width := WizardForm.FinishedPage.ClientWidth;
  ResultMemo.Height := ScaleY(96);
  ResultMemo.ReadOnly := True;
  ResultMemo.ScrollBars := ssVertical;
  ResultMemo.Visible := False;

  CopyLocalButton := TNewButton.Create(WizardForm);
  CopyLocalButton.Parent := WizardForm.FinishedPage;
  CopyLocalButton.Left := ScaleX(0);
  CopyLocalButton.Top := ResultMemo.Top + ResultMemo.Height + ScaleY(8);
  CopyLocalButton.Width := ScaleX(130);
  CopyLocalButton.Caption := GetLocalizedMessage('CopyLocal');
  CopyLocalButton.OnClick := @CopyLocalClick;
  CopyLocalButton.Visible := False;

  CopyPublicButton := TNewButton.Create(WizardForm);
  CopyPublicButton.Parent := WizardForm.FinishedPage;
  CopyPublicButton.Left := CopyLocalButton.Left + CopyLocalButton.Width + ScaleX(8);
  CopyPublicButton.Top := CopyLocalButton.Top;
  CopyPublicButton.Width := ScaleX(130);
  CopyPublicButton.Caption := GetLocalizedMessage('CopyPublic');
  CopyPublicButton.OnClick := @CopyPublicClick;
  CopyPublicButton.Visible := False;

  CopyBearerButton := TNewButton.Create(WizardForm);
  CopyBearerButton.Parent := WizardForm.FinishedPage;
  CopyBearerButton.Left := ScaleX(0);
  CopyBearerButton.Top := CopyLocalButton.Top + CopyLocalButton.Height + ScaleY(8);
  CopyBearerButton.Width := ScaleX(130);
  CopyBearerButton.Caption := GetLocalizedMessage('CopyBearer');
  CopyBearerButton.OnClick := @CopyBearerClick;
  CopyBearerButton.Visible := False;

  CopyOAuthButton := TNewButton.Create(WizardForm);
  CopyOAuthButton.Parent := WizardForm.FinishedPage;
  CopyOAuthButton.Left := CopyBearerButton.Left + CopyBearerButton.Width + ScaleX(8);
  CopyOAuthButton.Top := CopyBearerButton.Top;
  CopyOAuthButton.Width := ScaleX(130);
  CopyOAuthButton.Caption := GetLocalizedMessage('CopyOAuth');
  CopyOAuthButton.OnClick := @CopyOAuthClick;
  CopyOAuthButton.Visible := False;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = FixedTunnelPage.ID) and (SelectedTunnelMode() <> 'named');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  URL: String;
begin
  Result := True;
  if (CurPageID = ConnectionPage.ID) and (SelectedTunnelMode() <> 'none') then
    StartupPage.Values[0] := True;
  if CurPageID = FixedTunnelPage.ID then
  begin
    URL := Trim(FixedTunnelPage.Values[0]);
    if (Pos('https://', Lowercase(URL)) <> 1) or (Pos('"', URL) > 0) then
    begin
      MsgBox(GetLocalizedMessage('InvalidServerURL'), mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if (Trim(FixedTunnelPage.Values[1]) = '') and
      (ExpandConstant('{param:TUNNELTOKENFILE|}') = '') and
      (not FileExists(AddBackslash(ExistingInstallRoot()) + 'cloudflared-token.dpapi')) then
    begin
      MsgBox(GetLocalizedMessage('TokenRequired'), mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  PowerShellPath: String;
  InstallScriptPath: String;
  OfflineArchivePath: String;
  OfflineChecksumPath: String;
  OfflineCloudflaredPath: String;
  TokenFilePath: String;
  SilentTokenFile: String;
  Parameters: String;
  TunnelMode: String;
  ExitCode: Integer;
  ErrorMessage: String;
  DeleteTokenFile: Boolean;
begin
  Result := '';
  InstallProgressPage.Show;
  try
    InstallProgressPage.SetText(GetLocalizedMessage('OfflineProgressPreparing'), '');
    InstallProgressPage.SetProgress(1, 4);
    ExtractTemporaryFile('install.ps1');
    ExtractTemporaryFile('agentdock_windows_{#PayloadArchitecture}.zip');
    ExtractTemporaryFile('agentdock_windows_{#PayloadArchitecture}.zip.sha256');
    ExtractTemporaryFile('cloudflared.exe');

    PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    InstallScriptPath := ExpandConstant('{tmp}\install.ps1');
    OfflineArchivePath := ExpandConstant('{tmp}\agentdock_windows_{#PayloadArchitecture}.zip');
    OfflineChecksumPath := ExpandConstant('{tmp}\agentdock_windows_{#PayloadArchitecture}.zip.sha256');
    OfflineCloudflaredPath := ExpandConstant('{tmp}\cloudflared.exe');
    ResultFilePath := ExpandConstant('{tmp}\agentdock-install-result.ini');
    DeleteFile(ResultFilePath);
    TunnelMode := SelectedTunnelMode();
    DeleteTokenFile := False;

    InstallProgressPage.SetProgress(2, 4);
    Parameters :=
      '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + QuoteArgument(InstallScriptPath) +
      ' -Version ' + QuoteArgument('{#AppVersion}') +
      ' -OfflineArchive ' + QuoteArgument(OfflineArchivePath) +
      ' -OfflineChecksumFile ' + QuoteArgument(OfflineChecksumPath) +
      ' -OfflineCloudflaredBinary ' + QuoteArgument(OfflineCloudflaredPath) +
      ' -InstallDir ' + QuoteArgument(ExpandConstant('{app}\bin')) +
      ' -TunnelMode ' + TunnelMode +
      ' -InstallChannel setup' +
      ' -ResultFile ' + QuoteArgument(ResultFilePath);

    if StartupPage.Values[0] or (TunnelMode <> 'none') then
      Parameters := Parameters + ' -RegisterStartup';

    if TunnelMode = 'named' then
    begin
      Parameters := Parameters + ' -ServerUrl ' + QuoteArgument(Trim(FixedTunnelPage.Values[0]));
      SilentTokenFile := ExpandConstant('{param:TUNNELTOKENFILE|}');
      if SilentTokenFile <> '' then
        TokenFilePath := SilentTokenFile
      else if Trim(FixedTunnelPage.Values[1]) <> '' then
      begin
        TokenFilePath := ExpandConstant('{tmp}\agentdock-tunnel-token.txt');
        TemporaryTokenFilePath := TokenFilePath;
        DeleteTokenFile := True;
        if not SaveStringToFile(TokenFilePath, Trim(FixedTunnelPage.Values[1]), False) then
        begin
          Result := GetLocalizedMessage('TokenFileFailed');
          Exit;
        end;
      end;
      if TokenFilePath <> '' then
        Parameters := Parameters + ' -TunnelTokenFile ' + QuoteArgument(TokenFilePath);
      if DeleteTokenFile then
        Parameters := Parameters + ' -DeleteTunnelTokenFile';
    end;

    InstallProgressPage.SetText(GetLocalizedMessage('OfflineProgressApplying'), '');
    InstallProgressPage.SetProgress(3, 4);
    if not Exec(PowerShellPath, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    begin
      Result := GetLocalizedMessage('InstallerStartFailed');
      Exit;
    end;
    if ExitCode <> 0 then
    begin
      ErrorMessage := GetIniString('AgentDock', 'Message', '', ResultFilePath);
      if ErrorMessage = '' then
        ErrorMessage := GetLocalizedMessage('InstallerExitCode') + ' ' + IntToStr(ExitCode);
      Result := GetLocalizedMessage('InstallFailed') + ' ' + ErrorMessage;
      Exit;
    end;
    InstallProgressPage.SetText(GetLocalizedMessage('OfflineProgressFinishing'), '');
    InstallProgressPage.SetProgress(4, 4);
  finally
    InstallProgressPage.Hide;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Summary: String;
begin
  if (CurPageID = wpReady) and ExistingInstallDetected then
    WizardForm.ReadyLabel.Caption := GetLocalizedMessage('ReadyUpgrade');
  if CurPageID <> wpFinished then
    Exit;

  LocalMCPURL := GetIniString('AgentDock', 'LocalMCPUrl', '', ResultFilePath);
  PublicMCPURL := GetIniString('AgentDock', 'PublicMCPUrl', '', ResultFilePath);
  BearerToken := GetIniString('AgentDock', 'BearerToken', '', ResultFilePath);
  OAuthPassword := GetIniString('AgentDock', 'OAuthPassword', '', ResultFilePath);
  Summary := GetLocalizedMessage('Health') + ' ' +
    GetIniString('AgentDock', 'Health', 'unknown', ResultFilePath) + #13#10 +
    GetLocalizedMessage('LocalMCP') + ' ' + LocalMCPURL;
  if PublicMCPURL <> '' then
    Summary := Summary + #13#10 + GetLocalizedMessage('PublicMCP') + ' ' + PublicMCPURL;
  if BearerToken <> '' then
    Summary := Summary + #13#10 + GetLocalizedMessage('BearerToken') + ' ' + BearerToken;
  if OAuthPassword <> '' then
    Summary := Summary + #13#10 + GetLocalizedMessage('OAuthPassword') + ' ' + OAuthPassword;

  ResultMemo.Text := Summary;
  ResultMemo.Visible := True;
  CopyLocalButton.Visible := LocalMCPURL <> '';
  CopyPublicButton.Visible := PublicMCPURL <> '';
  CopyBearerButton.Visible := BearerToken <> '';
  CopyOAuthButton.Visible := OAuthPassword <> '';
end;

function InitializeUninstall(): Boolean;
begin
  PurgeState := False;
  UninstallCleanupExecuted := False;
  if not UninstallSilent then
    PurgeState := MsgBox(
      GetLocalizedMessage('PurgeStateQuestion'),
      mbConfirmation,
      MB_YESNO
    ) = IDYES;
  Result := True;
end;

function GetUninstallParameters(Param: String): String;
begin
  Result := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    QuoteArgument(ExpandConstant('{app}\installer\uninstall-windows.ps1')) +
    ' -InstallDir ' + QuoteArgument(ExpandConstant('{app}\bin')) +
    ' -KeepInstallDir';
  if PurgeState then
    Result := Result + ' -PurgeState';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  PowerShellPath: String;
  ScriptPath: String;
  ExitCode: Integer;
begin
  if (CurUninstallStep <> usAppMutexCheck) or UninstallCleanupExecuted then
    Exit;

  UninstallCleanupExecuted := True;
  Log('AgentDock: running managed cleanup before uninstall file removal.');
  ScriptPath := ExpandConstant('{app}\installer\uninstall-windows.ps1');
  if not FileExists(ScriptPath) then
    RaiseException(GetLocalizedMessage('UninstallScriptMissing'));

  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  if not Exec(
    PowerShellPath,
    GetUninstallParameters(''),
    '',
    SW_HIDE,
    ewWaitUntilTerminated,
    ExitCode
  ) then
    RaiseException(GetLocalizedMessage('UninstallScriptFailed') + ' start');
  if ExitCode <> 0 then
    RaiseException(
      GetLocalizedMessage('UninstallScriptFailed') + ' ' + IntToStr(ExitCode)
    );
  Log('AgentDock: managed cleanup completed successfully.');
end;

procedure DeinitializeSetup();
begin
  if ResultFilePath <> '' then
    DeleteFile(ResultFilePath);
  if TemporaryTokenFilePath <> '' then
    DeleteFile(TemporaryTokenFilePath);
end;
