using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
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
    private DispatcherTimer? _trayStatusTimer;
    private RuntimeSnapshot? _traySnapshot;
    private bool _traySnapshotRefreshInProgress;
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
        _trayStatusTimer?.Stop();
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
        _trayMenu = new Forms.ContextMenuStrip();
        PopulateTrayMenu(_trayMenu, null);

        _notifyIcon = new Forms.NotifyIcon
        {
            Text = "AgentDock",
            Visible = true,
            Icon = LoadIcon(),
            ContextMenuStrip = _trayMenu
        };
        _notifyIcon.DoubleClick += (_, _) => ShowControlPanel();

        // 系统托盘菜单必须挂到 NotifyIcon 上，不能手动 Show；否则会产生任务栏图标且失焦后不自动关闭。
        _trayStatusTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(3)
        };
        _trayStatusTimer.Tick += async (_, _) => await RefreshTraySnapshotAsync();
        _trayStatusTimer.Start();
        _ = RefreshTraySnapshotAsync();
    }

    private async Task RefreshTraySnapshotAsync()
    {
        if (_traySnapshotRefreshInProgress)
        {
            return;
        }

        _traySnapshotRefreshInProgress = true;
        try
        {
            _traySnapshot = await Runtime.GetSnapshotAsync();
            if (_notifyIcon is not null)
            {
                _notifyIcon.Text = TruncateNotifyIconText($"AgentDock：{GetTrayStatusText(_traySnapshot)}");
            }
            if (_trayMenu is not null && !_trayMenu.Visible)
            {
                PopulateTrayMenu(_trayMenu, _traySnapshot);
            }
        }
        catch
        {
            if (_notifyIcon is not null)
            {
                _notifyIcon.Text = "AgentDock：状态不可用";
            }
            if (_trayMenu is not null && !_trayMenu.Visible)
            {
                PopulateTrayMenu(_trayMenu, null);
            }
        }
        finally
        {
            _traySnapshotRefreshInProgress = false;
        }
    }

    private void PopulateTrayMenu(Forms.ContextMenuStrip menu, RuntimeSnapshot? snapshot)
    {
        while (menu.Items.Count > 0)
        {
            var oldItem = menu.Items[0];
            menu.Items.RemoveAt(0);
            oldItem.Dispose();
        }

        var statusText = snapshot is null ? "正在读取状态…" : GetTrayStatusText(snapshot);
        var status = new Forms.ToolStripMenuItem($"AgentDock：{statusText}") { Enabled = false };
        menu.Items.Add(status);
        menu.Items.Add(new Forms.ToolStripSeparator());

        menu.Items.Add(CreateMenuItem("打开 AgentDock", (_, _) => ShowControlPanel()));
        menu.Items.Add(new Forms.ToolStripSeparator());

        if (snapshot?.CoreRunning == true)
        {
            menu.Items.Add(CreateMenuItem("停止 AgentDock", async (_, _) => await RunTrayActionAsync("stop")));
            menu.Items.Add(CreateMenuItem("重启 AgentDock", async (_, _) => await RunTrayActionAsync("restart")));
        }
        else
        {
            menu.Items.Add(CreateMenuItem(
                "启动 AgentDock",
                async (_, _) => await RunTrayActionAsync("start"),
                snapshot is not null));
        }
        menu.Items.Add(CreateMenuItem(
            "检查更新…",
            async (_, _) => await RunTrayActionAsync("update"),
            snapshot is not null));
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
            await RefreshTraySnapshotAsync();
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
        _trayStatusTimer?.Stop();
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
