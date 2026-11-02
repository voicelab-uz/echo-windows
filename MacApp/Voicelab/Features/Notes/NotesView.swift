import SwiftUI
import VoiceLabCore

struct NotesView: View {
    let library: LibraryModel
    @State private var selection: UUID?
    @State private var query = ""
    /// Hiding the note list gives the editor the whole page.
    @AppStorage("notesListVisible") private var listVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var selectedNote: Note? { library.snapshot.notes.first(where: { $0.id == selection }) }
    private var notes: [Note] {
        library.snapshot.notes.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.body.localizedCaseInsensitiveContains(query)
        }
        .sorted { a, b in a.isPinned == b.isPinned ? a.updatedAt > b.updatedAt : a.isPinned }
    }
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var renameOriginalTitle = ""
    @State private var renameEditorID = UUID()
    @State private var deleting: Note?
    @FocusState private var renameFocused: Bool

    /// The list slides like a drawer. Without a selected note it is the only way forward,
    /// so it always shows then.
    private var showsList: Bool { listVisible || selectedNote == nil }
    private static let listWidth: CGFloat = 260

    var body: some View {
        HStack(spacing: 0) {
            // The panel keeps its full width and is revealed from the leading edge, so the
            // rows never squeeze while the drawer opens or closes.
            noteList
                .frame(width: Self.listWidth)
                .frame(width: showsList ? Self.listWidth : 0, alignment: .trailing)
                .clipped()
                .opacity(showsList ? 1 : 0)
            Rectangle().fill(Design.border).frame(width: showsList ? 1 : 0)
            Group {
                if let selected = selectedNote {
                    NoteEditor(library: library, noteID: selected.id, listVisible: listVisible) {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.34)) { listVisible.toggle() }
                    }
                    .id(selected.id)
                } else {
                    EmptyContent(
                        symbol: "note.text", title: AppLocalization.text("G‘oyalarga joy bering"),
                        subtitle: AppLocalization.text(
                            "Yangi qayd yarating yoki chap tomondan mavjud qaydni tanlang.")
                    )
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil { selection = notes.first?.id }
            library.requestNotesSync()
        }
        .onDisappear { library.setUnsavedEdit(renameEditorID, isDirty: false) }
        .onChange(of: library.snapshot.notes.map(\.id)) { _, ids in
            if selection == nil || !ids.contains(where: { $0 == selection }) {
                selection = notes.first?.id
            }
        }
        .confirmationDialog(AppLocalization.text("Qayd o‘chirilsinmi?"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(AppLocalization.text("O‘chirish"), role: .destructive) {
                if let deleting { library.removeNote(deleting.id) }
                deleting = nil
            }
        } message: {
            Text(AppLocalization.text("Bu amalni qaytarib bo‘lmaydi."))
        }
    }

    private var noteList: some View {
        VStack(spacing: 16) {
            HStack {
                AppIcon(systemName: "note.text").foregroundStyle(Design.accent)
                    .symbolRenderingMode(.hierarchical)
                Text(AppLocalization.text("Qaydlar")).font(.title3.weight(.semibold))
                Spacer()
                if library.notesSyncError != nil {
                    AppIcon(systemName: "icloud.slash")
                        .foregroundStyle(.orange)
                        .help(library.notesSyncError ?? "")
                        .accessibilityLabel(library.notesSyncError ?? "")
                } else if library.isSyncingNotes {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(AppLocalization.text("Qaydlar sinxronlanmoqda"))
                }
                Button {
                    let note = Note()
                    library.saveNote(note)
                    selection = note.id
                } label: {
                    AppIcon(systemName: "square.and.pencil")
                }.help(AppLocalization.text("Yangi qayd"))
            }.padding(.horizontal, 16).padding(.top, 22)
            WorkspaceSearchField(prompt: AppLocalization.text("Qaydlarni izlash"), text: $query).padding(
                .horizontal, 14)
            List(selection: $selection) {
                ForEach(notes) { note in
                    row(note).tag(note.id)
                        // Two-finger tap (or Control-click) opens the actions first.
                        .contextMenu { actions(for: note) }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
        }
        .background(Design.canvas)
    }

    @ViewBuilder private func row(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                if note.isPinned {
                    AppIcon(systemName: "pin.fill", size: 11).foregroundStyle(Design.accent)
                }
                if renaming == note.id {
                    TextField(AppLocalization.text("Qayd sarlavhasi"), text: Binding(get: { renameText }, set: { value in
                        renameText = value
                        library.setUnsavedEdit(renameEditorID, isDirty: value != renameOriginalTitle)
                    }))
                        .textFieldStyle(.plain).font(.callout.weight(.semibold))
                        .focused($renameFocused)
                        .onSubmit { commitRename(note) }
                        .onExitCommand {
                            library.setUnsavedEdit(renameEditorID, isDirty: false)
                            renaming = nil
                        }
                        .onChange(of: renameFocused) { _, focused in if !focused { commitRename(note) } }
                } else {
                    Text(displayTitle(note)).font(.callout.weight(.semibold)).lineLimit(1)
                }
            }
            Text(note.body.isEmpty ? AppLocalization.text("Yozishni boshlang…") : note.body)
                .font(.caption)
                .foregroundStyle(.secondary).lineLimit(2)
            Text(note.updatedAt, format: .dateTime.day().month(.abbreviated)).font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder private func actions(for note: Note) -> some View {
        Button(AppLocalization.text("Nomini o‘zgartirish")) { startRename(note) }
        Button(AppLocalization.text(note.isPinned ? "Mahkamlashni olib tashlash" : "Qaydni mahkamlash")) {
            var updated = note
            updated.isPinned.toggle()
            library.saveNote(updated)
        }
        Button(AppLocalization.text("Nusxalash")) { TextInsertion.copy(note.title + "\n\n" + note.body) }
        Divider()
        Button(AppLocalization.text("Qaydni o‘chirish"), role: .destructive) { deleting = note }
    }

    private func displayTitle(_ note: Note) -> String {
        note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppLocalization.text("Yangi qayd") : note.title
    }

    private func startRename(_ note: Note) {
        selection = note.id
        renameText = note.title
        renameOriginalTitle = note.title
        library.setUnsavedEdit(renameEditorID, isDirty: false)
        renaming = note.id
        Task { @MainActor in renameFocused = true }
    }

    private func commitRename(_ note: Note) {
        guard renaming == note.id else { return }
        defer { library.setUnsavedEdit(renameEditorID, isDirty: false) }
        renaming = nil
        guard var updated = library.snapshot.notes.first(where: { $0.id == note.id }),
              updated.title != renameText else { return }
        updated.title = renameText
        library.saveNote(updated)
    }
}

private struct NoteEditor: View {
    let library: LibraryModel
    let noteID: UUID
    let listVisible: Bool
    let toggleList: () -> Void
    private var note: Note { library.snapshot.notes.first { $0.id == noteID } ?? Note() }
    private func field<Value>(_ keyPath: WritableKeyPath<Note, Value>) -> Binding<Value> {
        Binding(
            get: { note[keyPath: keyPath] },
            set: { value in
                guard var updated = library.snapshot.notes.first(where: { $0.id == noteID }) else { return }
                updated[keyPath: keyPath] = value
                library.saveNote(updated)
            })
    }
    @State private var confirmDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button(action: toggleList) {
                    Image(systemName: "sidebar.left").frame(width: 20, height: 20)
                }
                .help(AppLocalization.text(listVisible ? "Yon menyuni yashirish" : "Yon menyuni ko‘rsatish"))
                .accessibilityLabel(AppLocalization.text(listVisible ? "Yon menyuni yashirish" : "Yon menyuni ko‘rsatish"))
                Text(note.updatedAt, format: .dateTime.day().month(.wide).hour().minute()).font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    field(\.isPinned).wrappedValue.toggle()
                } label: {
                    AppIcon(systemName: note.isPinned ? "pin.fill" : "pin")
                }.help(AppLocalization.text("Qaydni mahkamlash"))
                Button {
                    TextInsertion.copy(note.title + "\n\n" + note.body)
                } label: {
                    AppIcon(systemName: "doc.on.doc")
                }.help(AppLocalization.text("Nusxalash"))
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    AppIcon(systemName: "trash")
                }.help(AppLocalization.text("Qaydni o‘chirish"))
            }.buttonStyle(.echoPlain).foregroundStyle(.secondary)
            if library.notesSyncConflict {
                HStack {
                    AppLabel(
                        AppLocalization.text(
                            "Boshqa qurilmadagi tahrir ham saqlandi. Qaydlar ro‘yxatini tekshiring."),
                        systemImage: "doc.on.doc")
                    Spacer()
                    Button {
                        library.dismissNotesConflict()
                    } label: {
                        AppIcon(systemName: "xmark")
                    }
                    .buttonStyle(.plain).accessibilityLabel(AppLocalization.text("Yopish"))
                }.font(.caption).foregroundStyle(.secondary)
            }
            TextField(AppLocalization.text("Qayd sarlavhasi"), text: field(\.title)).textFieldStyle(.plain)
                .font(
                    .system(size: 27, weight: .semibold))
            Divider()
            TextEditor(text: field(\.body)).font(.system(size: 15)).lineSpacing(7).scrollContentBackground(
                .hidden
            )
            .accessibilityLabel(AppLocalization.text("Qayd matni"))
            HStack {
                Text(AppLocalization.text("%d so‘z", note.body.split(whereSeparator: \.isWhitespace).count))
                    .font(.caption2)
                Spacer()
                if library.saveError != nil {
                    AppLabel(AppLocalization.text("Saqlash xatosi"), systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                }
            }.foregroundStyle(.secondary)
        }.padding(28).background(Design.surface)
            .confirmationDialog(AppLocalization.text("Qayd o‘chirilsinmi?"), isPresented: $confirmDelete) {
                Button(AppLocalization.text("O‘chirish"), role: .destructive) { library.removeNote(note.id) }
            } message: {
                Text(AppLocalization.text("Bu amalni qaytarib bo‘lmaydi."))
            }
    }
}
