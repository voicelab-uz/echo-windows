using System.Windows.Controls;
using Microsoft.Extensions.DependencyInjection;
using VoiceLabEcho.App.ViewModels;

namespace VoiceLabEcho.App.Views;

public partial class SettingsView : UserControl
{
    public SettingsView()
    {
        InitializeComponent();
        DataContext = App.ServiceProvider.GetRequiredService<SettingsViewModel>();
    }
}
