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
            Icon = LoadIcon(),
            ContextMenuStrip = new Forms.ContextMenuStrip()
        };
        _notifyIcon.DoubleClick += (_, _) => ShowControlPanel();

        var open = new Forms.ToolStripMenuItem("打开控制面板");
        open.Click += (_, _) => ShowControlPanel();
        var start = new Forms.ToolStripMenuItem("启动 AgentDock");
        start.Click += async (_, _) => await RunTrayActionAsync("start");
        var restart = new Forms.ToolStripMenuItem("重启 AgentDock");
        restart.Click += async (_, _) => await RunTrayActionAsync("restart");
        var stop = new Forms.ToolStripMenuItem("停止 AgentDock");
        stop.Click += async (_, _) => await RunTrayActionAsync("stop");
        var exit = new Forms.ToolStripMenuItem("退出托盘");
        exit.Click += (_, _) => Dispatcher.Invoke(RequestExit);

        _notifyIcon.ContextMenuStrip.Items.Add(open);
        _notifyIcon.ContextMenuStrip.Items.Add(new Forms.ToolStripSeparator());
        _notifyIcon.ContextMenuStrip.Items.Add(start);
        _notifyIcon.ContextMenuStrip.Items.Add(restart);
        _notifyIcon.ContextMenuStrip.Items.Add(stop);
        _notifyIcon.ContextMenuStrip.Items.Add(new Forms.ToolStripSeparator());
        _notifyIcon.ContextMenuStrip.Items.Add(exit);
    }

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
