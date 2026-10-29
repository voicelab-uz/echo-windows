using System.Windows.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLabEcho.App.ViewModels;

namespace VoiceLabEcho.App.Views;

public partial class StatisticsView : UserControl
{
    public StatisticsView()
    {
        InitializeComponent();
        DataContext = App.ServiceProvider.GetRequiredService<StatisticsViewModel>();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, System.Windows.RoutedEventArgs e)
    {
        if (DataContext is StatisticsViewModel viewModel)
        {
            await viewModel.LoadStatisticsAsync();
        }
    }
}
