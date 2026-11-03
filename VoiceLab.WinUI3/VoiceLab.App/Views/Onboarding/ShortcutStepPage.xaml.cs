using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLab.Infrastructure.Services;
using VoiceLab.Infrastructure.Hotkeys;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class ShortcutStepPage : Page
{
    private bool _loaded;
    private bool _tested;
    private readonly ISettingsService _settings = App.Services.GetRequiredService<ISettingsService>();
    private readonly IGlobalHotkeyService _hotkeys = App.Services.GetRequiredService<IGlobalHotkeyService>();

    public ShortcutStepPage()
    {
        this.InitializeComponent();
        Loaded += (_, _) =>
        {
            var selected = _settings.GetSetting("Shortcut", "win-alt-space");
            if (selected == "win-alt-space") WinAltOption.IsChecked = true;
            else if (selected == "ctrl-shift-space") CtrlShiftOption.IsChecked = true;
            else if (selected == "ctrl-alt-space") CtrlAltOption.IsChecked = true;
            else WinAltOption.IsChecked = true;
            _loaded = true;
            _tested = false;
            ContinueButton.IsEnabled = false;
            _hotkeys.HotkeyPressed += OnHotkeyPressed;
            ShortcutStatusText.Text = App.RegisterConfiguredHotkey()
                ? _hotkeys.IsPassiveFallback
                    ? "Press the shortcut to test it. Windows may also respond to this reserved key combination."
                    : "Press the selected shortcut now to test it."
                : "This shortcut is unavailable. Choose another one.";
        };
        Unloaded += (_, _) => { _loaded = false; _hotkeys.HotkeyPressed -= OnHotkeyPressed; };
    }

    private void OnHotkeyPressed(object? sender, EventArgs e) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            _tested = true;
            ContinueButton.IsEnabled = true;
            ShortcutStatusText.Text = "Shortcut detected. Press Continue to use it.";
        });

    private void OnShortcutChecked(object sender, RoutedEventArgs e)
    {
        if (!_loaded) return;
        var shortcut = WinAltOption.IsChecked == true ? "win-alt-space" :
            CtrlShiftOption.IsChecked == true ? "ctrl-shift-space" : "ctrl-alt-space";
        var previous = _settings.GetSetting("Shortcut", "win-alt-space");
        if (previous is not ("win-alt-space" or "ctrl-alt-space" or "ctrl-shift-space"))
            previous = "win-alt-space";
        if (shortcut == previous) return;
        _tested = false;
        ContinueButton.IsEnabled = false;
        _settings.SaveSetting("Shortcut", shortcut);
        if (!App.RegisterConfiguredHotkey(force: true))
        {
            _settings.SaveSetting("Shortcut", previous);
            var restored = App.RegisterConfiguredHotkey(force: true);
            _loaded = false;
            if (previous == "win-alt-space") WinAltOption.IsChecked = true;
            else if (previous == "ctrl-shift-space") CtrlShiftOption.IsChecked = true;
            else if (previous == "ctrl-alt-space") CtrlAltOption.IsChecked = true;
            else WinAltOption.IsChecked = true;
            _loaded = true;
            ShortcutStatusText.Text = restored
                ? "That shortcut is already used by another app. Your previous shortcut is active."
                : "Neither shortcut could be registered. Choose a different one to continue.";
            return;
        }
        ShortcutStatusText.Text = _hotkeys.IsPassiveFallback
            ? "Press the shortcut to test it. Windows may also respond to this reserved key combination."
            : "Shortcut active. Press it now to test it.";
    }

    private void OnNextClick(object sender, RoutedEventArgs e)
    {
        if (!_tested)
        {
            ShortcutStatusText.Text = "Press the selected shortcut once to confirm it works.";
            return;
        }
        if (!App.RegisterConfiguredHotkey())
        {
            ShortcutStatusText.Text = "This shortcut is unavailable. Choose another one.";
            return;
        }
        Frame.Navigate(typeof(AlphabetStepPage));
    }
}
