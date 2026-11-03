using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using VoiceLab.App.Services;

namespace VoiceLab.App.ViewModels;

public partial class OnboardingViewModel : ObservableObject
{
    private readonly INavigationService _navigationService;

    [ObservableProperty]
    private int _currentStep = 0;

    [ObservableProperty]
    private int _totalSteps = 15;

    [ObservableProperty]
    private double _progress = 0;

    public OnboardingViewModel(INavigationService navigationService)
    {
        _navigationService = navigationService;
        UpdateProgress();
    }

    [RelayCommand]
    private void NextStep()
    {
        CurrentStep++;
        UpdateProgress();
    }

    [RelayCommand]
    private void PreviousStep()
    {
        if (CurrentStep > 0)
        {
            CurrentStep--;
            UpdateProgress();
        }
    }

    private void UpdateProgress()
    {
        Progress = ((double)(CurrentStep + 1) / TotalSteps) * 100;
    }
}
