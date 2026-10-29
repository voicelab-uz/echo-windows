using System.Windows;
using System.Windows.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLabEcho.App.ViewModels;
using VoiceLabEcho.App.Views;

namespace VoiceLabEcho.App;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;

    public MainWindow()
    {
        InitializeComponent();
        _viewModel = App.ServiceProvider.GetRequiredService<MainViewModel>();
        DataContext = _viewModel;

        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        await _viewModel.InitializeAsync();
        NavigateToView("Home");
    }

    private void OnNavigationClick(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton button && button.Tag is string viewName)
        {
            ContentHeaderText.Text = viewName;
            NavigateToView(viewName);
        }
    }

    private void NavigateToView(string viewName)
    {
        UserControl? view = viewName switch
        {
            "Home" => new HistoryView(),
            "Statistics" => new StatisticsView(),
            "Vocabulary" => new VocabularyView(),
            "Notes" => new NotesView(),
            "GettingStarted" => new GettingStartedView(),
            "Settings" => new SettingsView(),
            _ => null
        };

        if (view != null)
        {
            ContentArea.Content = view;
        }
    }

    private void OnRecordButtonClick(object sender, RoutedEventArgs e)
    {
        _viewModel.StartRecordingCommand.Execute(null);
    }
}
