import SwiftUI
import VoiceLabCore

/// Add or edit one dictionary entry or snippet.
///
/// Dictionary: a plain word Echo should spell exactly, or — with "Correct a misspelling"
/// on — a pair: whenever the misspelling is heard it is written as the correct spelling.
/// Snippets: a short phrase to say, and the text that is written in its place.
struct VocabularyEntrySheet: View {
    let library: LibraryModel
    let kind: VocabularyTab
    private let original: VocabularyEntry
    private let isNew: Bool
    @State private var word: String
    @State private var replacement: String
    @State private var correcting: Bool
    @State private var language: VocabularyLanguage
    @State private var editorID = UUID()
    @State private var showsInfo = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    private enum Field { case word, replacement }

    init(library: LibraryModel, kind: VocabularyTab, entry: VocabularyEntry?, defaultLanguage: VocabularyLanguage) {
        self.library = library
        self.kind = kind
        isNew = entry == nil
        let value = entry ?? VocabularyEntry(word: "", language: kind == .dictionary ? defaultLanguage : .all)
        original = value
        _word = State(initialValue: value.word)
        _replacement = State(initialValue: value.replacement)
        _correcting = State(initialValue: value.isCorrection)
        _language = State(initialValue: value.language)
    }

    private var title: String {
        if !isNew { return "Tahrirlash" }
        return kind == .dictionary ? "Lug‘atga qo‘shish" : "Ibora qo‘shish"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppLocalization.text(title)).font(.system(size: 18, weight: .semibold))
            if kind == .dictionary { dictionaryFields } else { snippetFields }
            if let error { ErrorBanner(message: error) { self.error = nil } }
            HStack(spacing: 10) {
                Spacer()
                Button(AppLocalization.text("Bekor qilish")) {
                    library.setUnsavedEdit(editorID, isDirty: false)
                    dismiss()
                }
                    .buttonStyle(.echo).keyboardShortcut(.cancelAction)
                Button(AppLocalization.text(isNew ? (kind == .dictionary ? "So‘zni qo‘shish" : "Ibora qo‘shish") : "Saqlash"),
                       action: save)
                    .buttonStyle(.echoProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24).frame(width: 480)
        .onAppear { focus = .word; updateDirtyState() }
        .onDisappear { library.setUnsavedEdit(editorID, isDirty: false) }
        .animation(.snappy(duration: 0.2), value: correcting)
    }

    private var dictionaryFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Text(AppLocalization.text("Xato yozilishni tuzatish")).font(.system(size: 13))
                Button { showsInfo.toggle() } label: {
                    WorkspaceAssetIcon(name: .info, size: 14).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.text(
                    "Echo bu so‘zni eshitganda uni avtomatik ravishda to‘g‘ri yozuvga almashtiradi."))
                .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
                    Text(AppLocalization.text(
                        "Echo bu so‘zni eshitganda uni avtomatik ravishda to‘g‘ri yozuvga almashtiradi."))
                        .font(.system(size: 12)).padding(12).frame(width: 240)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: tracking($correcting)).toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel(AppLocalization.text("Xato yozilishni tuzatish"))
            }
            if correcting {
                HStack(spacing: 10) {
                    field(AppLocalization.text("Xato yozilish"), text: tracking($word), focus: .word)
                    AppIcon(systemName: "arrow.right", size: 12).foregroundStyle(.secondary)
                    field(AppLocalization.text("To‘g‘ri yozilish"), text: tracking($replacement), focus: .replacement)
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 10) {
                    field(AppLocalization.text("Yangi so‘z qo‘shing"), text: tracking($word), focus: .word)
                    Picker(AppLocalization.text("Til"), selection: tracking($language)) {
                        ForEach(VocabularyLanguage.allCases) { Text(AppLocalization.text($0.title)).tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                }
                .transition(.opacity)
            }
        }
    }

    private var snippetFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalization.text("Shuni ayting")).font(.caption).foregroundStyle(.secondary)
                field("“telegramim”", text: tracking($word), focus: .word)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalization.text("Shu matn yoziladi")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: tracking($replacement)).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 120).focused($focus, equals: .replacement)
                    .background(Design.canvas, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Design.border, lineWidth: 0.75))
                    .accessibilityLabel(AppLocalization.text("Shu matn yoziladi"))
            }
        }
    }

    private func field(_ prompt: String, text: Binding<String>, focus field: Field) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 12).frame(height: 36)
            .background(Design.canvas, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(focus == field ? Design.tint.opacity(0.6) : Design.border, lineWidth: focus == field ? 1.5 : 0.75))
            .focused($focus, equals: field)
            .onSubmit { if field == .word && needsReplacement { focus = .replacement } else { save() } }
    }

    private var needsReplacement: Bool { kind == .snippets || correcting }

    private func tracking<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { value in
            binding.wrappedValue = value
            updateDirtyState()
        })
    }

    private func updateDirtyState() {
        library.setUnsavedEdit(editorID, isDirty: word != original.word || replacement != original.replacement
            || correcting != original.isCorrection || language != original.language)
    }

    private var canSave: Bool {
        library.isReady && !VocabularyRules.cleanWord(word).isEmpty
            && (!needsReplacement || !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func save() {
        guard canSave else { return }
        var value = original
        value.word = word
        value.replacement = needsReplacement ? replacement : ""
        value.isCorrection = kind == .dictionary && correcting
        value.language = kind == .dictionary && !correcting ? language : .all
        do {
            try library.saveVocabulary(value)
            library.setUnsavedEdit(editorID, isDirty: false)
            dismiss()
        } catch { self.error = AppLocalization.error(error) }
    }
}
