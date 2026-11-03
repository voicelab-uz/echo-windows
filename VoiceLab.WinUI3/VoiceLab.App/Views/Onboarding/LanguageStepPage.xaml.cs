using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class LanguageStepPage : Page
{
    public LanguageStepPage()
    {
        this.InitializeComponent();
        var language = App.Services.GetRequiredService<ISettingsService>().GetSetting("PreferredLanguage", "auto");
        if (language == "uz") UzbekOption.IsChecked = true;
        else if (language == "en") EnglishOption.IsChecked = true;
        else if (language == "ru") RussianOption.IsChecked = true;
    }

    private void OnNextClick(object sender, RoutedEventArgs e)
    {
        var language = UzbekOption.IsChecked == true ? "uz" : EnglishOption.IsChecked == true ? "en" :
            RussianOption.IsChecked == true ? "ru" : "auto";
        App.Services.GetRequiredService<ISettingsService>().SaveSetting("PreferredLanguage", language);
        Frame.Navigate(typeof(SignInStepPage));
    }
}
