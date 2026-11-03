using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Composition;
using System.Numerics;
using Microsoft.Extensions.DependencyInjection;
using VoiceLab.Infrastructure.Services;
using Microsoft.UI.Xaml.Media.Imaging;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class TimeSavingsStepPage : Page
{
    private Compositor _compositor;
    private const int AVERAGE_TYPING_WPM = 40;
    private int _voiceWpm = 130;

    public TimeSavingsStepPage()
    {
        this.InitializeComponent();
        _compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
        this.Loaded += OnLoaded;
        ActualThemeChanged += (_, _) => ApplyIconTheme();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyIconTheme();
        var settings = App.Services.GetRequiredService<ISettingsService>();
        var words = settings.GetSetting("PracticeWords", 0);
        var seconds = settings.GetSetting("PracticeSeconds", 0d);
        if (words > 0 && seconds > 0) _voiceWpm = Math.Clamp((int)Math.Round(words * 60d / seconds), 30, 260);
        // Calculate multiplier
        var multiplier = Math.Round((double)_voiceWpm / AVERAGE_TYPING_WPM, 1);

        // Start count-up animation for multiplier
        MultiplierText.Text = multiplier.ToString("0.0");

        // Animate bars
        var maxWpm = Math.Max(_voiceWpm, AVERAGE_TYPING_WPM);
        AnimateBar(VoiceBar, _voiceWpm, _voiceWpm * 100d / maxWpm, 800, 0);
        AnimateBar(TypingBar, AVERAGE_TYPING_WPM, AVERAGE_TYPING_WPM * 100d / maxWpm, 800, 100);

        // Calculate hours saved
        var hoursPerDay = HoursSlider.Value;
        var savedHours = CalculateHoursSaved(hoursPerDay);
        HoursSavedText.Text = savedHours.ToString("0.0");
    }

    private void ApplyIconTheme()
    {
        var suffix = ActualTheme == ElementTheme.Dark ? ".dark.svg" : ".svg";
        VoiceIcon.Source = new SvgImageSource(new Uri("ms-appx:///Assets/icons/mic" + suffix));
        TypingIcon.Source = new SvgImageSource(new Uri("ms-appx:///Assets/icons/keyboard" + suffix));
    }

    private async void AnimateCountUp(TextBlock textBlock, double target, int durationMs)
    {
        var startTime = DateTime.Now;
        var duration = TimeSpan.FromMilliseconds(durationMs);

        while (DateTime.Now - startTime < duration)
        {
            var progress = (DateTime.Now - startTime).TotalMilliseconds / durationMs;
            var eased = 1 - Math.Pow(1 - progress, 3); // Cubic ease-out
            var current = target * eased;

            textBlock.Text = current.ToString("0.0");
            await Task.Delay(16); // ~60fps
        }

        textBlock.Text = target.ToString("0.0");
    }

    private void AnimateBar(Border bar, int wpm, double targetWidthPercent, int durationMs, int delayMs)
    {
        var visual = ElementCompositionPreview.GetElementVisual(bar);

        // Width animation (using Scale on X axis)
        var scaleAnimation = _compositor.CreateVector3KeyFrameAnimation();
        scaleAnimation.InsertKeyFrame(0.0f, new Vector3(0, 1, 1));
        scaleAnimation.InsertKeyFrame(1.0f, new Vector3((float)(targetWidthPercent / 100.0), 1, 1));
        scaleAnimation.Duration = TimeSpan.FromMilliseconds(durationMs);
        scaleAnimation.DelayTime = TimeSpan.FromMilliseconds(delayMs);

        // Cubic bezier easing
        var easing = _compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.22f, 1.0f),
            new Vector2(0.36f, 1.0f)
        );
        scaleAnimation.SetReferenceParameter("easing", easing);

        visual.CenterPoint = new Vector3(0, (float)bar.ActualHeight / 2, 0);
        visual.StartAnimation("Scale", scaleAnimation);

        // Update WPM text
        var wpmText = (bar.Tag as TextBlock);
        if (wpmText != null)
        {
            AnimateCountUp(wpmText, wpm, durationMs);
        }
    }

    private double CalculateHoursSaved(double hoursPerDay)
    {
        var workDaysPerWeek = 5;
        var savedFraction = Math.Max(0, 1 - (double)AVERAGE_TYPING_WPM / _voiceWpm);
        return Math.Round(hoursPerDay * workDaysPerWeek * savedFraction * 10) / 10;
    }

    private void OnSliderValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (HoursSavedText != null)
        {
            var savedHours = CalculateHoursSaved(e.NewValue);
            HoursSavedText.Text = savedHours.ToString("0.0");
        }
    }

    private void OnNextClick(object sender, RoutedEventArgs e)
    {
        Frame.Navigate(typeof(PersonalizeStepPage));
    }
}
