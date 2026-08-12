using System.ComponentModel;
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

    public RuntimeService(string? runtimeRoot = null)
    {
        RuntimeRoot = string.IsNullOrWhiteSpace(runtimeRoot)
            ? ResolveRuntimeRoot()
            : Path.GetFullPath(runtimeRoot);
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
        settings.AcpAgent = NormalizeAcpAgent(settings.AcpAgent);
        settings.AcpCommand ??= "";
        settings.AcpArgs ??= [];
        settings.AcpAllowedRoots ??= [];

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
        var binaryPath = ResolveCoreBinaryPath(manifest);
        var health = await ReadHealthAsync(localOrigin, cancellationToken);
        var version = health.Version;
        if (string.IsNullOrWhiteSpace(version))
        {
            version = await ReadCoreVersionAsync(binaryPath, cancellationToken);
        }
        var coreRunning = health.Healthy || IsProcessRunningAtPath("agentdock", binaryPath);
        var cloudflaredRunning = IsProcessRunningAtPath("cloudflared", manifest.CloudflaredBinary);
        var tunnelMode = ReadText(Path.Combine(RuntimeRoot, "cloudflared-mode.txt"));
        if (string.IsNullOrWhiteSpace(tunnelMode))
        {
            tunnelMode = string.IsNullOrWhiteSpace(manifest.TunnelMode) ? "none" : manifest.TunnelMode;
        }

        return new RuntimeSnapshot(
            manifest,
            settings,
            version,
            coreRunning,
            health.Healthy,
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

    public AcpAdapterResolution ResolveAcpAdapter(
        string agent,
        string configuredCommand = "",
        IReadOnlyList<string>? configuredArguments = null) =>
        AcpAdapterResolver.Resolve(agent, RuntimeRoot, configuredCommand, configuredArguments);

    public async Task RunActionAsync(string action, CancellationToken cancellationToken = default)
    {
        switch (action)
        {
            case "start":
                await RunCoreActionAsync("start", cancellationToken);
                await RunTunnelActionAsync("start", cancellationToken);
                break;
            case "stop":
                await RunTunnelActionAsync("stop", cancellationToken);
                await RunCoreActionAsync("stop", cancellationToken);
                break;
            case "restart":
                var mode = ReadText(Path.Combine(RuntimeRoot, "cloudflared-mode.txt")).ToLowerInvariant();
                if (mode == "quick")
                {
                    // Quick Tunnel 重建会清理旧地址、重启核心、等待新地址并再次应用 OAuth Origin。
                    await RunTunnelActionAsync("regenerate", cancellationToken);
                }
                else
                {
                    await RunTunnelActionAsync("stop", cancellationToken);
                    await RunCoreActionAsync("restart", cancellationToken);
                    await RunTunnelActionAsync("start", cancellationToken);
                }
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(action), action, "不支持的运行时操作。");
        }
    }

    public async Task<UpdateCheckResult> CheckForUpdatesAsync(CancellationToken cancellationToken = default)
    {
        var binaryPath = await ResolveCoreBinaryAsync(cancellationToken);
        var startInfo = CreateRedirectedProcessStartInfo(binaryPath);
        startInfo.ArgumentList.Add("update");
        startInfo.ArgumentList.Add("--check");
        var output = await RunProcessAsync(startInfo, cancellationToken);
        try
        {
            return JsonSerializer.Deserialize<UpdateCheckResult>(output, JsonOptions)
                ?? throw new JsonException("更新检查结果为空");
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException("无法解析 AgentDock 更新检查结果。", ex);
        }
    }

    public async Task<string> RunUpdateAsync(
        IProgress<UpdateProgress>? progress,
        CancellationToken cancellationToken = default)
    {
        var binaryPath = await ResolveCoreBinaryAsync(cancellationToken);
        var startInfo = CreateRedirectedProcessStartInfo(binaryPath);
        startInfo.ArgumentList.Add("update");
        return await RunUpdateProcessAsync(startInfo, progress, cancellationToken);
    }

    public async Task SetTunnelModeAsync(
        string mode,
        string serverUrl,
        string tunnelToken,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string>
        {
            "configure",
            "--mode", mode,
            "--server-url", serverUrl ?? ""
        };
        string? secretFile = null;
        try
        {
            if (!string.IsNullOrWhiteSpace(tunnelToken))
            {
                secretFile = await WriteSecretFileAsync(tunnelToken, cancellationToken);
                arguments.AddRange(["--token-file", secretFile]);
            }

            await RunNativeAgentDockAsync("tunnel", arguments, cancellationToken);
        }
        finally
        {
            DeleteSecretFile(secretFile);
        }
    }

    public Task RegenerateQuickTunnelAsync(CancellationToken cancellationToken = default) =>
        RunTunnelActionAsync("regenerate", cancellationToken);

    public async Task SaveSettingsAsync(
        ControlPanelSettings settings,
        string nexusToken,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string>
        {
            "update",
            "--port", settings.Port.ToString(),
            "--log-level", settings.LogLevel,
            "--nexus-endpoint", settings.NexusEndpoint ?? "",
            $"--browser-enabled={settings.BrowserEnabled.ToString().ToLowerInvariant()}",
            $"--acp-enabled={settings.AcpEnabled.ToString().ToLowerInvariant()}",
            "--acp-agent", NormalizeAcpAgent(settings.AcpAgent),
            "--acp-allowed-roots-json", JsonSerializer.Serialize(settings.AcpAllowedRoots ?? [], JsonOptions)
        };
        string? secretFile = null;
        try
        {
            if (!string.IsNullOrWhiteSpace(nexusToken))
            {
                secretFile = await WriteSecretFileAsync(nexusToken, cancellationToken);
                arguments.AddRange(["--nexus-token-file", secretFile]);
            }

            await RunNativeAgentDockAsync("config", arguments, cancellationToken);
        }
        finally
        {
            DeleteSecretFile(secretFile);
        }
    }

    public Task SetStartupAsync(string component, bool enabled, CancellationToken cancellationToken = default)
    {
        if (component is not ("core" or "tray"))
        {
            throw new ArgumentOutOfRangeException(nameof(component), component, "不支持的开机启动组件。");
        }
        return RunNativeAgentDockAsync(
            "service",
            ["autostart", "--component", component, "--enabled", enabled ? "true" : "false"],
            cancellationToken);
    }

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

    private async Task<string> ResolveCoreBinaryAsync(CancellationToken cancellationToken)
    {
        var manifest = await ReadJsonAsync<RuntimeManifest>(ManifestPath, cancellationToken);
        var binaryPath = ResolveCoreBinaryPath(manifest);
        if (!File.Exists(binaryPath))
        {
            throw new FileNotFoundException("找不到 AgentDock 核心程序，请运行 Setup.exe 修复安装。", binaryPath);
        }
        return binaryPath;
    }

    private string ResolveCoreBinaryPath(RuntimeManifest? manifest)
    {
        var binaryPath = manifest?.BinaryPath;
        return string.IsNullOrWhiteSpace(binaryPath)
            ? Path.Combine(RuntimeRoot, "bin", "agentdock.exe")
            : binaryPath;
    }

    internal async Task<int> RunElevatedCoreTaskAsync(CancellationToken cancellationToken = default)
    {
        var manifest = await ReadJsonAsync<RuntimeManifest>(ManifestPath, cancellationToken) ?? new RuntimeManifest();
        var binaryPath = ResolveCoreBinaryPath(manifest);
        if (!File.Exists(binaryPath))
        {
            throw new FileNotFoundException("找不到 AgentDock 核心程序。", binaryPath);
        }

        Directory.CreateDirectory(LogsDirectory);
        var workingDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AgentDock");
        Directory.CreateDirectory(workingDirectory);

        var startInfo = new ProcessStartInfo
        {
            FileName = binaryPath,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("service");
        startInfo.ArgumentList.Add("launch-core");
        startInfo.ArgumentList.Add("--runtime-root");
        startInfo.ArgumentList.Add(RuntimeRoot);

        // Highest 计划任务运行 WinExe 托管进程，再由它无控制台启动核心并持续等待。
        // 这样 Task Scheduler 仍掌握整个进程树，/End 可以一次结束托管进程与核心进程。
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("无法启动 AgentDock 核心程序。");
        await using var stdout = new FileStream(
            Path.Combine(LogsDirectory, "agentdock.out.log"),
            FileMode.Append,
            FileAccess.Write,
            FileShare.ReadWrite,
            4096,
            useAsync: true);
        await using var stderr = new FileStream(
            Path.Combine(LogsDirectory, "agentdock.err.log"),
            FileMode.Append,
            FileAccess.Write,
            FileShare.ReadWrite,
            4096,
            useAsync: true);

        var stdoutCopy = process.StandardOutput.BaseStream.CopyToAsync(stdout, cancellationToken);
        var stderrCopy = process.StandardError.BaseStream.CopyToAsync(stderr, cancellationToken);
        await Task.WhenAll(process.WaitForExitAsync(cancellationToken), stdoutCopy, stderrCopy);
        return process.ExitCode;
    }

    internal Task RunCoreStartupAsync(CancellationToken cancellationToken = default) =>
        RunNativeAgentDockAsync("service", ["start"], cancellationToken, allowElevation: false);

    internal Task RunTunnelStartupAsync(CancellationToken cancellationToken = default) =>
        RunNativeAgentDockAsync("tunnel", ["start"], cancellationToken, allowElevation: false);

    internal Task RunCoreActionAsync(string action, CancellationToken cancellationToken = default)
    {
        if (action is not ("start" or "stop" or "restart"))
        {
            throw new ArgumentOutOfRangeException(nameof(action), action, "不支持的核心服务操作。");
        }
        return RunNativeAgentDockAsync("service", [action], cancellationToken);
    }

    internal Task RunTunnelActionAsync(string action, CancellationToken cancellationToken = default)
    {
        if (action is not ("start" or "stop" or "restart" or "regenerate"))
        {
            throw new ArgumentOutOfRangeException(nameof(action), action, "不支持的 Tunnel 操作。");
        }
        return RunNativeAgentDockAsync("tunnel", [action], cancellationToken);
    }

    private async Task RunNativeAgentDockAsync(
        string command,
        IReadOnlyCollection<string> arguments,
        CancellationToken cancellationToken,
        bool allowElevation = true)
    {
        var manifest = await ReadJsonAsync<RuntimeManifest>(ManifestPath, cancellationToken) ?? new RuntimeManifest();
        var binaryPath = await ResolveCoreBinaryAsync(cancellationToken);
        var commandArguments = new List<string> { command };
        commandArguments.AddRange(arguments);
        commandArguments.AddRange(["--runtime-root", RuntimeRoot]);

        var startInfo = CreateRedirectedProcessStartInfo(binaryPath);
        foreach (var argument in commandArguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        try
        {
            _ = await RunProcessAsync(startInfo, cancellationToken);
        }
        catch (InvalidOperationException) when (
            allowElevation &&
            string.Equals(manifest.PrivilegeMode, "elevated", StringComparison.OrdinalIgnoreCase))
        {
            // 最高权限计划任务启动的核心进程不能保证允许普通托盘终止。
            // 原生命令真正失败时才请求 UAC；命令设计为幂等，可安全重试已完成的前置状态变更。
            await RunElevatedProcessAsync(binaryPath, commandArguments, cancellationToken);
        }
    }

    private static async Task RunElevatedProcessAsync(
        string binaryPath,
        IReadOnlyCollection<string> arguments,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = binaryPath,
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("无法启动 AgentDock 管理程序。");
        await process.WaitForExitAsync(cancellationToken);
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"AgentDock 管理程序执行失败，退出码：{process.ExitCode}。");
        }
    }

    private static ProcessStartInfo CreateRedirectedProcessStartInfo(string fileName)
    {
        var utf8 = new UTF8Encoding(false);
        return new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = utf8,
            StandardErrorEncoding = utf8
        };
    }

    private static async Task<string> RunProcessAsync(ProcessStartInfo startInfo, CancellationToken cancellationToken)
    {
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException($"无法启动 {startInfo.FileName}。");
        var standardOutput = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var standardError = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        var output = (await standardOutput).Trim();
        var error = (await standardError).Trim();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? output : error);
        }

        if (string.IsNullOrWhiteSpace(output))
        {
            return error;
        }
        return string.IsNullOrWhiteSpace(error) ? output : output + Environment.NewLine + error;
    }

    private static async Task<string> RunUpdateProcessAsync(
        ProcessStartInfo startInfo,
        IProgress<UpdateProgress>? progress,
        CancellationToken cancellationToken)
    {
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException($"无法启动 {startInfo.FileName}。");
        var output = new StringBuilder();
        var error = new StringBuilder();
        var outputTask = ReadProcessLinesAsync(process.StandardOutput, output, progress, cancellationToken);
        var errorTask = ReadProcessLinesAsync(process.StandardError, error, null, cancellationToken);

        await Task.WhenAll(process.WaitForExitAsync(cancellationToken), outputTask, errorTask);
        var outputText = output.ToString().Trim();
        var errorText = error.ToString().Trim();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(errorText) ? outputText : errorText);
        }

        var result = string.IsNullOrWhiteSpace(outputText)
            ? errorText
            : string.IsNullOrWhiteSpace(errorText) ? outputText : outputText + Environment.NewLine + errorText;
        progress?.Report(new UpdateProgress(100, LastNonEmptyLine(result, "更新完成。")));
        return result;
    }

    private static async Task ReadProcessLinesAsync(
        StreamReader reader,
        StringBuilder buffer,
        IProgress<UpdateProgress>? progress,
        CancellationToken cancellationToken)
    {
        while (await reader.ReadLineAsync(cancellationToken) is { } line)
        {
            buffer.AppendLine(line);
            if (!string.IsNullOrWhiteSpace(line))
            {
                progress?.Report(MapUpdateProgress(line));
            }
        }
    }

    private static UpdateProgress MapUpdateProgress(string line)
    {
        var message = line.Trim();
        var percentage = message switch
        {
            var value when value.Contains("正在下载", StringComparison.Ordinal) => 20,
            var value when value.Contains("文件校验通过", StringComparison.Ordinal) => 50,
            var value when value.Contains("正在备份并安装", StringComparison.Ordinal) => 70,
            var value when value.Contains("交给辅助进程", StringComparison.Ordinal) => 80,
            var value when value.Contains("正在更新官方核心 Skill", StringComparison.Ordinal) => 90,
            var value when value.Contains("更新完成", StringComparison.Ordinal) => 100,
            var value when value.Contains("当前已是最新版本", StringComparison.Ordinal) => 100,
            _ => 10
        };
        return new UpdateProgress(percentage, message);
    }

    private static string LastNonEmptyLine(string value, string fallback)
    {
        var line = value
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .LastOrDefault();
        return string.IsNullOrWhiteSpace(line) ? fallback : line;
    }

    private static string NormalizeAcpAgent(string? value)
    {
        return value?.Trim().ToLowerInvariant() switch
        {
            "claude" => "claude",
            "grok" => "grok",
            _ => "codex"
        };
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

    private async Task<(bool Healthy, string Version)> ReadHealthAsync(string origin, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await _httpClient.GetAsync(origin.TrimEnd('/') + "/healthz", cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return (false, "");
            }

            try
            {
                var body = await response.Content.ReadAsStringAsync(cancellationToken);
                var health = JsonSerializer.Deserialize<CoreVersionInfo>(body, JsonOptions);
                return (true, health?.Version?.Trim() ?? "");
            }
            catch (Exception ex) when (ex is IOException or JsonException)
            {
                // 健康端点已返回成功时，版本解析失败不应把服务误判为离线；随后再回退读取本地二进制 BuildInfo。
                return (true, "");
            }
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return (false, "");
        }
        catch (HttpRequestException)
        {
            return (false, "");
        }
    }

    private async Task<string> ReadCoreVersionAsync(string binaryPath, CancellationToken cancellationToken)
    {
        if (!File.Exists(binaryPath))
        {
            return "";
        }

        var startInfo = CreateRedirectedProcessStartInfo(binaryPath);
        startInfo.ArgumentList.Add("version");
        startInfo.ArgumentList.Add("--json");
        try
        {
            var output = await RunProcessAsync(startInfo, cancellationToken);
            return JsonSerializer.Deserialize<CoreVersionInfo>(output, JsonOptions)?.Version?.Trim() ?? "";
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or Win32Exception or JsonException)
        {
            return "";
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
