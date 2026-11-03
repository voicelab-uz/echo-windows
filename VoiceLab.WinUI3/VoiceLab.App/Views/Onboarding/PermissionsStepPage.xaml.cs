using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLab.Infrastructure.Audio;
using Microsoft.UI.Xaml.Media.Imaging;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class PermissionsStepPage : Page
{
    public PermissionsStepPage()
    {
        this.InitializeComponent();
        Loaded += (_, _) => ApplyIconTheme();
        ActualThemeChanged += (_, _) => ApplyIconTheme();
    }

    private void ApplyIconTheme()
    {
        var suffix = ActualTheme == ElementTheme.Dark ? ".dark.svg" : ".svg";
        foreach (var (icon, name) in new (Image icon, string name)[]
        {
            (PermissionMicIcon, "mic"), (SecurityIcon, "shield"),
            (CloudIcon, "speech-to-text"), (ControlIcon, "settings")
        }) icon.Source = new SvgImageSource(new Uri("ms-appx:///Assets/icons/" + name + suffix));
    }

    private async void OnGrantAccessClick(object sender, RoutedEventArgs e)
    {
        try
        {
            GrantButton.IsEnabled = false;
            StatusText.Text = "Requesting permission...";

            // Use the same capture device and API as dictation and the microphone test.
            var audio = App.Services.GetRequiredService<IAudioCaptureService>();
            audio.StartRecording();
            await Task.Delay(250);
            await audio.StopRecordingAsync();

            StatusText.Text = "✓ Microphone access granted";
            StatusText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(
                Windows.UI.Color.FromArgb(255, 16, 185, 129)
            );

            await Task.Delay(500);
            Frame.Navigate(typeof(MicTestStepPage));
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Microphone unavailable: {ex.Message} Check Windows microphone access, then retry.";
            StatusText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(
                Windows.UI.Color.FromArgb(255, 239, 68, 68)
            );
            GrantButton.IsEnabled = true;
        }
    }

    private void OnOpenMicrophoneSettingsClick(object sender, RoutedEventArgs e)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:privacy-microphone")
            { UseShellExecute = true });
        }
        catch (Exception ex) { StatusText.Text = $"Could not open Windows Settings: {ex.Message}"; }
    }
}
