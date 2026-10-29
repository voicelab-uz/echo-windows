using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using VoiceLabEcho.Core.Interfaces;
using VoiceLabEcho.Infrastructure.Services;
using VoiceLabEcho.Infrastructure.Api;
using VoiceLabEcho.Infrastructure.Audio;
using VoiceLabEcho.Infrastructure.Storage;
using VoiceLabEcho.Infrastructure.Security;
using VoiceLabEcho.App.Services;
using VoiceLabEcho.App.ViewModels;

namespace VoiceLabEcho.App;

public partial class App : Application
{
    private readonly IHost _host;
    private TrayIconService? _trayIconService;

    public App()
    {
        _host = Host.CreateDefaultBuilder()
            .ConfigureServices((context, services) =>
            {
                // Core Services
                services.AddSingleton<IAuthenticationService, AuthenticationService>();
                services.AddSingleton<IAudioRecordingService, AudioRecordingService>();
                services.AddSingleton<ITranscriptionService, TranscriptionService>();
                services.AddSingleton<IStorageService, EncryptedStorageService>();
                services.AddSingleton<INotesService, NotesService>();
                services.AddSingleton<IVocabularyService, VocabularyService>();
                services.AddSingleton<IHistoryService, HistoryService>();
                services.AddSingleton<IStatisticsService, StatisticsService>();
                services.AddSingleton<IKeyboardShortcutService, KeyboardShortcutService>();

                // Infrastructure
                services.AddSingleton<IEncryptionProvider, EncryptionProvider>();
                services.AddSingleton<ICredentialManager, CredentialManager>();
                services.AddSingleton<VoiceLabApiClient>();
                services.AddSingleton<PkceGenerator>();

                // App Services
                services.AddSingleton<NavigationService>();
                services.AddSingleton<TrayIconService>();
                services.AddSingleton<WindowManager>();
                services.AddSingleton<TextInsertionService>();
                services.AddSingleton<StartupService>();
                services.AddSingleton<ThemeService>();

                // ViewModels
                services.AddTransient<MainViewModel>();
                services.AddTransient<HistoryViewModel>();
                services.AddTransient<RecordingViewModel>();
                services.AddTransient<VocabularyViewModel>();
                services.AddTransient<NotesViewModel>();
                services.AddTransient<StatisticsViewModel>();
                services.AddTransient<SettingsViewModel>();
                services.AddTransient<OnboardingViewModel>();
                services.AddTransient<GettingStartedViewModel>();

                // Windows
                services.AddSingleton<MainWindow>();

                // HTTP Client
                services.AddHttpClient<VoiceLabApiClient>(client =>
                {
                    client.BaseAddress = new Uri("https://api.voicelab.uz");
                    client.Timeout = TimeSpan.FromSeconds(30);
                });
            })
            .Build();
    }

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        await _host.StartAsync();

        // Initialize tray icon
        _trayIconService = _host.Services.GetRequiredService<TrayIconService>();
        _trayIconService.Initialize();

        // Show main window
        var mainWindow = _host.Services.GetRequiredService<MainWindow>();
        mainWindow.Show();

        // Handle global exception
        AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;
        DispatcherUnhandledException += OnDispatcherUnhandledException;
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        _trayIconService?.Dispose();

        using (_host)
        {
            await _host.StopAsync();
        }

        base.OnExit(e);
    }

    private void OnUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        if (e.ExceptionObject is Exception exception)
        {
            LogException(exception);
            MessageBox.Show(
                $"An unexpected error occurred: {exception.Message}",
                "Error",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void OnDispatcherUnhandledException(object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
    {
        LogException(e.Exception);
        MessageBox.Show(
            $"An unexpected error occurred: {e.Exception.Message}",
            "Error",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        e.Handled = true;
    }

    private void LogException(Exception exception)
    {
        // TODO: Implement proper logging
        System.Diagnostics.Debug.WriteLine($"Unhandled exception: {exception}");
    }

    public static IServiceProvider ServiceProvider => ((App)Current)._host.Services;
}
