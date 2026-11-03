using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views;

public sealed partial class NotesPage : Page
{
    private readonly INotesService _notesService = (INotesService)App.Services.GetService(typeof(INotesService))!;
    private readonly List<Note> _notes = new();
    private List<NoteFolder> _folders = new();
    private Note? _activeNote;
    private bool _loadingFolders;
    private readonly SemaphoreSlim _syncGate = new(1, 1);
    private readonly SemaphoreSlim _saveGate = new(1, 1);
    private readonly DispatcherTimer _autoSaveTimer = new() { Interval = TimeSpan.FromMilliseconds(700) };
    private bool _loadingEditor;
    private bool _draftChanged;
    private bool _savingLocal;
    private int _draftVersion;

    public NotesPage()
    {
        InitializeComponent();
        TitleBox.TextChanged += OnDraftChanged;
        ContentBox.TextChanged += OnDraftChanged;
        PinnedCheckBox.Checked += OnDraftChanged;
        PinnedCheckBox.Unchecked += OnDraftChanged;
        NoteFolderSelector.SelectionChanged += OnDraftChanged;
        _autoSaveTimer.Tick += OnAutoSaveTick;
        Loaded += async (_, _) =>
        {
            try { await LoadFoldersAsync(); await LoadNotesAsync(); await SyncAndRefreshAsync(); }
            catch (Exception ex) { NoteStatus.Text = $"Could not load notes: {ex.Message}"; }
        };
        Unloaded += (_, _) => _autoSaveTimer.Stop();
    }

    protected override void OnNavigatingFrom(NavigatingCancelEventArgs e)
    {
        if (_draftChanged || _savingLocal)
        {
            e.Cancel = true;
            NoteStatus.Text = "Save or discard your changes before leaving Notes.";
            return;
        }
        base.OnNavigatingFrom(e);
    }

    private void OnDraftChanged(object sender, RoutedEventArgs e)
    {
        if (_loadingEditor) return;
        _draftChanged = true;
        _draftVersion++;
        _autoSaveTimer.Stop();
        _autoSaveTimer.Start();
        NoteStatus.Text = "Saving shortly…";
        NotesList.IsEnabled = false;
        NewNoteButton.IsEnabled = false;
        DiscardButton.IsEnabled = !_savingLocal;
        DeleteButton.IsEnabled = false;
    }

