using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using Application = System.Windows.Application;
using Forms = System.Windows.Forms;

namespace AgentDock.ControlPanel;

public partial class App : System.Windows.Application
{
    private const string MutexName = "Local\\AgentDock.ControlPanel.Singleton";
    private const string ShowEventName = "Local\\AgentDock.ControlPanel.Show";
    private const string AppUserModelId = "com.uvwt.agentdock.controlpanel";

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    private Mutex? _singleInstanceMutex;
    private EventWaitHandle? _showEvent;
    private CancellationTokenSource? _showEventCancellation;
    private Forms.NotifyIcon? _notifyIcon;
    private Forms.ContextMenuStrip? _trayMenu;
    private bool _ownsSingleInstanceMutex;
    private bool _exitRequested;

    public RuntimeService Runtime { get; private set; } = null!;
    public MainWindow ControlPanelWindow { get; private set; } = null!;
    public bool ExitRequested => _exitRequested;

    protected override void OnStartup(StartupEventArgs e)
    {
        // 使用稳定的 AppUserModelID，避免升级后任务栏沿用旧版本的隐式图标缓存。
        _ = SetCurrentProcessExplicitAppUserModelID(AppUserModelId);

        _singleInstanceMutex = new Mutex(true, MutexName, out var createdNew);
        _ownsSingleInstanceMutex = createdNew;
        if (!createdNew)
        {
            using var existingEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
            existingEvent.Set();
            Shutdown();
            return;
        }

        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        Runtime = new RuntimeService();
        ControlPanelWindow = new MainWindow(Runtime);
        MainWindow = ControlPanelWindow;

        CreateNotifyIcon();
        StartShowEventListener();

        var background = e.Args.Any(arg => string.Equals(arg, "--background", StringComparison.OrdinalIgnoreCase));
        if (!background)
        {
            ShowControlPanel();
        }
    }

    public void ShowControlPanel()
    {
        Dispatcher.Invoke(() =>
        {
            if (!ControlPanelWindow.IsVisible)
            {
                ControlPanelWindow.Show();
            }

            if (ControlPanelWindow.WindowState == WindowState.Minimized)
            {
                ControlPanelWindow.WindowState = WindowState.Normal;
            }

            ControlPanelWindow.Activate();
            ControlPanelWindow.Topmost = true;
            ControlPanelWindow.Topmost = false;
            ControlPanelWindow.Focus();
            _ = ControlPanelWindow.RefreshAsync();
        });
    }

    public void RequestExit()
    {
        _exitRequested = true;
        _showEventCancellation?.Cancel();
        _trayMenu?.Dispose();
        _notifyIcon?.Dispose();
        ControlPanelWindow.Close();
        Shutdown();
    }

    private void StartShowEventListener()
    {
        _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        _showEventCancellation = new CancellationTokenSource();
        var token = _showEventCancellation.Token;
        _ = Task.Run(() =>
        {
            var handles = new WaitHandle[] { _showEvent, token.WaitHandle };
            while (!token.IsCancellationRequested)
            {
                var signaled = WaitHandle.WaitAny(handles);
                if (signaled == 0)
                {
                    Dispatcher.BeginInvoke(ShowControlPanel);
                }
            }
        }, token);
    }

    private void CreateNotifyIcon()
    {
        _notifyIcon = new Forms.NotifyIcon
        {
            Text = "AgentDock",
            Visible = true,
            Icon = LoadIcon()
        };
        _notifyIcon.DoubleClick += (_, _) => ShowControlPanel();
        _notifyIcon.MouseUp += NotifyIcon_MouseUp;
    }

    private async void NotifyIcon_MouseUp(object? sender, Forms.MouseEventArgs e)
    {
        if (e.Button != Forms.MouseButtons.Right)
        {
            return;
        }

        try
        {
            var snapshot = await Runtime.GetSnapshotAsync();
            _trayMenu?.Dispose();
            _trayMenu = BuildTrayMenu(snapshot);
            _trayMenu.Show(Forms.Cursor.Position);
        }
        catch (Exception ex)
        {
            _notifyIcon?.ShowBalloonTip(5000, "AgentDock", ex.Message, Forms.ToolTipIcon.Error);
        }
    }

