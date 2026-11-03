namespace VoiceLab.App.Services;

public interface INavigationService
{
    void NavigateTo(Type pageType, object? parameter = null);
    void GoBack();
    bool CanGoBack { get; }
}
