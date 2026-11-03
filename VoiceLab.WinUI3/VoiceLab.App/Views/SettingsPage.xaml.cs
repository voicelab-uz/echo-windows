using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using Microsoft.Extensions.DependencyInjection;
using VoiceLab.Infrastructure.Services;
using VoiceLab.Infrastructure.Audio;
using VoiceLab.App.Services;
using VoiceLab.Infrastructure.Hotkeys;

namespace VoiceLab.App.Views;

public sealed partial class SettingsPage : Page
{
    private readonly ISettingsService _settings = App.Services.GetRequiredService<ISettingsService>();
    private bool _initialized;
    private bool _signingOut;

    public SettingsPage()
    {
        this.InitializeComponent();
        Loaded += (_, _) =>
        {
            _initialized = false;
            SelectTag(ThemeSelector, _settings.GetSetting("Theme", "system"));
            SelectTag(AccentSelector, _settings.GetSetting("AccentColor", "voicelab"));
            SelectTag(ShortcutSelector, _settings.GetSetting("Shortcut", "win-alt-space"));
            UpdateActivationModeInfo();
            UpdatePasteShortcutInfo();
            SelectTag(LanguageSelector, _settings.GetSetting("PreferredLanguage", "auto"));
            SelectTag(AlphabetSelector, _settings.GetSetting("UzbekAlphabet", "current"));
            MicrophoneSelector.Items.Clear();
            try
            {
                var devices = App.Services.GetRequiredService<IAudioCaptureService>().GetAvailableDevices();
                for (var i = 0; i < devices.Count; i++) MicrophoneSelector.Items.Add(new ComboBoxItem { Content = devices[i], Tag = i });
                var selectedDevice = _settings.GetSetting("MicrophoneIndex", 0);
                MicrophoneSelector.SelectedItem = MicrophoneSelector.Items.OfType<ComboBoxItem>().FirstOrDefault(item => Equals(item.Tag, selectedDevice));
                MicrophoneSelector.IsEnabled = devices.Count > 0;
                MicrophoneSelector.PlaceholderText = devices.Count > 0 ? "Choose a microphone" : "No microphone found";
            }
            catch
            {
                MicrophoneSelector.IsEnabled = false;
                MicrophoneSelector.PlaceholderText = "Microphones unavailable";
            }
            CapitalizationToggle.IsOn = _settings.GetSetting("AutoCapitalize", true);
            AutoPasteToggle.IsOn = _settings.GetSetting("AutoPaste", true);
            RetainHistoryToggle.IsOn = _settings.GetSetting("RetainHistory", true);
            InsertionMethodSelector.IsEnabled = AutoPasteToggle.IsOn;
            SelectTag(InsertionMethodSelector, _settings.GetSetting("TextInsertionMethod", "paste"));
            PunctuationToggle.IsOn = _settings.GetSetting("SmartPunctuation", true);
            SoundToggle.IsOn = _settings.GetSetting("SoundFeedback", false);
            try { StartupToggle.IsOn = App.Services.GetRequiredService<IStartupService>().IsEnabled(); }
            catch { StartupToggle.IsEnabled = false; }
            _initialized = true;
            _ = LoadAccountAsync();
        };
    }

    private async Task LoadAccountAsync()
    {
        try
        {
            var user = await App.Services.GetRequiredService<IAuthenticationService>().GetCurrentUserAsync();
            AccountEmail.Text = user?.Email ?? "No account signed in";
        }
        catch (Exception ex)
        {
            AccountEmail.Text = "Account details temporarily unavailable";
            System.Diagnostics.Debug.WriteLine($"Settings account details unavailable: {ex}");
        }
    }

    private static void SelectTag(ComboBox combo, string value) =>
        combo.SelectedItem = combo.Items.OfType<ComboBoxItem>().FirstOrDefault(item => Equals(item.Tag, value))
            ?? combo.Items.OfType<ComboBoxItem>().FirstOrDefault();

    private void UpdatePasteShortcutInfo()
    {
        var available = App.Services.GetRequiredService<IGlobalHotkeyService>().IsPasteRegistered;
        PasteShortcutInfo.Text = available
            ? "Ctrl + Win + V pastes the last transcript into the focused app. The tray menu can copy it."
            : "The last-transcript shortcut is unavailable on this PC. Use Copy last transcript in the tray menu.";
    }

