using Microsoft.UI.Xaml;
using Microsoft.Extensions.DependencyInjection;
using VoiceLab.Infrastructure.Services;
using VoiceLab.Infrastructure.Storage;
using VoiceLab.Infrastructure.Audio;
using VoiceLab.Infrastructure.Hotkeys;
using VoiceLab.App.Services;

namespace VoiceLab.App;

public partial class App : Application
{
    private static System.Threading.Mutex? s_instanceMutex;
    private static int s_onboardingCompletionSyncing;
    private readonly ServiceProvider _services;

    public App()
    {
        s_instanceMutex = new System.Threading.Mutex(true, @"Local\VoiceLab.Echo.WinUI3", out var createdNew);
        if (!createdNew)
        {
            var existing = FindWindow(null, "VoiceLab Echo");
            if (existing != IntPtr.Zero) { ShowWindow(existing, 9); SetForegroundWindow(existing); }
            Environment.Exit(0);
        }
        StartupTrace("App constructor");
        InitializeComponent();
        StartupTrace("App resources initialized");
        var services = new ServiceCollection()
            .AddSingleton<JsonDataStore>()
            .AddSingleton<ISecureStorageService, VoiceLab.App.Services.CredentialVaultStorageService>()
            .AddSingleton<INotesService, NotesService>()
            .AddSingleton<IVocabularyService, VocabularyService>()
            .AddSingleton<ISnippetsService, SnippetsService>()
            .AddSingleton<IStatisticsService, StatisticsService>()
            .AddSingleton<ISettingsService, SettingsService>();
        services.AddSingleton<IAudioCaptureService, AudioCaptureService>();
        services.AddSingleton<IGlobalHotkeyService, GlobalHotkeyService>();
        services.AddSingleton<ITrayService, TrayService>();
        services.AddSingleton<IStartupService, StartupService>();
        services.AddSingleton<IRecordingOverlayService, RecordingOverlayService>();
        services.AddSingleton<IRecordingCoordinator, VoiceLab.App.Services.RecordingCoordinator>();
        services.AddHttpClient();
        services.AddSingleton<IAuthenticationService>(provider => new AuthenticationService(
            provider.GetRequiredService<IHttpClientFactory>().CreateClient(),
            provider.GetRequiredService<ISecureStorageService>()));
        services.AddHttpClient("transcriptions", client =>
        {
            // The synchronous desktop STT endpoint can spend up to 14 minutes processing.
            client.Timeout = TimeSpan.FromMinutes(15);
            client.MaxResponseContentBufferSize = 8 * 1024 * 1024;
        }).ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
        services.AddSingleton<ITranscriptionService>(provider => new TranscriptionService(
            provider.GetRequiredService<JsonDataStore>(),
            provider.GetRequiredService<IAuthenticationService>(),
            provider.GetRequiredService<ISettingsService>(),
            provider.GetRequiredService<IVocabularyService>(),
            provider.GetRequiredService<ISnippetsService>(),
            provider.GetRequiredService<IHttpClientFactory>().CreateClient("transcriptions")));
        services.AddHttpClient<IOnboardingProfileService, OnboardingProfileService>(client => client.Timeout = TimeSpan.FromSeconds(20));
        services.AddHttpClient<IOnboardingContextService, OnboardingContextService>(client => client.Timeout = TimeSpan.FromSeconds(20));
        services.AddHttpClient<ICloudUsageService, CloudUsageService>(client => client.Timeout = TimeSpan.FromSeconds(20));
        services.AddHttpClient<IAccountHistoryService, AccountHistoryService>(client => client.Timeout = TimeSpan.FromSeconds(20));
        services.AddHttpClient<IAccountNotesService, AccountNotesService>(client => client.Timeout = TimeSpan.FromSeconds(20));
        services.AddHttpClient<IAccountNotificationService, AccountNotificationService>(client => client.Timeout = TimeSpan.FromSeconds(20));
        services.AddHttpClient<IAccountUsageSyncService, AccountUsageSyncService>(client => client.Timeout = TimeSpan.FromSeconds(8));
        services.AddHttpClient<IAccountStatisticsService, AccountStatisticsService>(client => client.Timeout = TimeSpan.FromSeconds(20));
        _services = services.BuildServiceProvider();
        _services.GetRequiredService<IAudioCaptureService>().SetDevice(
            _services.GetRequiredService<ISettingsService>().GetSetting("MicrophoneIndex", 0));
        StartupTrace("Services initialized");
    }