    private void OnPageSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var narrow = e.NewSize.Width < 760;
        PageGrid.Padding = new Thickness(e.NewSize.Width < 560 ? 16 : 28);
        NotesContentGrid.ColumnDefinitions[0].Width = narrow ? new GridLength(1, GridUnitType.Star) : new GridLength(300);
        NotesContentGrid.ColumnDefinitions[1].Width = narrow ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        NotesContentGrid.RowDefinitions[0].Height = narrow ? new GridLength(230) : new GridLength(1, GridUnitType.Star);
        NotesContentGrid.RowDefinitions[1].Height = narrow ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        Grid.SetRow(EditorCard, narrow ? 1 : 0);
        Grid.SetColumn(EditorCard, narrow ? 0 : 1);
        Grid.SetRow(NewNoteButton, e.NewSize.Width < 560 ? 1 : 0);
        Grid.SetColumn(NewNoteButton, e.NewSize.Width < 560 ? 0 : 1);
        NewNoteButton.HorizontalAlignment = e.NewSize.Width < 560 ? HorizontalAlignment.Left : HorizontalAlignment.Right;
    }

    private async Task SyncAndRefreshAsync(bool refreshEditor = true)
    {
        await _syncGate.WaitAsync();
        try
        {
            var conflicts = await _notesService.SyncAsync();
            if ((refreshEditor || conflicts > 0) && !_draftChanged) await LoadNotesAsync();
            else await RefreshListPreservingEditorAsync();
            NoteStatus.Text = conflicts > 0
                ? $"Synced. {conflicts} conflicting edit(s) were preserved as copies."
                : _draftChanged ? "Cloud synced. Save your current edit when ready." : "Synced with VoiceLab";
        }
        catch (Exception ex)
        {
            NoteStatus.Text = $"Saved on this PC. Cloud sync pending: {ex.Message}";
        }
        finally { _syncGate.Release(); }
    }

    private async Task LoadFoldersAsync()
    {
        _folders = await _notesService.GetFoldersAsync();
        var selectedTag = (FolderFilter.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "all";
        _loadingFolders = true;
        while (FolderFilter.Items.Count > 2) FolderFilter.Items.RemoveAt(2);
        while (NoteFolderSelector.Items.Count > 1) NoteFolderSelector.Items.RemoveAt(1);
        foreach (var folder in _folders.OrderBy(item => item.Name))
        {
            FolderFilter.Items.Add(new ComboBoxItem { Content = folder.Name, Tag = folder.Id });
            NoteFolderSelector.Items.Add(new ComboBoxItem { Content = folder.Name, Tag = folder.Id });
        }
        FolderFilter.SelectedItem = FolderFilter.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => item.Tag?.ToString() == selectedTag) ?? FolderFilter.Items[0];
        _loadingFolders = false;
        OnFolderFilterChanged(this, new SelectionChangedEventArgs(new List<object>(), new List<object>()));
    }

    private void OnFolderFilterChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingFolders || NotesList is null || RenameFolderButton is null || DeleteFolderButton is null) return;
        var isFolder = _folders.Any(item => item.Id == (FolderFilter.SelectedItem as ComboBoxItem)?.Tag?.ToString());
        RenameFolderButton.IsEnabled = isFolder;
        DeleteFolderButton.IsEnabled = isFolder;
        ApplyFolderFilter();
    }

    private void ApplyFolderFilter()
    {
        if (NotesList is null) return;
        var tag = (FolderFilter.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "all";
        var visible = tag switch
        {
            "all" => _notes.ToList(),
            "unfiled" => _notes.Where(note => string.IsNullOrEmpty(note.FolderId)).ToList(),
            _ => _notes.Where(note => note.FolderId == tag).ToList()
        };
        NotesList.ItemsSource = null;
        NotesList.ItemsSource = visible;
        if (_activeNote is not null) NotesList.SelectedItem = visible.FirstOrDefault(note => note.Id == _activeNote.Id);
    }

    private async Task LoadNotesAsync()
    {
        try
        {
            var selectedId = _activeNote?.Id;
            _notes.Clear();
            _notes.AddRange(await _notesService.GetNotesAsync());
            _activeNote = selectedId is null ? null : _notes.FirstOrDefault(note => note.Id == selectedId);
            ApplyFolderFilter();
            if (_activeNote is null && NotesList.Items.Count > 0 && TitleBox.Text.Length == 0) NotesList.SelectedIndex = 0;
            else if (_notes.Count == 0) OnNewNoteClick(this, new RoutedEventArgs());
        }
        catch (Exception ex) { NoteStatus.Text = $"Could not load notes: {ex.Message}"; }
    }

    private async Task RefreshListPreservingEditorAsync()
    {
        var selectedId = _activeNote?.Id;
        var current = await _notesService.GetNotesAsync();
        _loadingEditor = true;
        try
        {
            _notes.Clear();
            _notes.AddRange(current);
            _activeNote = selectedId is null ? null : _notes.FirstOrDefault(note => note.Id == selectedId);
            ApplyFolderFilter();
        }
        finally { _loadingEditor = false; }
    }

    private void OnNewNoteClick(object sender, RoutedEventArgs e)
    {
        if (_draftChanged || _savingLocal) return;
        _autoSaveTimer.Stop();
        _loadingEditor = true;
        _activeNote = null;
        NotesList.SelectedItem = null;
        TitleBox.Text = string.Empty;
        ContentBox.Text = string.Empty;
        PinnedCheckBox.IsChecked = false;
        var filter = (FolderFilter.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        NoteFolderSelector.SelectedItem = NoteFolderSelector.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => item.Tag?.ToString() == filter) ?? NoteFolderSelector.Items[0];
        NoteStatus.Text = "Unsaved note";
        _draftChanged = false;
        _loadingEditor = false;
        NotesList.IsEnabled = true;
        NewNoteButton.IsEnabled = true;
        DiscardButton.IsEnabled = false;
        SaveButton.IsEnabled = true;
        DeleteButton.IsEnabled = false;
        TitleBox.Focus(FocusState.Programmatic);
    }

    private void OnNoteSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_draftChanged || _savingLocal || _loadingEditor) return;
        if (NotesList.SelectedItem is not Note note) return;
        _autoSaveTimer.Stop();
        _loadingEditor = true;
        _activeNote = note;
        TitleBox.Text = note.Title;
        ContentBox.Text = note.Content;
        PinnedCheckBox.IsChecked = note.IsPinned;
        NoteFolderSelector.SelectedItem = NoteFolderSelector.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => item.Tag?.ToString() == note.FolderId) ?? NoteFolderSelector.Items[0];
        NoteStatus.Text = $"Edited {note.UpdatedAt.LocalDateTime:g}";
        _draftChanged = false;
        _loadingEditor = false;
        NotesList.IsEnabled = true;
        NewNoteButton.IsEnabled = true;
        DiscardButton.IsEnabled = false;
        SaveButton.IsEnabled = true;
        DeleteButton.IsEnabled = true;
    }

    private async void OnAutoSaveTick(object? sender, object e)
    {
        _autoSaveTimer.Stop();
        if (await PersistCurrentAsync()) await SyncAndRefreshAsync(refreshEditor: false);
    }

    private async void OnSaveClick(object sender, RoutedEventArgs e)
    {
        _autoSaveTimer.Stop();
        if (await PersistCurrentAsync()) await SyncAndRefreshAsync();
    }

    private async Task<bool> PersistCurrentAsync()
    {
        await _saveGate.WaitAsync();
        try
        {
            if (!_draftChanged && _activeNote is not null) return true;
            _savingLocal = true;
            SaveButton.IsEnabled = false;
            DiscardButton.IsEnabled = false;
            var version = _draftVersion;
            var title = TitleBox.Text;
            var body = ContentBox.Text;
            var folderId = (NoteFolderSelector.SelectedItem as ComboBoxItem)?.Tag?.ToString();
            var pinned = PinnedCheckBox.IsChecked == true;
            var selected = _activeNote;
            Note saved;
            if (selected is null)
                saved = await _notesService.CreateNoteAsync(title, body,
                    string.IsNullOrEmpty(folderId) ? null : folderId, pinned);
            else
            {
                // Save a snapshot so a failed write cannot change the displayed stored note.
                saved = new Note
                {
                    Id = selected.Id, Title = title, Content = body,
                    FolderId = string.IsNullOrEmpty(folderId) ? null : folderId,
                    IsPinned = pinned, CreatedAt = selected.CreatedAt, UpdatedAt = selected.UpdatedAt
                };
                await _notesService.UpdateNoteAsync(saved);
            }
            if (ReferenceEquals(_activeNote, selected)) _activeNote = saved;
            await RefreshListPreservingEditorAsync();
            if (version == _draftVersion)
            {
                _draftChanged = false;
                NotesList.IsEnabled = true;
                NewNoteButton.IsEnabled = true;
                DeleteButton.IsEnabled = _activeNote is not null;
                NoteStatus.Text = "Saved on this PC";
            }
            else
            {
                NoteStatus.Text = "Saving latest changes…";
                _autoSaveTimer.Stop();
                _autoSaveTimer.Start();
            }
            return true;
        }
        catch (Exception ex)
        {
            NoteStatus.Text = "Could not save note: " + ex.Message;
            return false;
        }
        finally
        {
            _savingLocal = false;
            SaveButton.IsEnabled = true;
            DiscardButton.IsEnabled = _draftChanged;
            _saveGate.Release();
        }
    }

    private async void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (_activeNote is null || _draftChanged || _savingLocal) return;
        DeleteButton.IsEnabled = false;
        try
        {
            await _notesService.DeleteNoteAsync(_activeNote.Id);
            _activeNote = null;
            TitleBox.Text = string.Empty;
            ContentBox.Text = string.Empty;
            PinnedCheckBox.IsChecked = false;
            NoteStatus.Text = "Note deleted";
            await LoadNotesAsync();
            await SyncAndRefreshAsync();
        }
        catch (Exception ex) { NoteStatus.Text = ex.Message; DeleteButton.IsEnabled = true; }
    }

    private void OnDiscardClick(object sender, RoutedEventArgs e)
    {
        if (_savingLocal) return;
        _autoSaveTimer.Stop();
        _draftVersion++;
        _loadingEditor = true;
        if (_activeNote is null)
        {
            TitleBox.Text = "";
            ContentBox.Text = "";
            PinnedCheckBox.IsChecked = false;
            NoteStatus.Text = "New note";
        }
        else
        {
            TitleBox.Text = _activeNote.Title;
            ContentBox.Text = _activeNote.Content;
            PinnedCheckBox.IsChecked = _activeNote.IsPinned;
            NoteFolderSelector.SelectedItem = NoteFolderSelector.Items.OfType<ComboBoxItem>()
                .FirstOrDefault(item => item.Tag?.ToString() == _activeNote.FolderId) ?? NoteFolderSelector.Items[0];
            NoteStatus.Text = "Changes discarded";
        }
        _draftChanged = false;
        _loadingEditor = false;
        NotesList.IsEnabled = true;
        NewNoteButton.IsEnabled = true;
        DiscardButton.IsEnabled = false;
        DeleteButton.IsEnabled = _activeNote is not null;
    }

    private async void OnNewFolderClick(object sender, RoutedEventArgs e)
    {
        var input = new TextBox { PlaceholderText = "Folder name", MaxLength = 80 };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "New folder", Content = input,
            PrimaryButtonText = "Create", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            var folder = await _notesService.CreateFolderAsync(input.Text);
            await LoadFoldersAsync();
            FolderFilter.SelectedItem = FolderFilter.Items.OfType<ComboBoxItem>().First(item => item.Tag?.ToString() == folder.Id);
            NoteStatus.Text = $"Folder {folder.Name} created.";
        }
        catch (Exception ex) { NoteStatus.Text = ex.Message; }
    }

    private async void OnRenameFolderClick(object sender, RoutedEventArgs e)
    {
        var id = (FolderFilter.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        var folder = _folders.FirstOrDefault(item => item.Id == id);
        if (folder is null) return;
        var input = new TextBox { Text = folder.Name, MaxLength = 80 };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Rename folder", Content = input,
            PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            await _notesService.RenameFolderAsync(folder.Id, input.Text);
            await LoadFoldersAsync();
            NoteStatus.Text = "Folder renamed.";
        }
        catch (Exception ex) { NoteStatus.Text = ex.Message; }
    }

    private async void OnDeleteFolderClick(object sender, RoutedEventArgs e)
    {
        var id = (FolderFilter.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        var folder = _folders.FirstOrDefault(item => item.Id == id);
        if (folder is null) return;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = $"Delete {folder.Name}?",
            Content = "Notes in this folder will move to Unfiled.",
            PrimaryButtonText = "Delete folder", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            await _notesService.DeleteFolderAsync(folder.Id);
            await LoadFoldersAsync();
            await LoadNotesAsync();
            NoteStatus.Text = "Folder deleted. Its notes are now Unfiled.";
        }
        catch (Exception ex) { NoteStatus.Text = ex.Message; }
    }
}
