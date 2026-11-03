using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Media;
using System.Numerics;
using Windows.UI;
using VoiceLab.Infrastructure.Services;
using Microsoft.UI.Xaml.Media.Imaging;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class DoneStepPage : Page
{
    private Compositor _compositor;

    public DoneStepPage()
    {
        this.InitializeComponent();
        _compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
        this.Loaded += OnLoaded;
        ActualThemeChanged += (_, _) => ApplyIconTheme();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ShortcutRun.Text = App.Services.GetRequiredService<ISettingsService>().GetShortcutLabel();
        ApplyIconTheme();
        // Trigger confetti celebration!
        PlayCelebrationAnimation();

        // Animate the icon
        AnimateIcon();
    }

    private void ApplyIconTheme()
    {
        var suffix = ActualTheme == ElementTheme.Dark ? ".dark.svg" : ".svg";
        foreach (var (icon, name) in new (Image icon, string name)[]
        {
            (CelebrationIcon, "star"), (AppStepIcon, "doc"),
            (EditStepIcon, "edit"), (ShortcutStepIcon, "keyboard")
        }) icon.Source = new SvgImageSource(new Uri("ms-appx:///Assets/icons/" + name + suffix));
    }

    private void AnimateIcon()
    {
        var visual = ElementCompositionPreview.GetElementVisual(CelebrationIcon);

        visual.CenterPoint = new Vector3(
            (float)CelebrationIcon.ActualWidth / 2,
            (float)CelebrationIcon.ActualHeight / 2,
            0
        );

        // Pop animation
        var scaleAnimation = _compositor.CreateVector3KeyFrameAnimation();
        scaleAnimation.InsertKeyFrame(0.0f, new Vector3(0.6f, 0.6f, 1.0f));
        scaleAnimation.Duration = TimeSpan.FromMilliseconds(600);

        var easing = _compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.34f, 1.56f),
            new Vector2(0.64f, 1.0f)
        );
        scaleAnimation.InsertKeyFrame(1.0f, new Vector3(1.0f, 1.0f, 1.0f), easing);

        // Rotation animation
        var rotationAnimation = _compositor.CreateScalarKeyFrameAnimation();
        rotationAnimation.InsertKeyFrame(0.0f, -8.0f);
        rotationAnimation.InsertKeyFrame(1.0f, -4.0f);
        rotationAnimation.Duration = TimeSpan.FromMilliseconds(600);

        // Opacity animation
        var opacityAnimation = _compositor.CreateScalarKeyFrameAnimation();
        opacityAnimation.InsertKeyFrame(0.0f, 0.0f);
        opacityAnimation.InsertKeyFrame(1.0f, 1.0f);
        opacityAnimation.Duration = TimeSpan.FromMilliseconds(600);

        visual.StartAnimation("Scale", scaleAnimation);
        visual.StartAnimation("RotationAngleInDegrees", rotationAnimation);
        visual.StartAnimation("Opacity", opacityAnimation);
    }

    private void PlayCelebrationAnimation()
    {
        // Create 18 confetti particles in a circle
        ConfettiContainer.Children.Clear();
        for (int i = 0; i < 18; i++)
        {
            CreateConfettiParticle(i);
        }
    }

    private void CreateConfettiParticle(int index)
    {
        var particle = new Border
        {
            Width = 10,
            Height = 10,
            CornerRadius = new CornerRadius(2),
            Background = new SolidColorBrush(GetParticleColor(index)),
            RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5)
        };

        ConfettiContainer.Children.Add(particle);

        var visual = ElementCompositionPreview.GetElementVisual(particle);

        // Calculate position in circle
        var angle = (index / 18.0) * Math.PI * 2;
        var distance = 90 + (index % 4) * 28;
        var dx = (float)(Math.Cos(angle) * distance);
        var dy = (float)(Math.Sin(angle) * distance);
        var rotation = (index % 2 == 0 ? 1 : -1) * (120 + index * 11);

        // Position animation
        var positionAnim = _compositor.CreateVector3KeyFrameAnimation();
        positionAnim.InsertKeyFrame(0.0f, new Vector3(0, 0, 0));
        positionAnim.Duration = TimeSpan.FromMilliseconds(1100);
        positionAnim.DelayTime = TimeSpan.FromMilliseconds((index % 6) * 40);

        var easing = _compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.22f, 1.0f),
            new Vector2(0.36f, 1.0f)
        );
        positionAnim.InsertKeyFrame(1.0f, new Vector3(dx, dy, 0), easing);

        // Scale animation
        var scaleAnim = _compositor.CreateVector3KeyFrameAnimation();
        scaleAnim.InsertKeyFrame(0.0f, new Vector3(0.4f, 0.4f, 1.0f));
        scaleAnim.InsertKeyFrame(1.0f, new Vector3(1.0f, 1.0f, 1.0f));
        scaleAnim.Duration = TimeSpan.FromMilliseconds(1100);
        scaleAnim.DelayTime = TimeSpan.FromMilliseconds((index % 6) * 40);

        // Opacity animation
        var opacityAnim = _compositor.CreateScalarKeyFrameAnimation();
        opacityAnim.InsertKeyFrame(0.0f, 0.0f);
        opacityAnim.InsertKeyFrame(0.2f, 1.0f);
        opacityAnim.InsertKeyFrame(1.0f, 0.0f);
        opacityAnim.Duration = TimeSpan.FromMilliseconds(1100);
        opacityAnim.DelayTime = TimeSpan.FromMilliseconds((index % 6) * 40);

        // Rotation animation
        var rotationAnim = _compositor.CreateScalarKeyFrameAnimation();
        rotationAnim.InsertKeyFrame(0.0f, 0);
        rotationAnim.InsertKeyFrame(1.0f, (float)(rotation * Math.PI / 180));
        rotationAnim.Duration = TimeSpan.FromMilliseconds(1100);
        rotationAnim.DelayTime = TimeSpan.FromMilliseconds((index % 6) * 40);

        visual.CenterPoint = new Vector3(5, 5, 0);
        visual.StartAnimation("Offset", positionAnim);
        visual.StartAnimation("Scale", scaleAnim);
        visual.StartAnimation("Opacity", opacityAnim);
        visual.StartAnimation("RotationAngle", rotationAnim);
    }

    private Color GetParticleColor(int index)
    {
        return (index % 3) switch
        {
            0 => Color.FromArgb(255, 255, 155, 66),  // Accent orange
            1 => Color.FromArgb(255, 75, 111, 255),   // Blue
            _ => Color.FromArgb(255, 245, 194, 66)    // Yellow
        };
    }

    private async void OnFinishClick(object sender, RoutedEventArgs e)
    {
        FinishButton.IsEnabled = false;
        var auth = App.Services.GetRequiredService<IAuthenticationService>();
        if (!await auth.IsAuthenticatedAsync())
        {
            FinishStatus.Text = "Please sign in to your VoiceLab account to finish setup.";
            FinishButton.IsEnabled = true;
            Frame.Navigate(typeof(SignInStepPage));
            return;
        }

        try
        {
            var currentUser = await auth.GetCurrentUserAsync();
            var settings = App.Services.GetRequiredService<ISettingsService>();
            var completedAccounts = settings.GetSetting("PracticeCompletedAccountIds", new List<string>());
            if (currentUser?.Id is not { Length: > 0 } ownerId || !completedAccounts.Contains(ownerId))
            {
                FinishStatus.Text = "Try one voice transcription before finishing setup.";
                FinishButton.IsEnabled = true;
                Frame.Navigate(typeof(TryItIntroStepPage));
                return;
            }
            var context = App.Services.GetRequiredService<IOnboardingContextService>();
            var draft = await context.LoadDraftAsync();
            var questionnaireConfirmed = draft is { Pending: null }
                && draft.OwnerId == ownerId
                && DateTimeOffset.TryParse(draft.ConfirmedCompletedAt, out _)
                && OnboardingQuestionCatalog.Keys.All(draft.Answers.ContainsKey);
            if (!questionnaireConfirmed)
                questionnaireConfirmed = (await context.GetAsync())?.CompletedAt is not null;
            if (!questionnaireConfirmed)
            {
                FinishStatus.Text = "Finish the account questions before completing setup.";
                FinishButton.IsEnabled = true;
                Frame.Navigate(typeof(QuestionnaireStepPage));
                return;
            }
            FinishStatus.Text = "Finishing your VoiceLab setup…";
            var pending = settings.GetSetting("OnboardingCompletionPendingAccountIds", new List<string>());
            if (!pending.Contains(ownerId, StringComparer.Ordinal))
            {
                pending.Add(ownerId);
                settings.SaveSetting("OnboardingCompletionPendingAccountIds", pending);
            }
            settings.SaveSetting("OnboardingCompletedUserId", ownerId);
            settings.SaveSetting("OnboardingCompleted", true);
            settings.SaveSetting("OnboardingStep", 0);
            App.ShowShell();
        }
        catch (Exception ex)
        {
            FinishStatus.Text = "Setup could not be confirmed. Please retry. " + ex.Message;
            FinishButton.IsEnabled = true;
        }
    }
}
