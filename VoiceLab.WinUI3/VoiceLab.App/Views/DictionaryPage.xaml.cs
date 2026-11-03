using Microsoft.UI.Xaml.Controls;

namespace VoiceLab.App.Views;

public sealed partial class DictionaryPage : Page
{
    public DictionaryPage()
    {
        InitializeComponent();
        VocabularyFrame.Navigate(typeof(VocabularyPage));
        SnippetsFrame.Navigate(typeof(SnippetsPage));
    }

    public void SelectSnippets(bool snippets) => DictionaryTabs.SelectedIndex = snippets ? 1 : 0;
}
