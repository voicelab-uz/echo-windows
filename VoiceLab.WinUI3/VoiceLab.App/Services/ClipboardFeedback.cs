using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace VoiceLab.App.Services;

public static class ClipboardFeedback
{
    private sealed class State
    {
        public object? OriginalContent;
        public double OriginalMinWidth;
        public int Version;
        public bool Active;
    }

    private static readonly ConditionalWeakTable<Button, State> States = new();

    public static async Task CopyAsync(Button button, string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        Clipboard.Flush();

        var state = States.GetValue(button, static _ => new State());
        if (!state.Active)
        {
            state.OriginalContent = button.Content;
            state.OriginalMinWidth = button.MinWidth;
            state.Active = true;
        }
        var version = ++state.Version;
        button.MinWidth = Math.Max(button.MinWidth, button.ActualWidth);
        button.Content = "Copied";
        await Task.Delay(1500);
        if (version != state.Version) return;
        button.Content = state.OriginalContent;
        button.MinWidth = state.OriginalMinWidth;
        state.Active = false;
    }
}
