using System.Text.Json.Serialization;

namespace AgentDock.ControlPanel;

public sealed class RuntimeManifest
{
    [JsonPropertyName("install_root")]
    public string InstallRoot { get; set; } = "";

    [JsonPropertyName("agentdock_binary")]
    public string BinaryPath { get; set; } = "";

    [JsonPropertyName("agentdock_launcher")]
    public string LauncherPath { get; set; } = "";

    [JsonPropertyName("local_mcp_url")]
    public string LocalMcpUrl { get; set; } = "";

    [JsonPropertyName("public_mcp_url")]
    public string PublicMcpUrl { get; set; } = "";

    [JsonPropertyName("public_url")]
    public string PublicUrl { get; set; } = "";

    [JsonPropertyName("port")]
    public int ListenPort { get; set; } = 8765;

    [JsonPropertyName("privilege_mode")]
    public string PrivilegeMode { get; set; } = "standard";

    [JsonPropertyName("agentdock_task_name")]
    public string AgentDockTaskName { get; set; } = "AgentDock";

    [JsonPropertyName("startup_value_name")]
    public string StartupValueName { get; set; } = "AgentDock";

    [JsonPropertyName("tray_binary")]
    public string TrayBinaryPath { get; set; } = "";

    [JsonPropertyName("tray_startup_value_name")]
    public string TrayStartupValueName { get; set; } = "AgentDockTray";

    [JsonPropertyName("tunnel_mode")]
    public string TunnelMode { get; set; } = "none";

    [JsonPropertyName("cloudflared_binary")]
    public string CloudflaredBinary { get; set; } = "";

    [JsonPropertyName("cloudflared_launcher")]
    public string CloudflaredLauncher { get; set; } = "";

    [JsonPropertyName("cloudflared_startup_value_name")]
    public string CloudflaredStartupValueName { get; set; } = "AgentDockCloudflared";
}

public sealed class ControlPanelSettings
{
    [JsonPropertyName("port")]
    public int Port { get; set; } = 8765;

    [JsonPropertyName("log_level")]
    public string LogLevel { get; set; } = "info";

    [JsonPropertyName("nexus_endpoint")]
    public string NexusEndpoint { get; set; } = "";

    [JsonPropertyName("browser_enabled")]
    public bool BrowserEnabled { get; set; }

    [JsonPropertyName("acp_enabled")]
    public bool AcpEnabled { get; set; }

    [JsonPropertyName("acp_agent")]
    public string AcpAgent { get; set; } = "codex";

    [JsonPropertyName("acp_command")]
    public string AcpCommand { get; set; } = "";

    [JsonPropertyName("acp_args")]
    public List<string> AcpArgs { get; set; } = [];
}

public sealed class CoreVersionInfo
{
    [JsonPropertyName("version")]
    public string Version { get; set; } = "";
}

public sealed record RuntimeSnapshot(
    RuntimeManifest Manifest,
    ControlPanelSettings Settings,
    string Version,
    bool CoreRunning,
    bool Healthy,
    bool CloudflaredRunning,
    string LocalMcpUrl,
    string PublicOrigin,
    string PublicMcpUrl,
    string SavedNamedOrigin,
    string TunnelMode,
    bool CoreStartupEnabled,
    bool TrayStartupEnabled,
    bool TunnelTokenStored,
    bool NexusTokenStored,
    DateTimeOffset CheckedAt);

public sealed record UrlTestResult(bool Success, int? StatusCode, TimeSpan Elapsed, string Message);

public sealed class UpdateCheckResult
{
    [JsonPropertyName("current_version")]
    public string CurrentVersion { get; set; } = "";

    [JsonPropertyName("latest_version")]
    public string LatestVersion { get; set; } = "";

    [JsonPropertyName("update_available")]
    public bool UpdateAvailable { get; set; }

    [JsonPropertyName("message")]
    public string Message { get; set; } = "";
}

public sealed record UpdateProgress(int Percentage, string Message);

public sealed record AcpAdapterResolution(bool Available, string Command, IReadOnlyList<string> Arguments, string Message);
