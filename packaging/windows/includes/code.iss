[Code]
var
  UpgradeModePage: TInputOptionWizardPage;
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

function RuntimeUsesElevatedCore(): Boolean;
var
  Content: AnsiString;
  Normalized: String;
  ManifestPath: String;
begin
  Result := False;
  ManifestPath := AddBackslash(ExistingInstallRoot()) + 'runtime.json';
  if not FileExists(ManifestPath) then
    Exit;
  if not LoadStringFromFile(ManifestPath, Content) then
    Exit;
  Normalized := Lowercase(String(Content));
  StringChangeEx(Normalized, ' ', '', True);
  StringChangeEx(Normalized, #13, '', True);
  StringChangeEx(Normalized, #10, '', True);
  Result := Pos('"privilege_mode":"elevated"', Normalized) > 0;
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
  StartupPage.Values[1] := RuntimeUsesElevatedCore() or LegacyAgentDockScheduledTaskExists();

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

  UpgradeModePage := CreateInputOptionPage(
    wpWelcome,
    GetLocalizedMessage('UpgradeModeCaption'),
    GetLocalizedMessage('UpgradeModeDescription'),
    GetLocalizedMessage('UpgradeModeSubCaption'),
    True,
    False
  );
  UpgradeModePage.Add(GetLocalizedMessage('UpgradeKeepSettings'));
  UpgradeModePage.Add(GetLocalizedMessage('UpgradeChangeSettings'));
  UpgradeModePage.SelectedValueIndex := 0;

  StartupPage := CreateInputOptionPage(
    UpgradeModePage.ID,
    GetLocalizedMessage('StartupPageCaption'),
    GetLocalizedMessage('StartupPageDescription'),
    GetLocalizedMessage('StartupPageSubCaption'),
    False,
    False
  );
  StartupPage.Add(GetLocalizedMessage('StartupOption'));
  StartupPage.Add(GetLocalizedMessage('ElevatedCoreOption'));
  StartupPage.Values[0] := True;
  StartupPage.Values[1] := True;

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

  AutoStartParam := Lowercase(ExpandConstant('{param:ADMINMODE|}'));
  if (AutoStartParam = '0') or (AutoStartParam = 'false') or (AutoStartParam = 'standard') then
    StartupPage.Values[1] := False
  else if (AutoStartParam = '1') or (AutoStartParam = 'true') or (AutoStartParam = 'elevated') then
    StartupPage.Values[1] := True;

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
var
  PreserveExisting: Boolean;
begin
  PreserveExisting := ExistingInstallDetected and (UpgradeModePage.SelectedValueIndex = 0);
  Result :=
    ((PageID = UpgradeModePage.ID) and (not ExistingInstallDetected)) or
    (PreserveExisting and
      ((PageID = StartupPage.ID) or (PageID = ConnectionPage.ID) or (PageID = FixedTunnelPage.ID))) or
    ((PageID = FixedTunnelPage.ID) and (SelectedTunnelMode() <> 'named'));
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  URL: String;
begin
  Result := True;
  if (CurPageID = StartupPage.ID) and StartupPage.Values[1] then
    StartupPage.Values[0] := True;
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
  PrivilegeMode: String;
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
    if StartupPage.Values[1] then
      PrivilegeMode := 'elevated'
    else
      PrivilegeMode := 'standard';
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
      ' -CorePrivilegeMode ' + PrivilegeMode +
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
  InstalledPrivilegeMode: String;
begin
  if (CurPageID = wpReady) and ExistingInstallDetected then
    WizardForm.ReadyLabel.Caption := GetLocalizedMessage('ReadyUpgrade');
  if CurPageID <> wpFinished then
    Exit;

  LocalMCPURL := GetIniString('AgentDock', 'LocalMCPUrl', '', ResultFilePath);
  PublicMCPURL := GetIniString('AgentDock', 'PublicMCPUrl', '', ResultFilePath);
  BearerToken := GetIniString('AgentDock', 'BearerToken', '', ResultFilePath);
  OAuthPassword := GetIniString('AgentDock', 'OAuthPassword', '', ResultFilePath);
  InstalledPrivilegeMode := GetIniString('AgentDock', 'PrivilegeMode', 'standard', ResultFilePath);
  if InstalledPrivilegeMode = 'elevated' then
    InstalledPrivilegeMode := GetLocalizedMessage('PrivilegeElevated')
  else
    InstalledPrivilegeMode := GetLocalizedMessage('PrivilegeStandard');
  Summary := GetLocalizedMessage('Health') + ' ' +
    GetIniString('AgentDock', 'Health', 'unknown', ResultFilePath) + #13#10 +
    GetLocalizedMessage('PrivilegeMode') + ' ' + InstalledPrivilegeMode + #13#10 +
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
