using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class WelcomeStepPage : Page
{
    public WelcomeStepPage()
    {
        InitializeComponent();
        Loaded += (_, _) => ApplyCompanyLogoTheme();
        ActualThemeChanged += (_, _) => ApplyCompanyLogoTheme();
    }

    private void OnLayoutSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var showPreview = e.NewSize.Width >= 760;
        PreviewPanel.Visibility = showPreview ? Visibility.Visible : Visibility.Collapsed;
        IntroductionColumn.Width = showPreview ? new GridLength(5, GridUnitType.Star)
            : new GridLength(1, GridUnitType.Star);
        PreviewColumn.Width = showPreview ? new GridLength(6, GridUnitType.Star)
            : new GridLength(0);
    }

    private void ApplyCompanyLogoTheme()
    {
        var variant = ActualTheme == ElementTheme.Dark ? ".dark" : "";
        CompanyLogo.Source = new SvgImageSource(new Uri($"ms-appx:///Assets/icons/company-logo{variant}.svg"));
        DemoMicIcon.Source = new SvgImageSource(new Uri($"ms-appx:///Assets/icons/mic{variant}.svg"));
    }

    private void OnStartClick(object sender, RoutedEventArgs e) =>
        Frame.Navigate(typeof(PermissionsStepPage));

    private async void OnLegalLinkClick(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string path } || path is not ("privacy" or "terms")) return;
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
}
