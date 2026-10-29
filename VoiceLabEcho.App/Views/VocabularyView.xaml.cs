using System.Windows.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLabEcho.App.ViewModels;

namespace VoiceLabEcho.App.Views;

public partial class VocabularyView : UserControl
{
    public VocabularyView()
    {
        InitializeComponent();
        DataContext = App.ServiceProvider.GetRequiredService<VocabularyViewModel>();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, System.Windows.RoutedEventArgs e)
    {
        if (DataContext is VocabularyViewModel viewModel)
        {
            await viewModel.LoadVocabularyAsync();
        }
    }
}
