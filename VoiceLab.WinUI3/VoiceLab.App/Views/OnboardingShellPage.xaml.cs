using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using System;
using VoiceLab.App.Views.Onboarding;
using Microsoft.Extensions.DependencyInjection;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views;

public sealed partial class OnboardingShellPage : Page
{
    private static readonly Type[] Steps =
    [
        typeof(WelcomeStepPage), typeof(PermissionsStepPage), typeof(MicTestStepPage),
        typeof(ShortcutStepPage), typeof(AlphabetStepPage), typeof(LanguageStepPage), typeof(SignInStepPage),
        typeof(QuestionnaireStepPage), typeof(TryItIntroStepPage),
        typeof(TryItMessageStepPage), typeof(TryItEmailStepPage), typeof(TryItListStepPage),
        typeof(TimeSavingsStepPage), typeof(PersonalizeStepPage), typeof(DoneStepPage)
    ];

    public OnboardingShellPage(int startingStep = 0)
    {
        this.InitializeComponent();
        ActualThemeChanged += (_, _) => App.UpdateThemePalette(ActualTheme);
        Loaded += (_, _) => App.UpdateThemePalette(ActualTheme);
        ContentFrame.Navigate(Steps[Math.Clamp(startingStep, 0, Steps.Length - 1)]);
    }

    private void OnContentNavigated(object sender, Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
    {
        var index = Array.IndexOf(Steps, e.SourcePageType);
        ProgressBar.Value = index < 0 ? 0 : (index + 1d) * 100 / Steps.Length;
        StepCountText.Text = $"Step {Math.Max(1, index + 1)} of {Steps.Length}";
        if (index >= 0) App.Services.GetRequiredService<ISettingsService>().SaveSetting("OnboardingStep", index);
        BackButton.Visibility = index > 0 && index != 7 && index != 8 ? Visibility.Visible : Visibility.Collapsed;
        var section = index switch { 0 => 0, 1 => 1, <= 5 => 2, <= 7 => 3, _ => 4 };
        var labels = new[] { GetStartedSection, PermissionsSection, SetupSection, LearnSection, PersonalizeSection };
        for (var i = 0; i < labels.Length; i++)
        {
            labels[i].Opacity = i == section ? 1 : i < section ? .65 : .4;
            labels[i].FontWeight = i == section ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
        }
    }

    private void OnBackClick(object sender, RoutedEventArgs e)
    {
        if (ContentFrame.CanGoBack) ContentFrame.GoBack();
        else
        {
            var index = Array.IndexOf(Steps, ContentFrame.CurrentSourcePageType);
            if (index > 0) ContentFrame.Navigate(Steps[index - 1]);
        }
    }
}
