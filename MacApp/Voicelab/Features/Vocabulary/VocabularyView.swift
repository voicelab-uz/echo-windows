import SwiftUI
import UniformTypeIdentifiers
import VoiceLabCore

/// Dictionary and Snippets, laid out like the rest of the workspace: a title with its
/// actions, a tab row with the tools on the right, and one bordered list.
///
/// - Dictionary: words Echo should spell exactly, plus corrections ("misspelling → right
///   spelling") that are rewritten automatically whenever they are heard.
/// - Snippets: say a short phrase and Echo writes the saved text instead.
struct VocabularyView: View {
    let library: LibraryModel
    @State private var tab: VocabularyTab = .dictionary
    @State private var query = ""
    @State private var language: VocabularyLanguage = .all
    @State private var bulkText = ""
    @State private var showsImport = false
    @State private var confirmsClear = false
    @State private var sheet: VocabularySheet?
    @State private var exporting = false
    @State private var exportDocument = VocabularyDocument(text: "")
    @State private var error: String?
    @State private var importSummary: String?
    @AppStorage("snippetsIntroDismissed") private var snippetsIntroDismissed = false
    @AppStorage("dictionaryIntroDismissed") private var dictionaryIntroDismissed = false
    private var introDismissed: Bool { tab == .dictionary ? dictionaryIntroDismissed : snippetsIntroDismissed }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dictionary: [VocabularyEntry] { library.snapshot.vocabulary.filter { !$0.isPhrase } }
    private var phrases: [VocabularyEntry] { library.snapshot.vocabulary.filter(\.isPhrase) }
    private var entries: [VocabularyEntry] {
        (tab == .dictionary ? dictionary : phrases).filter { entry in
            (tab == .snippets || language == .all || entry.language == language)
                && (query.isEmpty || entry.word.localizedCaseInsensitiveContains(query)
                    || entry.replacement.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 26)
                tabRow.padding(.bottom, 20)
                if let error { ErrorBanner(message: error) { self.error = nil }.padding(.bottom, 14) }
                if let importSummary {
                    Text(importSummary).font(.caption).foregroundStyle(.secondary).padding(.bottom, 14)
                }
                if tab == .dictionary && showsImport {
                    importPanel.padding(.bottom, 18)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                if !introDismissed {
                    intro.padding(.bottom, 22).transition(.opacity)
                }
                entryList
            }
            .frame(maxWidth: 880).padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .disabled(!library.isReady)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: showsImport)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: introDismissed)
        .onChange(of: tab) { _, _ in
            error = nil
            importSummary = nil
            query = ""
            showsImport = false
        }
        .confirmationDialog(
            AppLocalization.text("Lug‘atdagi barcha so‘zlar o‘chirilsinmi?"),
            isPresented: $confirmsClear, titleVisibility: .visible
        ) {
            Button(AppLocalization.text("Barchasini o‘chirish"), role: .destructive) { library.clearDictionary() }
        } message: {
            Text(AppLocalization.text("Iboralar saqlanib qoladi. Bu amalni bekor qilib bo‘lmaydi."))
        }
        .sheet(item: $sheet) { sheet in
            VocabularyEntrySheet(library: library, kind: sheet.kind, entry: sheet.entry, defaultLanguage: language)
        }
        .fileExporter(
            isPresented: $exporting, document: exportDocument,
            contentType: .plainText, defaultFilename: "dictionary.txt"
        ) { result in
            if case .failure(let failure) = result { error = AppLocalization.error(failure) }
        }
    }

    // MARK: Header and tools

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AppLocalization.text(tab.title))
                .font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                if tab == .dictionary {
                    Button(AppLocalization.text("Import")) { showsImport.toggle() }
                        .buttonStyle(.echo)
                }
                Button(AppLocalization.text("Yangi qo‘shish")) { sheet = VocabularySheet(kind: tab, entry: nil) }
                    .buttonStyle(.echoProminent)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    /// Tabs on the left, then search, filter and the count, all one height and one style.
    private var tabRow: some View {
        HStack(spacing: 22) {
            ForEach(VocabularyTab.allCases) { item in
                Button { tab = item } label: {
                    Text(AppLocalization.text(item.title))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tab == item ? Design.accent : Color.secondary)
                        .padding(.bottom, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(tab == item ? Design.tint : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ExpandingSearchField(prompt: AppLocalization.text("Izlash"), text: $query, width: 200)
                if tab == .dictionary {
                    toolMenu {
                        Picker(AppLocalization.text("Til"), selection: $language) {
                            ForEach(VocabularyLanguage.allCases) { Text(AppLocalization.text($0.title)).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 5) {
                            AppIcon(systemName: "globe", size: 12)
                            Text(AppLocalization.text(language.title)).lineLimit(1)
                        }
                    }
                    .help(AppLocalization.text("Til"))
                    if !dictionary.isEmpty {
                        toolMenu {
                            Button(AppLocalization.text("Lug‘atni eksport qilish")) {
                                exportDocument = VocabularyDocument(text: dictionary.map(\.word).joined(separator: "\n"))
                                exporting = true
                            }
                            Divider()
                            Button(AppLocalization.text("Barchasini o‘chirish"), role: .destructive) { confirmsClear = true }
                        } label: {
                            AppIcon(systemName: "ellipsis", size: 12)
                        }
                    }
                }
                Text(AppLocalization.text(tab == .dictionary ? "%d so‘z" : "%d ibora",
                                          tab == .dictionary ? dictionary.count : phrases.count))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Design.border).frame(height: 1) }
    }

    /// A compact menu that looks exactly like the search pill beside it.
    private func toolMenu<Content: View, Label: View>(
        @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label
    ) -> some View {
        Menu(content: content, label: label)
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.text("So‘zlarni vergul yoki yangi qator bilan ajrating."))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $bulkText).font(.body).scrollContentBackground(.hidden)
                .frame(height: 95).padding(6)
                .background(Design.canvas, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text(AppLocalization.text("%d so‘z tayyor", VocabularyRules.words(in: bulkText).count))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(AppLocalization.text("Bekor qilish")) { showsImport = false }.buttonStyle(.echo)
                Button(AppLocalization.text("Import")) { importWords() }
                    .buttonStyle(.echoProminent)
                    .disabled(VocabularyRules.words(in: bulkText).isEmpty)
            }
        }
        .padding(16)
        .background(Design.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Design.border, lineWidth: 0.75))
    }

    /// Explains the current tab with two examples until the person closes it.
    private var intro: some View {
        let dictionary = tab == .dictionary
        return VStack(alignment: .leading, spacing: 14) {
            Text(AppLocalization.text(dictionary ? "Echo so‘zlaringizni siz xohlagandek yozadi."
                                                 : "Qayta yozish shart bo‘lmagan matnlar."))
                .font(.system(size: 26, weight: .regular, design: .serif))
                .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Text(AppLocalization.text(dictionary
                ? "Ismlar va atamalarni qo‘shing yoki Echo noto‘g‘ri eshitadigan so‘zni to‘g‘risiga almashtiring — har safar avtomatik tuzatiladi."
                : "Tez-tez yoziladigan matnni saqlang — email, tanishtiruv yoki prompt — keyin bir iborani aytib, uni darhol qo‘ying."))
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                if dictionary {
                    exampleChip("“voys lab”", "VoiceLab")
                    exampleChip("“toshkant”", "Toshkent")
                } else {
                    exampleChip("“telegramim”", "t.me/voicelab")
                    exampleChip("“emailim”", "salom@voicelab.uz")
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            Button(AppLocalization.text(dictionary ? "So‘zni qo‘shish" : "Yangi ibora qo‘shish")) {
                sheet = VocabularySheet(kind: tab, entry: nil)
            }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 14).frame(height: 32)
                .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [Color(red: 0.09, green: 0.12, blue: 0.22), Color(red: 0.2, green: 0.17, blue: 0.24),
                                    Color(red: 0.32, green: 0.24, blue: 0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                if tab == .dictionary { dictionaryIntroDismissed = true } else { snippetsIntroDismissed = true }
            } label: {
                AppIcon(systemName: "xmark", size: 10).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(.white.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain).padding(14)
            .accessibilityLabel(AppLocalization.text("Yopish"))
        }
    }

    private func exampleChip(_ trigger: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(trigger).italic()
                .padding(.horizontal, 10).frame(height: 26)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            AppIcon(systemName: "arrow.right", size: 10).foregroundStyle(.white.opacity(0.7))
            Text(text)
                .padding(.horizontal, 10).frame(height: 26)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
    }

    // MARK: List

    private var entryList: some View {
        let visible = entries
        return VStack(spacing: 0) {
            if visible.isEmpty {
                VStack(spacing: 10) {
                    WorkspaceIcon(symbol: tab == .dictionary ? "character.book.closed" : "text.bubble", size: 52)
                    Text(AppLocalization.text(emptyTitle)).font(.system(size: 13, weight: .medium))
                    Text(AppLocalization.text(tab == .dictionary
                        ? "Ismlar va maxsus atamalarni shu yerda saqlang."
                        : "Qisqa iborani ayting — o‘rniga saqlangan matn yoziladi."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 44)
            } else {
                ForEach(visible) { entry in
                    VocabularyRow(entry: entry,
                                  edit: { sheet = VocabularySheet(kind: tab, entry: entry) },
                                  remove: { library.removeVocabulary(entry.id) })
                    if entry.id != visible.last?.id { Divider().padding(.leading, 16) }
                }
            }
        }
        .background(Design.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Design.border, lineWidth: 0.75))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyTitle: String {
        let all = tab == .dictionary ? dictionary : phrases
        return all.isEmpty
            ? (tab == .dictionary ? "Lug‘atingizni yarating" : "Birinchi iborangizni qo‘shing")
            : "Mos yozuv topilmadi"
    }

    private func importWords() {
        do {
            let result = try library.importVocabulary(bulkText, language: language)
            error = nil
            importSummary = result.skipped > 0
                ? AppLocalization.text("%d ta qo‘shildi, %d ta takroriy so‘z o‘tkazildi.", result.added, result.skipped)
                : nil
            if result.added > 0 {
                bulkText = ""
                showsImport = false
            }
        } catch { self.error = AppLocalization.error(error) }
    }
}

enum VocabularyTab: CaseIterable, Identifiable {
    case dictionary, snippets
    var id: Self { self }
    var title: String { self == .dictionary ? "Lug‘at" : "Iboralar" }
}

private struct VocabularySheet: Identifiable {
    let kind: VocabularyTab
    let entry: VocabularyEntry?
    let id = UUID()
}

/// One row: the word, "misspelling → spelling", or "phrase → text"; actions on hover.
private struct VocabularyRow: View {
    let entry: VocabularyEntry
    let edit: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(entry.word).foregroundStyle(.primary)
                if entry.isSnippet {
                    AppIcon(systemName: "arrow.right", size: 10).foregroundStyle(.secondary)
                    Text(entry.replacement).foregroundStyle(entry.isCorrection ? .primary : .secondary)
                }
            }
            .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !entry.isSnippet && entry.language != .all {
                Text(AppLocalization.text(entry.language.title))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                Button(action: edit) { WorkspaceAssetIcon(name: .edit, size: 14).frame(width: 18, height: 18) }
                    .help(AppLocalization.text("Tahrirlash")).accessibilityLabel(AppLocalization.text("Tahrirlash"))
                Button(role: .destructive, action: remove) {
                    WorkspaceAssetIcon(name: .delete, size: 14).frame(width: 18, height: 18)
                }
                .help(AppLocalization.text("O‘chirish")).accessibilityLabel(AppLocalization.text("O‘chirish"))
            }
            .buttonStyle(.echoPlain).foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 16).frame(minHeight: 46)
        .background(hovering ? Color.primary.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: edit)
    }
}

private struct VocabularyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
