using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Composition;
using System.Numerics;
using Microsoft.Extensions.DependencyInjection;
using VoiceLab.Infrastructure.Services;
using VoiceLab.Infrastructure.Hotkeys;
using Microsoft.UI.Xaml.Media.Imaging;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class TryItIntroStepPage : Page
{
    private Compositor _compositor;

    public TryItIntroStepPage()
    {
        this.InitializeComponent();
        _compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
        this.Loaded += OnLoaded;
        ActualThemeChanged += (_, _) => ApplyIconTheme();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        App.Services.GetRequiredService<IGlobalHotkeyService>().HotkeyPressed += OnHotkeyPressed;
        ApplyIconTheme();
        Unloaded += OnUnloaded;
        var value = App.Services.GetRequiredService<ISettingsService>().GetSetting("Shortcut", "win-alt-space");
        var label = value switch { "ctrl-shift-space" => "Ctrl+Shift+Space", "ctrl-alt-space" => "Ctrl+Alt+Space", _ => "Win+Alt+Space" };
        ShortcutRun.Text = label;
        ShortcutCaption.Text = label;
        // Start pulsing animations
        StartKeyPressAnimation();
        StartGlowAnimation();
    }

    private void ApplyIconTheme()
    {
        var variant = ActualTheme == ElementTheme.Dark ? ".dark" : "";
        KeyboardIcon.Source = new SvgImageSource(new Uri("ms-appx:///Assets/icons/keyboard" + variant + ".svg"));
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        App.Services.GetRequiredService<IGlobalHotkeyService>().HotkeyPressed -= OnHotkeyPressed;
        Unloaded -= OnUnloaded;
    }

    private async void OnHotkeyPressed(object? sender, EventArgs e)
    {
        Frame.Navigate(typeof(TryItMessageStepPage));
        if (Frame.Content is TryItMessageStepPage practice)
            await practice.BeginFromShortcutAsync();
    }

    private void StartKeyPressAnimation()
    {
        var visual = ElementCompositionPreview.GetElementVisual(HotkeyButton);

        // Set center point for scaling
        visual.CenterPoint = new Vector3(
            (float)HotkeyButton.ActualWidth / 2,
            (float)HotkeyButton.ActualHeight / 2,
            0
        );

        // Key press animation (Y translation)
        var pressAnimation = _compositor.CreateVector3KeyFrameAnimation();
        pressAnimation.InsertKeyFrame(0.0f, new Vector3(0, 0, 0));
        pressAnimation.InsertKeyFrame(0.45f, new Vector3(0, 2, 0));  // Pressed down
        pressAnimation.InsertKeyFrame(0.6f, new Vector3(0, 2, 0));   // Hold
        pressAnimation.InsertKeyFrame(1.0f, new Vector3(0, 0, 0));   // Release
        pressAnimation.Duration = TimeSpan.FromMilliseconds(2200);
        pressAnimation.IterationBehavior = AnimationIterationBehavior.Forever;

        visual.StartAnimation("Offset", pressAnimation);
    }

    private void StartGlowAnimation()
    {
        var visual = ElementCompositionPreview.GetElementVisual(GlowRing);

        visual.CenterPoint = new Vector3(
            (float)GlowRing.ActualWidth / 2,
            (float)GlowRing.ActualHeight / 2,
            0
        );

        // Scale animation (pulse effect)
        var scaleAnimation = _compositor.CreateVector3KeyFrameAnimation();
        scaleAnimation.InsertKeyFrame(0.0f, new Vector3(1.0f, 1.0f, 1.0f));
        scaleAnimation.InsertKeyFrame(0.5f, new Vector3(1.4f, 1.4f, 1.0f));
        scaleAnimation.InsertKeyFrame(1.0f, new Vector3(1.0f, 1.0f, 1.0f));
        scaleAnimation.Duration = TimeSpan.FromMilliseconds(2200);
        scaleAnimation.IterationBehavior = AnimationIterationBehavior.Forever;

        // Opacity animation (fade out)
        var opacityAnimation = _compositor.CreateScalarKeyFrameAnimation();
        opacityAnimation.InsertKeyFrame(0.0f, 0.4f);
        opacityAnimation.InsertKeyFrame(0.5f, 0.0f);
        opacityAnimation.InsertKeyFrame(1.0f, 0.4f);
        opacityAnimation.Duration = TimeSpan.FromMilliseconds(2200);
        opacityAnimation.IterationBehavior = AnimationIterationBehavior.Forever;

        visual.StartAnimation("Scale", scaleAnimation);
        visual.StartAnimation("Opacity", opacityAnimation);
    }

    private void OnStartClick(object sender, RoutedEventArgs e)
    {
        // Navigate to try it step
        Frame.Navigate(typeof(TryItMessageStepPage));
    }
}
