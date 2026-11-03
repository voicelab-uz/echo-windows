using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoiceLab.Infrastructure.Services;
using Microsoft.Extensions.DependencyInjection;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class SignInStepPage : Page
{
    private readonly IAuthenticationService _authService =
        (IAuthenticationService)App.Services.GetService(typeof(IAuthenticationService))!;
    private CancellationTokenSource? _signInCancellation;

    public SignInStepPage()
    {
        InitializeComponent();
        ActualThemeChanged += (_, _) => App.UpdateThemePalette(ActualTheme);
        Loaded += async (_, _) =>
        {
            try
            {
                if (await _authService.IsAuthenticatedAsync())
                {
                    if (!IsLoaded) return;
                    App.SetAccountContext((await _authService.GetCurrentUserAsync())?.Id);
                    await ContinueAfterSignInAsync();
                }
            }
            catch (Exception ex) { if (IsLoaded) SignInStatus.Text = ex.Message; }
        };
        Unloaded += (_, _) => _signInCancellation?.Cancel();
    }

    private async void OnSignInClick(object sender, RoutedEventArgs e)
    {
        if (_signInCancellation is not null) return;
        using var attempt = new CancellationTokenSource();
        _signInCancellation = attempt;
        SignInButton.IsEnabled = false;
        SignInStatus.Text = "Opening your browser… complete sign-in there, then return to Echo.";
        try
        {
            var result = await _authService.SignInWithBrowserAsync(attempt.Token);
            if (attempt.IsCancellationRequested || !IsLoaded) return;
            if (!result.Success)
            {
                SignInStatus.Text = result.Error ?? "Sign-in could not be completed. Please try again.";
                SignInButton.IsEnabled = true;
                return;
            }

            App.MainWindow?.Activate();
            SignInStatus.Text = $"Signed in as {result.User?.Email}. Continuing setup…";
            App.SetAccountContext(result.User?.Id);
            try { await App.Services.GetRequiredService<IOnboardingProfileService>().PullAsync(); }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Legacy onboarding profile pull will retry later: {ex}");
            }
            if (attempt.IsCancellationRequested || !IsLoaded) return;
            await Task.Delay(350);
            if (attempt.IsCancellationRequested || !IsLoaded) return;
            await ContinueAfterSignInAsync();
        }
        catch (Exception ex)
        {
            if (attempt.IsCancellationRequested || !IsLoaded) return;
            SignInStatus.Text = ex.Message;
            SignInButton.IsEnabled = true;
        }
        finally
        {
            if (ReferenceEquals(_signInCancellation, attempt)) _signInCancellation = null;
        }
    }

    private async Task ContinueAfterSignInAsync()
    {
        var settings = App.Services.GetRequiredService<ISettingsService>();
        var userId = (await _authService.GetCurrentUserAsync())?.Id;
        var completed = settings.GetSetting("OnboardingCompleted", false) &&
            userId == settings.GetSetting("OnboardingCompletedUserId", "");
        if (completed) { App.ShowShell(); return; }
        settings.SaveSetting("OnboardingCompleted", false);
        if (Frame is not null) Frame.Navigate(typeof(QuestionnaireStepPage));
        else if (App.MainWindow is { } window) window.Content = new OnboardingShellPage(7);
    }
}
