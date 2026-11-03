using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace VoiceLab.App.Services;

public class NavigationService : INavigationService
{
    private Frame? _frame;

    public void SetFrame(Frame frame)
    {
        _frame = frame;
    }

    public void NavigateTo(Type pageType, object? parameter = null)
    {
        if (_frame == null) return;

        _frame.Navigate(pageType, parameter, new SlideNavigationTransitionInfo
        {
            Effect = SlideNavigationTransitionEffect.FromRight
        });
    }

    public void GoBack()
    {
        if (_frame?.CanGoBack == true)
        {
            _frame.GoBack(new SlideNavigationTransitionInfo
            {
                Effect = SlideNavigationTransitionEffect.FromLeft
            });
        }
    }

    public bool CanGoBack => _frame?.CanGoBack ?? false;
}
