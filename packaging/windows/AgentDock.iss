#ifndef AppVersion
#define AppVersion "0.0.0"
#endif

#ifndef OutputDir
#define OutputDir "..\..\dist"
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
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=AgentDockSetup
SetupIconFile=assets\agentdock.ico
UninstallDisplayIcon={app}\installer\agentdock.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UsePreviousAppDir=yes
#ifdef SignedBuild
SignTool=agentdock-sign
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"


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
english.ZHDocsShortcut=AgentDock 使用文档
english.ZHUninstallShortcut=卸载 AgentDock
english.ZHStartupPageCaption=启动方式
english.ZHStartupPageDescription=选择 AgentDock 如何随 Windows 启动
english.ZHStartupPageSubCaption=普通用户建议保持自动启动。AgentDock 始终只使用当前用户权限。
english.ZHStartupOption=登录 Windows 后自动启动 AgentDock 和托盘
english.ZHConnectionPageCaption=连接方式
english.ZHConnectionPageDescription=选择允许访问 AgentDock 的范围
english.ZHConnectionPageSubCaption=默认只允许本机访问。公网访问必须由你明确开启。
english.ZHLocalMode=仅本机使用（推荐）
english.ZHQuickMode=创建临时公网地址
english.ZHNamedMode=使用自己的 Cloudflare 域名
english.ZHFixedPageCaption=固定公网地址
english.ZHFixedPageDescription=填写 Cloudflare Tunnel 信息
english.ZHFixedPageSubCaption=公网地址只填写 HTTPS Origin，例如 https://agent.example.com。Tunnel Token 不会进入命令行。
english.ZHServerURLLabel=HTTPS 公网地址：
english.ZHTunnelTokenLabel=Cloudflare Tunnel Token：
english.ZHCopyLocal=复制本地 MCP 地址
english.ZHCopyPublic=复制公网 MCP 地址
english.ZHCopyBearer=复制 Bearer Token
english.ZHCopyOAuth=复制 OAuth 登录密码
english.ZHInvalidServerURL=固定公网地址必须以 https:// 开头，并且不能包含引号。
english.ZHTokenRequired=请填写 Cloudflare Tunnel Token。
english.ZHTokenFileFailed=无法创建临时 Tunnel Token 文件。
english.ZHInstallerStartFailed=无法启动 AgentDock 安装器。
english.ZHInstallerExitCode=安装脚本退出码：
english.ZHInstallFailed=AgentDock 安装失败：
english.ZHHealth=状态：
english.ZHLocalMCP=本地 MCP 地址：
english.ZHPublicMCP=公网 MCP 地址：
english.ZHBearerToken=Bearer Token：
english.ZHOAuthPassword=OAuth 登录密码：
english.ZHPurgeStateQuestion=是否同时删除任务、Skill、配置和默认工作目录？选择“否”将保留用户数据。

[Files]
Source: "..\..\scripts\install.ps1"; Flags: dontcopy
Source: "..\..\scripts\install.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "..\..\scripts\uninstall-windows.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "assets\agentdock.ico"; DestDir: "{app}\installer"; Flags: ignoreversion

[Icons]
Name: "{group}\AgentDock"; Filename: "{app}\bin\agentdock-tray.exe"; WorkingDir: "{app}"
Name: "{group}\{code:GetLocalizedMessage|DocsShortcut}"; Filename: "https://uvwt.github.io/agentdock-docs/"
Name: "{group}\{code:GetLocalizedMessage|UninstallShortcut}"; Filename: "{uninstallexe}"

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{code:GetUninstallParameters}"; Flags: runhidden waituntilterminated; RunOnceId: "AgentDockUninstall"

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
  ResultFilePath: String;
  TemporaryTokenFilePath: String;
  LocalMCPURL: String;
  PublicMCPURL: String;
  BearerToken: String;
  OAuthPassword: String;

function IsChineseUI(): Boolean;
var
  Language: Integer;
begin
  Language := GetUILanguage();
  Result :=
    (Language = $0804) or
    (Language = $1004) or
    (Language = $0404) or
    (Language = $0C04) or
    (Language = $1404);
end;

function GetLocalizedMessage(Key: String): String;
begin
  if IsChineseUI() then
    Result := CustomMessage('ZH' + Key)
  else
    Result := CustomMessage(Key);
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

procedure CopyLocalClick(Sender: TObject);
begin
  if LocalMCPURL <> '' then
    SetClipboardText(LocalMCPURL);
end;

procedure CopyPublicClick(Sender: TObject);
begin
  if PublicMCPURL <> '' then
    SetClipboardText(PublicMCPURL);
end;

procedure CopyBearerClick(Sender: TObject);
begin
  if BearerToken <> '' then
    SetClipboardText(BearerToken);
end;

procedure CopyOAuthClick(Sender: TObject);
begin
  if OAuthPassword <> '' then
    SetClipboardText(OAuthPassword);
end;

procedure InitializeWizard();
var
  ModeParam: String;
  AutoStartParam: String;
begin
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

  ModeParam := Lowercase(ExpandConstant('{param:MODE|}'));
  if ModeParam = 'quick' then
    ConnectionPage.SelectedValueIndex := 1
  else if ModeParam = 'named' then
    ConnectionPage.SelectedValueIndex := 2;

  AutoStartParam := Lowercase(ExpandConstant('{param:AUTOSTART|}'));
  if (AutoStartParam = '0') or (AutoStartParam = 'false') then
    StartupPage.Values[0] := False;

  FixedTunnelPage.Values[0] := ExpandConstant('{param:SERVERURL|}');

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
      (ExpandConstant('{param:TUNNELTOKENFILE|}') = '') then
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
  TokenFilePath: String;
  SilentTokenFile: String;
  Parameters: String;
  TunnelMode: String;
  ExitCode: Integer;
  ErrorMessage: String;
  DeleteTokenFile: Boolean;
begin
  Result := '';
  ExtractTemporaryFile('install.ps1');

  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  InstallScriptPath := ExpandConstant('{tmp}\install.ps1');
  ResultFilePath := ExpandConstant('{tmp}\agentdock-install-result.ini');
  DeleteFile(ResultFilePath);
  TunnelMode := SelectedTunnelMode();
  DeleteTokenFile := False;

  Parameters :=
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + QuoteArgument(InstallScriptPath) +
    ' -Version ' + QuoteArgument('{#AppVersion}') +
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
    else
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
    Parameters := Parameters + ' -TunnelTokenFile ' + QuoteArgument(TokenFilePath);
    if DeleteTokenFile then
      Parameters := Parameters + ' -DeleteTunnelTokenFile';
  end;

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
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Summary: String;
begin
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
    ' -InstallDir ' + QuoteArgument(ExpandConstant('{app}\bin'));
  if PurgeState then
    Result := Result + ' -PurgeState';
end;

procedure DeinitializeSetup();
begin
  if ResultFilePath <> '' then
    DeleteFile(ResultFilePath);
  if TemporaryTokenFilePath <> '' then
    DeleteFile(TemporaryTokenFilePath);
end;