    private void UpdateActivationModeInfo()
    {
        var hotkeys = App.Services.GetRequiredService<IGlobalHotkeyService>();
        var available = hotkeys.IsReleaseTrackingAvailable;
        var saved = _settings.GetSetting("ActivationMode", "automatic");
        if (saved is not ("automatic" or "toggle" or "hold")) saved = "automatic";
        var selected = available ? saved : "toggle";
        var wasInitialized = _initialized;
        _initialized = false;
        SelectTag(ActivationModeSelector, selected);
        _initialized = wasInitialized;
        ActivationModeSelector.IsEnabled = available;
        ActivationModeInfo.Text = available ? selected switch
        {
            "hold" => "Hold the shortcut to record. A very short press is discarded.",
            "toggle" => "Press the shortcut once to record, then again to transcribe.",
            _ => "Hold to talk, or tap for hands-free recording. Press again to finish a hands-free recording."
        } : "Release tracking is unavailable on this PC. The shortcut uses press-once toggle mode.";
        if (hotkeys.IsPassiveFallback)
            ActivationModeInfo.Text += " Windows may also respond to this reserved key combination.";
    }

    private void OnActivationModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized || ActivationModeSelector.SelectedValue is not string value ||
            !App.Services.GetRequiredService<IGlobalHotkeyService>().IsReleaseTrackingAvailable) return;
        _settings.SaveSetting("ActivationMode", value);
        UpdateActivationModeInfo();
    }

    private void OnSettingsScrollSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (e.NewSize.Width > 0) SettingsContent.Width = Math.Min(800, e.NewSize.Width);
    }

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized || ThemeSelector.SelectedValue is not string value) return;
        _settings.SaveSetting("Theme", value);
        App.ApplyTheme();
    }

    private void OnAccentChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized || AccentSelector.SelectedValue is not string value) return;
        _settings.SaveSetting("AccentColor", value);
        App.ApplyTheme();
    }

    private void OnShortcutChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized || ShortcutSelector.SelectedValue is not string value) return;
        var previous = _settings.GetSetting("Shortcut", "win-alt-space");
        if (previous is not ("win-alt-space" or "ctrl-alt-space" or "ctrl-shift-space"))
            previous = "win-alt-space";
        if (value == previous) return;
        if (App.Services.GetRequiredService<IRecordingCoordinator>().State is RecordingState.Recording or RecordingState.Transcribing)
        {
            _initialized = false;
            SelectTag(ShortcutSelector, previous);
            _initialized = true;
            _ = new ContentDialog { XamlRoot = XamlRoot, Title = "Finish dictation first",
                Content = "Stop the current recording before changing its global shortcut.",
                CloseButtonText = "OK" }.ShowAsync();
            return;
        }
        _settings.SaveSetting("Shortcut", value);
        if (!App.RegisterConfiguredHotkey(force: true))
        {
            _settings.SaveSetting("Shortcut", previous);
            var restored = App.RegisterConfiguredHotkey(force: true);
            _initialized = false;
            SelectTag(ShortcutSelector, previous);
            _initialized = true;
            if (!restored && App.MainWindow?.Content is ShellPage warningShell) warningShell.ShowHotkeyError();
            var message = new ContentDialog { XamlRoot = XamlRoot, Title = "Shortcut unavailable",
                Content = restored ? "Another app is already using that shortcut. Your previous shortcut is active."
                    : "Neither shortcut could be registered. Choose another shortcut to enable dictation.",
                CloseButtonText = "OK" };
            _ = message.ShowAsync();
        }
        else if (App.MainWindow?.Content is ShellPage shell) shell.ClearHotkeyError();
        UpdateActivationModeInfo();
        UpdatePasteShortcutInfo();
    }

    private void OnMicrophoneChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized || MicrophoneSelector.SelectedItem is not ComboBoxItem { Tag: int index }) return;
        App.Services.GetRequiredService<IAudioCaptureService>().SetDevice(index);
        _settings.SaveSetting("MicrophoneIndex", index);
    }

    private async void OnOpenMicPrivacyClick(object sender, RoutedEventArgs e)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:privacy-microphone")
            { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            await new ContentDialog { XamlRoot = XamlRoot, Title = "Windows Settings unavailable",
                Content = ex.Message, CloseButtonText = "OK" }.ShowAsync();
        }
    }

    private async void OnLegalLinkClick(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string path } ||
            path is not ("privacy" or "terms" or "refund" or "cookies")) return;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://voicelab.uz/" + path)
            { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            await new ContentDialog { XamlRoot = XamlRoot, Title = "Could not open the browser",
                Content = ex.Message, CloseButtonText = "OK" }.ShowAsync();
        }
    }

    private void OnOutputChanged(object sender, RoutedEventArgs e)
    {
        if (!_initialized) return;
        _settings.SaveSetting("AutoPaste", AutoPasteToggle.IsOn);
        _settings.SaveSetting("RetainHistory", RetainHistoryToggle.IsOn);
        InsertionMethodSelector.IsEnabled = AutoPasteToggle.IsOn;
        _settings.SaveSetting("AutoCapitalize", CapitalizationToggle.IsOn);
        _settings.SaveSetting("SmartPunctuation", PunctuationToggle.IsOn);
        _settings.SaveSetting("SoundFeedback", SoundToggle.IsOn);
    }

    private void OnInsertionMethodChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initialized && InsertionMethodSelector.SelectedValue is string value)
            _settings.SaveSetting("TextInsertionMethod", value);
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initialized && LanguageSelector.SelectedValue is string value)
            _settings.SaveSetting("PreferredLanguage", value);
    }

    private void OnAlphabetChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initialized && AlphabetSelector.SelectedValue is string value)
            _settings.SaveSetting("UzbekAlphabet", value);
    }

    private void OnStartupChanged(object sender, RoutedEventArgs e)
    {
        if (!_initialized) return;
        try { App.Services.GetRequiredService<IStartupService>().SetEnabled(StartupToggle.IsOn); }
        catch (Exception ex)
        {
            _initialized = false;
            StartupToggle.IsOn = !StartupToggle.IsOn;
            _initialized = true;
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Startup setting failed",
                Content = ex.Message, CloseButtonText = "OK" };
            _ = dialog.ShowAsync();
        }
    }

    private async void OnSignOutClick(object sender, RoutedEventArgs e)
    {
        if (_signingOut) return;
        _signingOut = true;
        SignOutButton.IsEnabled = false;
        SignOutButton.Content = "Signing out...";
        var auth = App.Services.GetRequiredService<IAuthenticationService>();
        try { await App.Services.GetRequiredService<IRecordingCoordinator>().CancelAsync(); }
        catch { /* Sign-out should still complete if the microphone has failed. */ }
        try { await auth.SignOutAsync(); }
        catch (RemoteSessionRevocationException ex)
        {
            await new ContentDialog { XamlRoot = XamlRoot, Title = "Signed out on this device",
                Content = ex.Message + " If you need to end other active sessions, use your VoiceLab account security settings.",
                CloseButtonText = "OK" }.ShowAsync();
        }
        catch (Exception ex)
        {
            await new ContentDialog { XamlRoot = XamlRoot, Title = "Sign-out failed",
                Content = "Echo could not remove the saved sign-in from this device: " + ex.Message,
                CloseButtonText = "OK" }.ShowAsync();
            _signingOut = false;
            SignOutButton.IsEnabled = true;
            SignOutButton.Content = "Sign Out";
            return;
        }
        App.SetAccountContext(null);
        App.StopRuntimeServices();
        _settings.SaveSetting("OnboardingStep", 6);
        _settings.SaveSetting("OnboardingProfilePulledUserId", "");
        _settings.SaveSetting("UserRole", "");
        _settings.SaveSetting("TypingPlaces", new List<string>());
        _settings.SaveSetting("PreferredLanguage", "auto");
        _settings.SaveSetting("WritingStyle", "");
        _settings.SaveSetting("PracticeWords", 0);
        _settings.SaveSetting("PracticeSeconds", 0d);
        if (App.MainWindow is { } window)
        {
            window.Content = new OnboardingShellPage(6);
            // Sign-out tears down the runtime hook. A new account still needs
            // the shortcut for onboarding practice before ShowShell runs again.
            App.RegisterConfiguredHotkey();
        }
    }
}
