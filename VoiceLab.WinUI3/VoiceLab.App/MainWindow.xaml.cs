using Microsoft.UI.Xaml;
using VoiceLab.App.Views;

namespace VoiceLab.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        Title = "VoiceLab Echo";

        // Fit the onboarding and navigation layout inside the current work area.
        var appWindow = this.AppWindow;
        var display = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(appWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary);
        var workArea = display.WorkArea;
        var width = Math.Min(1200, Math.Max(1, workArea.Width - 32));
        var height = Math.Min(800, Math.Max(1, workArea.Height - 32));
        appWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
        appWindow.Move(new Windows.Graphics.PointInt32(workArea.X + (workArea.Width - width) / 2,
            workArea.Y + (workArea.Height - height) / 2));
        var iconPath = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "voicelab.ico");
        if (System.IO.File.Exists(iconPath)) appWindow.SetIcon(iconPath);

    }
}
