using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class PersonalizeStepPage : Page
{
    public PersonalizeStepPage()
    {
        this.InitializeComponent();
        var style = App.Services.GetRequiredService<ISettingsService>().GetSetting("WritingStyle", "casual");
        WritingStyleSelector.SelectedItem = WritingStyleSelector.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => Equals(item.Tag, style)) ?? WritingStyleSelector.Items[0];
    }

    private void OnNextClick(object sender, RoutedEventArgs e)
    {
        var settings = App.Services.GetRequiredService<ISettingsService>();
        settings.SaveSetting("AutoCapitalize", CapitalizeSwitch.IsOn);
        settings.SaveSetting("SmartPunctuation", PunctuationSwitch.IsOn);
        settings.SaveSetting("SoundFeedback", SoundSwitch.IsOn);
        settings.SaveSetting("WritingStyle", (WritingStyleSelector.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "casual");
        Frame.Navigate(typeof(DoneStepPage));
    }
}
