using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Microsoft.Win32;

namespace AgentDock.ControlPanel;

public sealed class RuntimeService : IDisposable
{
    private const string AuthEntropy = "agentdock.startup.v1";
    private const string OAuthPasswordEntropy = "agentdock.oauth.password.v1";
    private const string TunnelTokenEntropy = "agentdock.cloudflare.tunnel.v1";
    private const string NexusTokenEntropy = "agentdock.nexus.token.v1";
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(10) };

    public RuntimeService()
    {
        RuntimeRoot = ResolveRuntimeRoot();
    }

    public string RuntimeRoot { get; }
    public string ManifestPath => Path.Combine(RuntimeRoot, "runtime.json");
    public string SettingsPath => Path.Combine(RuntimeRoot, "control-panel-settings.json");
    public string LogsDirectory => Path.Combine(RuntimeRoot, "logs");
    public string ConfigDirectory => RuntimeRoot;

    public async Task<RuntimeSnapshot> GetSnapshotAsync(CancellationToken cancellationToken = default)
    {
        var manifest = await ReadJsonAsync<RuntimeManifest>(ManifestPath, cancellationToken) ?? new RuntimeManifest();
        var manifestPort = manifest.ListenPort is >= 1 and <= 65535 ? manifest.ListenPort : 8765;
        var settings = await ReadJsonAsync<ControlPanelSettings>(SettingsPath, cancellationToken);
        if (settings is null)
        {
            settings = new ControlPanelSettings { Port = manifestPort };
        }
        else if (settings.Port is < 1 or > 65535)
        {
            settings.Port = manifestPort;
        }

        if (string.IsNullOrWhiteSpace(settings.LogLevel))
        {
            settings.LogLevel = "info";
        }

        var localOrigin = $"http://127.0.0.1:{settings.Port}";
        var localMcpUrl = localOrigin + "/mcp";
        var publicOrigin = ReadFirstNonEmpty(
            Path.Combine(RuntimeRoot, "quick-tunnel-url.txt"),
            Path.Combine(RuntimeRoot, "server-url.txt"));
        if (string.IsNullOrWhiteSpace(publicOrigin))
        {
            publicOrigin = manifest.PublicUrl;
        }
        if (string.IsNullOrWhiteSpace(publicOrigin) && Uri.TryCreate(manifest.PublicMcpUrl, UriKind.Absolute, out var manifestPublicUri))
        {
            publicOrigin = manifestPublicUri.GetLeftPart(UriPartial.Authority);
        }

        publicOrigin = publicOrigin.TrimEnd('/');
        var publicMcpUrl = string.IsNullOrWhiteSpace(publicOrigin) ? "" : publicOrigin + "/mcp";
        var savedNamedOrigin = ReadText(Path.Combine(RuntimeRoot, "named-server-url.txt")).TrimEnd('/');
        var healthy = await IsHealthyAsync(localOrigin, cancellationToken);
        var coreRunning = healthy || IsProcessRunningAtPath("agentdock", manifest.BinaryPath);
        var cloudflaredRunning = IsProcessRunningAtPath("cloudflared", manifest.CloudflaredBinary);
        var tunnelMode = ReadText(Path.Combine(RuntimeRoot, "cloudflared-mode.txt"));
        if (string.IsNullOrWhiteSpace(tunnelMode))
        {
            tunnelMode = string.IsNullOrWhiteSpace(manifest.TunnelMode) ? "none" : manifest.TunnelMode;
        }

        return new RuntimeSnapshot(
            manifest,
            settings,
            coreRunning,
            healthy,
            cloudflaredRunning,
            localMcpUrl,
            publicOrigin,
            publicMcpUrl,
            savedNamedOrigin,
            tunnelMode,
            IsCoreStartupEnabled(manifest),
            IsRunValuePresent(manifest.TrayStartupValueName, "AgentDockTray"),
            File.Exists(Path.Combine(RuntimeRoot, "cloudflared-token.dpapi")),
            File.Exists(Path.Combine(RuntimeRoot, "nexus-token.dpapi")),
            DateTimeOffset.Now);
    }

    public string ReadBearerToken() => ReadProtectedText(Path.Combine(RuntimeRoot, "auth-token.dpapi"), AuthEntropy);
    public string ReadOAuthPassword() => ReadProtectedText(Path.Combine(RuntimeRoot, "oauth-password.dpapi"), OAuthPasswordEntropy);
    public string ReadTunnelToken() => ReadProtectedText(Path.Combine(RuntimeRoot, "cloudflared-token.dpapi"), TunnelTokenEntropy);
    public string ReadNexusToken() => ReadProtectedText(Path.Combine(RuntimeRoot, "nexus-token.dpapi"), NexusTokenEntropy);

    public Task RunActionAsync(string action, CancellationToken cancellationToken = default) =>
        RunManagementScriptAsync(["-Action", action], cancellationToken);

    public async Task SetTunnelModeAsync(
        string mode,
        string serverUrl,
        string tunnelToken,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string>
        {
            "-Action", "set-mode",
            "-Mode", mode,
            "-ServerUrl", serverUrl ?? ""
        };
        string? secretFile = null;
        try
        {
            if (!string.IsNullOrWhiteSpace(tunnelToken))
            {
                secretFile = await WriteSecretFileAsync(tunnelToken, cancellationToken);
                arguments.AddRange(["-TunnelTokenFile", secretFile]);
            }

            await RunManagementScriptAsync(arguments, cancellationToken);
        }
        finally
        {
            DeleteSecretFile(secretFile);
        }
    }

    public Task RegenerateQuickTunnelAsync(CancellationToken cancellationToken = default) =>
        RunManagementScriptAsync(["-Action", "regenerate-quick"], cancellationToken);

    public async Task SaveSettingsAsync(
        ControlPanelSettings settings,
        string nexusToken,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string>
        {
            "-Action", "save-settings",
            "-Port", settings.Port.ToString(),
            "-LogLevel", settings.LogLevel,
            "-NexusEndpoint", settings.NexusEndpoint ?? "",
            "-BrowserEnabled", settings.BrowserEnabled ? "true" : "false",
            "-BrowserRunnerDir", settings.BrowserRunnerDir ?? "",
            "-BrowserNodePath", settings.BrowserNodePath ?? ""
        };
        string? secretFile = null;
        try
        {
            if (!string.IsNullOrWhiteSpace(nexusToken))
            {
                secretFile = await WriteSecretFileAsync(nexusToken, cancellationToken);
                arguments.AddRange(["-NexusTokenFile", secretFile]);
            }

            await RunManagementScriptAsync(arguments, cancellationToken);
        }
        finally
        {
            DeleteSecretFile(secretFile);
        }
    }

    public Task SetStartupAsync(string component, bool enabled, CancellationToken cancellationToken = default) =>
        RunManagementScriptAsync(
            ["-Action", "set-startup", "-Component", component, "-Enabled", enabled ? "true" : "false"],
            cancellationToken);

    public async Task<UrlTestResult> TestUrlAsync(string value, CancellationToken cancellationToken = default)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            return new UrlTestResult(false, null, TimeSpan.Zero, "地址无效");
        }

        var healthUri = new UriBuilder(uri) { Path = "/healthz", Query = "", Fragment = "" }.Uri;
        var stopwatch = Stopwatch.StartNew();
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, healthUri);
            using var response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            stopwatch.Stop();
            var success = response.IsSuccessStatusCode;
            return new UrlTestResult(
                success,
                (int)response.StatusCode,
                stopwatch.Elapsed,
                success ? $"访问正常 · {(int)response.StatusCode} · {stopwatch.ElapsedMilliseconds} ms" : $"访问失败 · {(int)response.StatusCode}");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            stopwatch.Stop();
            return new UrlTestResult(false, null, stopwatch.Elapsed, ex is TaskCanceledException ? "访问超时" : ex.Message);
        }
    }

    public void OpenLogsDirectory() => OpenDirectory(LogsDirectory);
    public void OpenConfigDirectory() => OpenDirectory(ConfigDirectory);

    private async Task RunManagementScriptAsync(IReadOnlyCollection<string> arguments, CancellationToken cancellationToken)
    {
        var script = ResolveManagementScript();
        if (!File.Exists(script))
        {
            throw new FileNotFoundException("找不到 Windows 管理脚本，请运行 Setup.exe 修复安装。", script);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(script);
        startInfo.ArgumentList.Add("-RuntimeRoot");
        startInfo.ArgumentList.Add(RuntimeRoot);
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("无法启动 AgentDock 管理脚本。");
        var standardOutput = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var standardError = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        var output = (await standardOutput).Trim();
        var error = (await standardError).Trim();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? output : error);
        }
    }

    private string ResolveManagementScript()
    {
        var installed = Path.Combine(RuntimeRoot, "installer", "manage-windows.ps1");
        if (File.Exists(installed))
        {
            return installed;
        }

        var overridePath = Environment.GetEnvironmentVariable("AGENTDOCK_MANAGE_SCRIPT");
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            return overridePath;
        }

        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            var candidate = Path.Combine(current.FullName, "scripts", "manage-windows.ps1");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            current = current.Parent;
        }

        return installed;
    }

    private static string ResolveRuntimeRoot()
    {
        var configured = Environment.GetEnvironmentVariable("AGENTDOCK_RUNTIME_DIR");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return Path.GetFullPath(configured);
        }

        var executableDirectory = new DirectoryInfo(AppContext.BaseDirectory);
        var baseDirectory = executableDirectory.FullName;
        if (File.Exists(Path.Combine(baseDirectory, "runtime.json")))
        {
            return baseDirectory;
        }

        var parent = executableDirectory.Parent?.FullName;
        if (!string.IsNullOrWhiteSpace(parent) && File.Exists(Path.Combine(parent, "runtime.json")))
        {
            return parent;
        }

        // 安装器会先启动 bin 中的托盘，再写入 runtime.json；此时仍应绑定当前安装目录。
        if (!string.IsNullOrWhiteSpace(parent) &&
            string.Equals(executableDirectory.Name, "bin", StringComparison.OrdinalIgnoreCase))
        {
            return parent;
        }

        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentDock");
    }

    private async Task<bool> IsHealthyAsync(string origin, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await _httpClient.GetAsync(origin.TrimEnd('/') + "/healthz", cancellationToken);
            return response.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    private static async Task<T?> ReadJsonAsync<T>(string path, CancellationToken cancellationToken)
    {
        try
        {
            await using var stream = File.OpenRead(path);
            return await JsonSerializer.DeserializeAsync<T>(stream, JsonOptions, cancellationToken);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            return default;
        }
    }

    private static string ReadFirstNonEmpty(params string[] paths)
    {
        foreach (var path in paths)
        {
            var value = ReadText(path);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }
        return "";
    }

    private static string ReadText(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllText(path, Encoding.UTF8).Trim() : "";
        }
        catch
        {
            return "";
        }
    }

    private static string ReadProtectedText(string path, string entropy)
    {
        try
        {
            var encoded = ReadText(path);
            if (string.IsNullOrWhiteSpace(encoded))
            {
                return "";
            }
            var protectedBytes = Convert.FromBase64String(encoded);
            var plainBytes = ProtectedData.Unprotect(protectedBytes, Encoding.UTF8.GetBytes(entropy), DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plainBytes);
        }
        catch
        {
            return "";
        }
    }

    private static bool IsProcessRunningAtPath(string processName, string expectedPath)
    {
        if (string.IsNullOrWhiteSpace(expectedPath))
        {
            return false;
        }
        try
        {
            var normalizedExpected = Path.GetFullPath(expectedPath);
            return Process.GetProcessesByName(processName).Any(process =>
            {
                using (process)
                {
                    try
                    {
                        var actual = process.MainModule?.FileName;
                        return !string.IsNullOrWhiteSpace(actual) &&
                               string.Equals(Path.GetFullPath(actual), normalizedExpected, StringComparison.OrdinalIgnoreCase);
                    }
                    catch
                    {
                        return false;
                    }
                }
            });
        }
        catch
        {
            return false;
        }
    }

    private static bool IsCoreStartupEnabled(RuntimeManifest manifest)
    {
        if (!string.Equals(manifest.PrivilegeMode, "elevated", StringComparison.OrdinalIgnoreCase))
        {
            return IsRunValuePresent(manifest.StartupValueName, "AgentDock");
        }

        try
        {
            var taskName = string.IsNullOrWhiteSpace(manifest.AgentDockTaskName) ? "AgentDock" : manifest.AgentDockTaskName;
            var startInfo = new ProcessStartInfo
            {
                FileName = "schtasks.exe",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            startInfo.ArgumentList.Add("/Query");
            startInfo.ArgumentList.Add("/TN");
            startInfo.ArgumentList.Add($"\\{taskName}");
            startInfo.ArgumentList.Add("/XML");

            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return false;
            }
            var taskXml = process.StandardOutput.ReadToEnd();
            process.WaitForExit(3000);
            if (process.ExitCode != 0 || string.IsNullOrWhiteSpace(taskXml))
            {
                return false;
            }

            var enabledElement = XDocument.Parse(taskXml)
                .Descendants()
                .FirstOrDefault(element => element.Name.LocalName == "Enabled");
            return enabledElement is not null && bool.TryParse(enabledElement.Value, out var enabled) && enabled;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsRunValuePresent(string configuredName, string fallbackName)
    {
        var name = string.IsNullOrWhiteSpace(configuredName) ? fallbackName : configuredName;
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false);
        return key?.GetValue(name) is string value && !string.IsNullOrWhiteSpace(value);
    }

    private static async Task<string> WriteSecretFileAsync(string value, CancellationToken cancellationToken)
    {
        var path = Path.Combine(Path.GetTempPath(), $"agentdock-secret-{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(path, value, new UTF8Encoding(false), cancellationToken);
        return path;
    }

    private static void DeleteSecretFile(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }
        try
        {
            File.Delete(path);
        }
        catch
        {
        }
    }

    private static void OpenDirectory(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }

    public void Dispose()
    {
        _httpClient.Dispose();
    }
}