    public static IServiceProvider Services => ((App)Current)._services;

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        StartupTrace("OnLaunched");
        try
        {
        m_window = new MainWindow();
        m_window.Activated += (_, eventArgs) =>
        {
            if (eventArgs.WindowActivationState != WindowActivationState.Deactivated
                && m_window.Content is VoiceLab.App.Views.ShellPage)
                _ = SyncPendingOnboardingCompletionAsync();
        };
        StartupTrace("Main window created");
        MainWindow = m_window;
        m_window.Content = new Microsoft.UI.Xaml.Controls.Grid
        {
            Background = (Microsoft.UI.Xaml.Media.Brush)Resources["OnbBgBrush"],
            Children =
            {
                new Microsoft.UI.Xaml.Controls.StackPanel
                {
                    Spacing = 16,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    Children =
                    {
                        new Microsoft.UI.Xaml.Controls.ProgressRing { IsActive = true, Width = 36, Height = 36 },
                        new Microsoft.UI.Xaml.Controls.TextBlock { Text = "Opening Echo…", HorizontalAlignment = HorizontalAlignment.Center }
                    }
                }
            }
        };
        m_window.Activate();
        var settings = Services.GetRequiredService<ISettingsService>();
        if (settings.GetSetting("OnboardingFlowVersion", 1) < 2)
        {
            var previousStep = settings.GetSetting("OnboardingStep", 0);
            var migratedStep = previousStep switch
            {
                1 => 5, 2 => 6, 3 => 7, 4 => 1, 5 => 2, 6 => 3, 7 => 4,
                _ => Math.Clamp(previousStep, 0, 14)
            };
            settings.SaveSetting("OnboardingStep", migratedStep);
            settings.SaveSetting("OnboardingFlowVersion", 2);
        }
        if (settings.GetSetting("OnboardingFlowVersion", 2) < 3)
        {
            // Older setup did not send the Mac app's six-question context. Resume there.
            var oldStep = settings.GetSetting("OnboardingStep", 0);
            if (oldStep >= 6) settings.SaveSetting("OnboardingStep", 6);
            settings.SaveSetting("OnboardingFlowVersion", 3);
        }
        if (settings.GetSetting("OnboardingFlowVersion", 3) < 4)
        {
            // The Mac-style Uzbek alphabet choice now sits before dictation language.
            var oldStep = settings.GetSetting("OnboardingStep", 0);
            if (oldStep >= 5) settings.SaveSetting("OnboardingStep", oldStep + 1);
            settings.SaveSetting("OnboardingFlowVersion", 4);
        }
        var onboardingCompleted = settings.GetSetting("OnboardingCompleted", false);
        var authService = Services.GetRequiredService<IAuthenticationService>();
        if (!onboardingCompleted)
        {
            var resumeStep = settings.GetSetting("OnboardingStep", 0);
            if (resumeStep >= 7)
            {
                if (await authService.IsAuthenticatedAsync())
                {
                    var userId = (await authService.GetCurrentUserAsync())?.Id;
                    SetAccountContext(userId);
                    if (resumeStep >= 9 && (userId is null || !settings
                        .GetSetting("PracticeCompletedAccountIds", new List<string>()).Contains(userId)))
                        resumeStep = 8;
                }
                else resumeStep = 6;
            }
            m_window.Content = new VoiceLab.App.Views.OnboardingShellPage(resumeStep);
        }
        else if (await authService.IsAuthenticatedAsync())
        {
            var userId = (await authService.GetCurrentUserAsync())?.Id;
            SetAccountContext(userId);
            if (userId == settings.GetSetting("OnboardingCompletedUserId", ""))
            {
                ShowShell();
            }
            else
            {
                settings.SaveSetting("OnboardingCompleted", false);
                m_window.Content = new VoiceLab.App.Views.OnboardingShellPage(7);
            }
        }
        else
        {
            m_window.Content = new VoiceLab.App.Views.Onboarding.SignInStepPage();
        }
        ApplyTheme();
        m_window.Activate();
        RegisterConfiguredHotkey();
        StartupTrace("Main window activated");
        }
        catch (Exception ex)
        {
            StartupTrace($"Startup failed: {ex}");
            if (m_window is null) throw;
            m_window.Content = new Microsoft.UI.Xaml.Controls.Grid
            {
                Padding = new Thickness(36),
                Children =
                {
                    new Microsoft.UI.Xaml.Controls.TextBlock
                    {
                        Text = $"Echo could not start: {ex.Message}",
                        TextWrapping = TextWrapping.Wrap,
                        FontSize = 18,
                        VerticalAlignment = VerticalAlignment.Center
                    }
                }
            };
            m_window.Activate();
        }
    }

    private static void StartupTrace(string message)
    {
        try { System.IO.File.AppendAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "VoiceLabEchoStartup.log"), $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}"); }
        catch { }
    }

    private Window? m_window;
    public static Window? MainWindow { get; private set; }

    public static void ShowShell()
    {
        var app = (App)Current;
        app.m_window!.Content = new VoiceLab.App.Views.ShellPage();
        ApplyTheme();
        var tray = Services.GetRequiredService<ITrayService>();
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(app.m_window);
        try { tray.Attach(handle); }
        catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Tray behavior unavailable: {ex.Message}"); }
        Services.GetRequiredService<IRecordingOverlayService>().Attach();
        if (!RegisterConfiguredHotkey() && app.m_window.Content is VoiceLab.App.Views.ShellPage shell)
            shell.ShowHotkeyError();
        _ = SyncPendingOnboardingCompletionAsync();
    }

    private static async Task SyncPendingOnboardingCompletionAsync()
    {
        if (System.Threading.Interlocked.Exchange(ref s_onboardingCompletionSyncing, 1) != 0) return;
        try
        {
            var auth = Services.GetRequiredService<IAuthenticationService>();
            var ownerId = (await auth.GetCurrentUserAsync())?.Id;
            if (string.IsNullOrWhiteSpace(ownerId)) return;
            var settings = Services.GetRequiredService<ISettingsService>();
            var pending = settings.GetSetting("OnboardingCompletionPendingAccountIds", new List<string>());
            if (!pending.Contains(ownerId, StringComparer.Ordinal)) return;
            await Services.GetRequiredService<IOnboardingContextService>().CompleteForAccountAsync(ownerId);
            if ((await auth.GetCurrentUserAsync())?.Id != ownerId) return;
            pending = settings.GetSetting("OnboardingCompletionPendingAccountIds", new List<string>());
            if (pending.RemoveAll(id => id == ownerId) > 0)
                settings.SaveSetting("OnboardingCompletionPendingAccountIds", pending);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Onboarding completion sync will retry: {ex.Message}");
        }
        finally { System.Threading.Interlocked.Exchange(ref s_onboardingCompletionSyncing, 0); }
    }

    public static void ApplyTheme()
    {
        if (MainWindow?.Content is not FrameworkElement root) return;
        var value = Services.GetRequiredService<ISettingsService>().GetSetting("Theme", "system");
        root.RequestedTheme = value switch
        {
            "light" => ElementTheme.Light,
            "dark" => ElementTheme.Dark,
            _ => ElementTheme.Default
        };
        var targetTheme = value switch
        {
            "light" => ElementTheme.Light,
            "dark" => ElementTheme.Dark,
            _ => root.ActualTheme
        };
        UpdateThemePalette(targetTheme);
        Services.GetRequiredService<IRecordingOverlayService>().ApplyTheme(targetTheme);
    }

    public static void UpdateThemePalette(ElementTheme theme)
    {
        var dark = theme == ElementTheme.Dark;
        var accent = GetAccentColor(dark);
        SetBrush("EchoAccentBrush", (uint)(accent.A << 24 | accent.R << 16 | accent.G << 8 | accent.B));
        SetBrush("EchoPageBrush", dark ? 0xFF1A1A1A : 0xFFFCFCFB);
        SetBrush("EchoCardBrush", dark ? 0xFF202020 : 0xFFF5F4F0);
        SetBrush("EchoBorderBrush", dark ? 0xFF3B3B3A : 0xFFE2E1DD);
        SetBrush("EchoSelectionBrush", dark ? 0xFF30302F : 0xFFEEEBDC);
        SetBrush("BackgroundBrush", dark ? 0xFF1A1A1A : 0xFFFCFCFB);
        SetBrush("SurfaceBrush", dark ? 0xFF202020 : 0xFFF5F4F0);
        SetBrush("BorderBrush", dark ? 0xFF3B3B3A : 0xFFE2E1DD);
        SetBrush("TextPrimaryBrush", dark ? 0xFFE9E8E1 : 0xFF1A1A1A);
        SetBrush("TextSecondaryBrush", dark ? 0xFFA8A8A4 : 0xFF777774);
        SetBrush("PrimaryBrush", dark ? 0xFFE9E8E1 : 0xFF1A1A1A);
        SetBrush("PrimaryForegroundBrush", dark ? 0xFF1A1A1A : 0xFFFFFFFF);
        SetBrush("PrimaryHoverBrush", dark ? 0xFFD8D7D0 : 0xFF333333);
        SetBrush("PrimaryPressedBrush", dark ? 0xFFC8C7C0 : 0xFF444444);
        SetBrush("OnbAccentBrush", dark ? 0xFFE9E8E1 : 0xFF1A1A1A);
        SetBrush("OnbAccentSoftBrush", dark ? 0x1AE9E8E1u : 0x1A1A1A1Au);
        SetBrush("OnbInkBrush", dark ? 0xFFE9E8E1 : 0xFF1A1A1A);
        SetBrush("OnbInkMutedBrush", dark ? 0xFFA8A8A4 : 0xFF777774);
        SetBrush("OnbBgBrush", dark ? 0xFF1A1A1A : 0xFFFCFCFB);
        SetBrush("OnbPanelBrush", dark ? 0xFF30302F : 0xFFEEEBDC);
        SetBrush("OnbCardBrush", dark ? 0xFF202020 : 0xFFF5F4F0);
        SetBrush("OnbCardBorderBrush", dark ? 0xFF3B3B3A : 0xFFE2E1DD);
        SetBrush("OnbKeyBrush", dark ? 0xFF202020 : 0xFFFCFCFB);
        SetBrush("OnbKeyBorderBrush", dark ? 0xFF777774 : 0xFFCFCFCD);
    }

    public static Windows.UI.Color GetAccentColor(bool dark)
    {
        var choice = Services.GetRequiredService<ISettingsService>().GetSetting("AccentColor", "voicelab");
        if (choice == "system" && Current.Resources.TryGetValue("SystemAccentColor", out var systemColor)
            && systemColor is Windows.UI.Color color) return color;
        var rgb = choice switch
        {
            "blue" => 0xFF0078D4u,
            "purple" => 0xFF8A54A2u,
            "pink" => 0xFFE5599Bu,
            "red" => 0xFFD13438u,
            "orange" => 0xFFE88028u,
            "yellow" => 0xFFB88700u,
            "green" => 0xFF17875Fu,
            "graphite" => dark ? 0xFFC4C4C4u : 0xFF6B6B6Bu,
            _ => dark ? 0xFF7394FFu : 0xFF3D63F2u
        };
        return Windows.UI.Color.FromArgb((byte)(rgb >> 24), (byte)(rgb >> 16),
            (byte)(rgb >> 8), (byte)rgb);
    }

    private static void SetBrush(string key, uint argb)
    {
        if (Current.Resources[key] is not Microsoft.UI.Xaml.Media.SolidColorBrush brush) return;
        brush.Color = Windows.UI.Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16),
            (byte)(argb >> 8), (byte)argb);
    }

    public static bool RegisterConfiguredHotkey(bool force = false)
    {
        var app = (App)Current;
        if (app.m_window is null) return false;
        var hotkeys = Services.GetRequiredService<IGlobalHotkeyService>();
        if (force && hotkeys.IsRegistered) hotkeys.UnregisterHotkey();
        if (!hotkeys.IsRegistered)
        {
            var handle = WinRT.Interop.WindowNative.GetWindowHandle(app.m_window);
            var shortcut = Services.GetRequiredService<ISettingsService>().GetSetting("Shortcut", "win-alt-space");
            var modifiers = shortcut switch
            {
                "ctrl-shift-space" => ModifierKeys.Control | ModifierKeys.Shift,
                "ctrl-alt-space" => ModifierKeys.Control | ModifierKeys.Alt,
                _ => ModifierKeys.Win | ModifierKeys.Alt
            };
            try { hotkeys.RegisterHotkey(handle, modifiers, VirtualKey.Space); }
            catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Global shortcut unavailable: {ex.Message}"); return false; }
        }
        return true;
    }

    public static void StopRuntimeServices()
    {
        Services.GetRequiredService<IGlobalHotkeyService>().UnregisterHotkey();
        Services.GetRequiredService<ITrayService>().Dispose();
        Services.GetRequiredService<IRecordingOverlayService>().Dispose();
    }

    public static void SetAccountContext(string? accountId) =>
        Services.GetRequiredService<JsonDataStore>().SetAccountId(accountId);

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr FindWindow(string? className, string windowName);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr handle, int command);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr handle);
}
