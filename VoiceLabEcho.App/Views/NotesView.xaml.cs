using System.Windows.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLabEcho.App.ViewModels;

namespace VoiceLabEcho.App.Views;

public partial class NotesView : UserControl
{
    public NotesView()
    {
        InitializeComponent();
        DataContext = App.ServiceProvider.GetRequiredService<NotesViewModel>();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, System.Windows.RoutedEventArgs e)
    {
        if (DataContext is NotesViewModel viewModel)
        {
            await viewModel.LoadNotesAsync();
        }
    }
}
