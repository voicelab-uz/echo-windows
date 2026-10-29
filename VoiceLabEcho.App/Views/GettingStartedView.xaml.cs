using System.Windows.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLabEcho.App.ViewModels;

namespace VoiceLabEcho.App.Views;

public partial class GettingStartedView : UserControl
{
    public GettingStartedView()
    {
        InitializeComponent();
        DataContext = App.ServiceProvider.GetRequiredService<GettingStartedViewModel>();
    }
}
