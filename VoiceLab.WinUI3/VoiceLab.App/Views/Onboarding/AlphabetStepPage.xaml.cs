using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class AlphabetStepPage : Page
{
    public AlphabetStepPage()
    {
        InitializeComponent();
        ModernOption.IsChecked = App.Services.GetRequiredService<ISettingsService>()
            .GetSetting("UzbekAlphabet", "current") == "modern";
    }

    private void OnNextClick(object sender, RoutedEventArgs e)
    {
        App.Services.GetRequiredService<ISettingsService>().SaveSetting("UzbekAlphabet",
            ModernOption.IsChecked == true ? "modern" : "current");
        Frame.Navigate(typeof(LanguageStepPage));
    }
}