    private Forms.ContextMenuStrip BuildTrayMenu(RuntimeSnapshot snapshot)
    {
        var menu = new Forms.ContextMenuStrip();
        var statusText = GetTrayStatusText(snapshot);
        var status = new Forms.ToolStripMenuItem($"AgentDock：{statusText}") { Enabled = false };
        menu.Items.Add(status);
        menu.Items.Add(new Forms.ToolStripSeparator());

        menu.Items.Add(CreateMenuItem("打开 AgentDock", (_, _) => ShowControlPanel()));
        menu.Items.Add(CreateMenuItem(
            "复制本地 MCP 地址",
            (_, _) => CopyTrayText(snapshot.LocalMcpUrl, "本地 MCP 地址已复制。"),
            !string.IsNullOrWhiteSpace(snapshot.LocalMcpUrl)));
        menu.Items.Add(CreateMenuItem(
            "复制公网 MCP 地址",
            (_, _) => CopyTrayText(snapshot.PublicMcpUrl, "公网 MCP 地址已复制。"),
            !string.IsNullOrWhiteSpace(snapshot.PublicMcpUrl)));
        menu.Items.Add(new Forms.ToolStripSeparator());

        if (snapshot.CoreRunning)
        {
            menu.Items.Add(CreateMenuItem("停止 AgentDock", async (_, _) => await RunTrayActionAsync("stop")));
            menu.Items.Add(CreateMenuItem("重启 AgentDock", async (_, _) => await RunTrayActionAsync("restart")));
        }
        else
        {
            menu.Items.Add(CreateMenuItem("启动 AgentDock", async (_, _) => await RunTrayActionAsync("start")));
        }
        menu.Items.Add(CreateMenuItem("检查更新…", async (_, _) => await RunTrayActionAsync("update")));
        menu.Items.Add(new Forms.ToolStripSeparator());

        menu.Items.Add(CreateMenuItem("打开日志目录", (_, _) => Runtime.OpenLogsDirectory()));
        menu.Items.Add(CreateMenuItem("打开配置目录", (_, _) => Runtime.OpenConfigDirectory()));
        menu.Items.Add(CreateMenuItem("打开使用文档", (_, _) => OpenDocumentation()));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(CreateMenuItem("退出菜单栏", (_, _) => Dispatcher.Invoke(RequestExit)));

        if (_notifyIcon is not null)
        {
            _notifyIcon.Text = TruncateNotifyIconText($"AgentDock：{statusText}");
        }
        return menu;
    }

    private static Forms.ToolStripMenuItem CreateMenuItem(string text, EventHandler onClick, bool enabled = true)
    {
        var item = new Forms.ToolStripMenuItem(text) { Enabled = enabled };
        item.Click += onClick;
        return item;
    }

    private static string GetTrayStatusText(RuntimeSnapshot snapshot)
    {
        if (snapshot.Healthy)
        {
            var version = string.IsNullOrWhiteSpace(snapshot.Manifest.Version) ? "未知版本" : snapshot.Manifest.Version;
            return $"运行正常 · {version}";
        }
        return snapshot.CoreRunning ? "服务异常" : "已停止";
    }

    private void CopyTrayText(string value, string successMessage)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return;
            }
            Forms.Clipboard.SetText(value);
            _notifyIcon?.ShowBalloonTip(3000, "AgentDock", successMessage, Forms.ToolTipIcon.Info);
        }
        catch (Exception ex)
        {
            _notifyIcon?.ShowBalloonTip(5000, "AgentDock", ex.Message, Forms.ToolTipIcon.Error);
        }
    }

    private static void OpenDocumentation()
    {
        Process.Start(new ProcessStartInfo("https://github.com/uvwt/agentdock#readme")
        {
            UseShellExecute = true
        });
    }

    private static string TruncateNotifyIconText(string value) => value.Length <= 63 ? value : value[..63];

    private async Task RunTrayActionAsync(string action)
    {
        try
        {
            await Runtime.RunActionAsync(action);
            var refreshTask = await Dispatcher.InvokeAsync(ControlPanelWindow.RefreshAsync);
            await refreshTask;
        }
        catch (Exception ex)
        {
            _notifyIcon?.ShowBalloonTip(5000, "AgentDock", ex.Message, Forms.ToolTipIcon.Error);
        }
    }

    private static Icon LoadIcon()
    {
        var adjacentIcon = Path.Combine(AppContext.BaseDirectory, "agentdock.ico");
        if (File.Exists(adjacentIcon))
        {
            return new Icon(adjacentIcon);
        }

        return Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _showEventCancellation?.Cancel();
        _showEvent?.Dispose();
        _showEventCancellation?.Dispose();
        _trayMenu?.Dispose();
        _notifyIcon?.Dispose();
        if (_ownsSingleInstanceMutex)
        {
            _singleInstanceMutex?.ReleaseMutex();
        }
        _singleInstanceMutex?.Dispose();
        Runtime?.Dispose();
        base.OnExit(e);
    }
}
