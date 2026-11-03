import Foundation
import Observation

struct KeyboardActions {
    let insertText: (String) -> Void
    let insertDictation: (String) -> Void
    let deleteBackward: () -> Void
    let nextKeyboard: () -> Void
    /// Whether the text field wants a capital letter at the cursor (sentence start, etc.).
    let shouldCapitalize: () -> Bool
    /// Returns false when the app could not be opened from the keyboard.
    let openApp: () -> Bool
    let openSettings: () -> Bool
    let openSubscription: () -> Bool
    var activateKeyboardSession: () -> Bool = { false }
    var adjustCursorByCharacterOffset: (Int) -> Void = { _ in }
    /// UIKit sender/event stay opaque here so the model remains platform independent.
    /// The controller forwards every touch phase to the public system keyboard picker.
    var handleInputModeList: ((AnyObject, AnyObject) -> Void)? = nil
    var insertEmoji: ((String) -> Void)? = nil
}

/// Keyboard side of `VoiceBridge`: mirrors the app's snapshot, sends commands and inserts
/// each transcript exactly once. Also holds the typing state (page and shift).
@MainActor
@Observable
final class KeyboardModel {
    enum Notice: Equatable {
        case none
        case openingApp
        case openAppManually
    }

    enum Page {
        case letters, numbers, symbols, emoji
    }

    enum Shift {
        case off, once, locked
    }

    enum Layout: String, CaseIterable {
        case uzbek, english, russian

        var label: String {
            switch self {
            case .uzbek: "UZ"
            case .english: "EN"
            case .russian: "РУ"
            }
        }
    }

    private(set) var snapshot = VoiceBridge.Snapshot()
    private(set) var hasFullAccess = true
    private(set) var needsGlobe = true
    private(set) var notice: Notice = .none
    private(set) var page: Page = .letters
    private(set) var selectedEmojiCategory: EmojiCategory = .smileys
    private(set) var emojiRecents: [String] = []
    static let emojiRecentLimit = 24
    @ObservationIgnored private let emojiDefaults: UserDefaults
    private static let emojiRecentsKey = "echo.keyboard.emojiRecents"

    init(emojiDefaults: UserDefaults = .standard) {
        self.emojiDefaults = emojiDefaults
        var seen = Set<String>()
        emojiRecents = Array((emojiDefaults.stringArray(forKey: Self.emojiRecentsKey) ?? [])
            .filter { EmojiCatalog.contains($0) && seen.insert($0).inserted }
            .prefix(Self.emojiRecentLimit))
        selectedEmojiCategory = emojiRecents.isEmpty ? .smileys : .recent
    }

    var visibleEmoji: [String] {
        selectedEmojiCategory == .recent ? emojiRecents : EmojiCatalog.items(in: selectedEmojiCategory)
    }

    private(set) var shift: Shift = .off
    private(set) var layout: Layout = .uzbek
    private(set) var usesModernUzbekAlphabet = true
    var showsPreferences = false
    private(set) var suggestionsEnabled = true
    private(set) var autocorrectEnabled = true
    private(set) var microphoneMode: VoiceBridge.MicrophoneMode = .readySession
    var returnKeyLabel = "Return"
    var returnKeySymbol: String? = "return"
    /// The transcript is taking longer than it usually does.
    private(set) var isSlow = false
    var suggestions: [String] = []
    var typedWord = ""
    var showsSuggestions = false
    @ObservationIgnored var chooseSuggestion: ((String) -> Void)?
    @ObservationIgnored var preferencesChanged: (() -> Void)?
    @ObservationIgnored var actions: KeyboardActions?

    @ObservationIgnored private var store: VoiceBridge.Store?
    @ObservationIgnored private var observer: VoiceBridge.Observer?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var noticeTimeout: Task<Void, Never>?
    @ObservationIgnored private var slowTimer: Task<Void, Never>?
    @ObservationIgnored private var manualShift = false
    @ObservationIgnored private var lastShiftTap = Date.distantPast
    @ObservationIgnored private var openingAppForDictation = false
    @ObservationIgnored private var stoppingUtterance = false

    private static let openingTimeout = Duration.seconds(20)
    private static let slowAfter = Duration.seconds(5)
    private static let capsLockInterval: TimeInterval = 0.35
    private static let layoutKey = "echo.keyboard.layout"
    private static let alphabetKey = "echo.uzbek.alphabet"
    private static let transcriptScriptKey = "echo.dictation.uzbekScript"

    var letterRows: [[String]] {
        let lines: [String]
        switch layout {
        case .uzbek:
            // Keep familiar QWERTY positions, including W, and expose the modern
            // Uzbek letters directly without replacing a standard top-row key.
            lines = usesModernUzbekAlphabet
                ? ["qwertyuiopş", "asdfghjklö", "zxçvbnmğ"]
                : ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .english:
            lines = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .russian:
            lines = ["йцукенгшщзх", "фывапролджэ", "ячсмитьбю"]
        }
        return lines.map { $0.map(String.init) }
    }

    var isSessionAlive: Bool { snapshot.isAlive() }
    var isRecording: Bool { isSessionAlive && snapshot.phase == .recording }
    var isTranscribing: Bool { isSessionAlive && snapshot.phase == .transcribing }
    var isBusy: Bool { isSessionAlive && (snapshot.phase == .starting || snapshot.phase == .transcribing) }

    /// While recording or waiting on the transcript, the voice panel replaces the keys.
    var showsVoicePanel: Bool {
        isSessionAlive && (snapshot.phase == .starting || snapshot.phase == .recording || snapshot.phase == .transcribing)
    }

    func appeared(hasFullAccess: Bool, needsGlobe: Bool) {
        showsPreferences = false
        stoppingUtterance = false
        self.hasFullAccess = hasFullAccess
        self.needsGlobe = needsGlobe
        // Without Full Access iOS hides the shared App Group container from keyboards.
        store = hasFullAccess ? VoiceBridge.Store() : nil
        if let preferences = UserDefaults(suiteName: VoiceBridge.appGroup) {
            layout = Layout(rawValue: preferences.string(forKey: Self.layoutKey) ?? "") ?? .uzbek
            refreshAlphabet(from: preferences)
            suggestionsEnabled = (preferences.object(forKey: "echo.keyboard.suggestions") as? Bool) ?? true
            autocorrectEnabled = (preferences.object(forKey: "echo.keyboard.autocorrect") as? Bool) ?? true
        }
        observer = VoiceBridge.Observer(name: VoiceBridge.stateNotification) { [weak self] in
            self?.reload()
        }
        // Darwin notifications stop when the app is suspended; polling notices a dead session.
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.store?.setKeyboardVisible(true)
                self?.reload()
                try? await Task.sleep(for: VoiceBridge.heartbeatInterval)
            }
        }
        store?.setKeyboardVisible(true)
        reload()
        refreshShift()
    }

    func disappeared() {
        // iOS hides and recreates the extension during the app handoff. That is
        // not a recording cancellation: the host owns the mic and its timeout.
        stoppingUtterance = false
        polling?.cancel()
        polling = nil
        observer = nil
        store?.setKeyboardVisible(false)
    }

    // MARK: Voice

    func micTapped() {
        showsPreferences = false
        guard let store else { return }
        // Host state can change between the last poll and this tap. In particular,
        // returning to another text field must not reopen an already ready host.
        reload()
        if isSessionAlive {
            switch snapshot.phase {
            case .recording:
                stoppingUtterance = true
                store.send(.stop)
            case .ready:
                stoppingUtterance = false
                store.send(.start)
            case .off, .starting, .transcribing: break
            }
            return
        }
        guard !openingAppForDictation else { return }
        let opened = actions?.openApp() ?? false
        openingAppForDictation = opened
        show(opened ? .openingApp : .openAppManually)
    }

    func openSettings() {
        _ = actions?.openSettings()
    }

    /// Session activation is separate from starting an utterance. Echo explains the
    /// microphone lifetime and asks the user to activate before keeping it ready.
    func activateSessionTapped() {
        guard hasFullAccess else { return }
        showsPreferences = false
        reload()
        guard !isSessionAlive else { return }
        guard !openingAppForDictation else { return }
        let opened = actions?.activateKeyboardSession() ?? false
        openingAppForDictation = opened
        show(opened ? .openingApp : .openAppManually)
    }

    func endSessionTapped() {
        guard hasFullAccess else { return }
        store?.send(.endSession)
        showsPreferences = false
    }

    func setMicrophoneMode(_ mode: VoiceBridge.MicrophoneMode) {
        microphoneMode = mode
        store?.microphoneMode = mode
        // Changing the policy does not discard a recording. An idle session can
        // release its microphone immediately; otherwise the choice applies next session.
        reload()
        if mode == .recordingOnly && snapshot.phase == .ready && isSessionAlive {
            store?.send(.endSession)
        }
    }

    func openSubscription() {
        _ = actions?.openSubscription()
    }

    func cancelTapped() {
        store?.send(.cancel)
    }

    // MARK: Typing

    func type(_ text: String) {
        let isLetter = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        let rendered: String
        if page == .letters, shift == .locked { rendered = text.uppercased() }
        else if page == .letters, shift == .once { rendered = text.prefix(1).uppercased() + text.dropFirst() }
        else { rendered = text }
        actions?.insertText(rendered)
        if isLetter { manualShift = false }
        if text == " " || text == "\n" {
            page = .letters
            manualShift = false
        }
        refreshShift()
    }

    func deleteBackward() {
        actions?.deleteBackward()
        refreshShift()
    }

    /// Unlike advanceToNextInputMode alone, this preserves UIKit's long-press
    /// and swipe-up picker, including the user's enabled Emoji keyboard.
    @discardableResult
    func showSystemKeyboardList(from view: AnyObject, with event: AnyObject) -> Bool {
        guard let handler = actions?.handleInputModeList else { return false }
        handler(view, event)
        return true
    }

    func showEmojiKeyboard() {
        page = .emoji
        selectedEmojiCategory = emojiRecents.isEmpty ? .smileys : .recent
    }

    func selectEmojiCategory(_ category: EmojiCategory) {
        selectedEmojiCategory = category
    }

    /// Insert a complete Unicode cluster atomically, without case conversion,
    /// autocorrect, clipboard access, app launches or dictation commands.
    func insertEmoji(_ emoji: String) {
        guard EmojiCatalog.contains(emoji), let actions else { return }
        if let insert = actions.insertEmoji { insert(emoji) }
        else { actions.insertText(emoji) }
        emojiRecents.removeAll { $0 == emoji }
        emojiRecents.insert(emoji, at: 0)
        if emojiRecents.count > Self.emojiRecentLimit { emojiRecents.removeLast(emojiRecents.count - Self.emojiRecentLimit) }
        emojiDefaults.set(emojiRecents, forKey: Self.emojiRecentsKey)
        refreshShift()
    }

    func adjustCursor(byCharacterOffset offset: Int) {
        guard offset != 0 else { return }
        actions?.adjustCursorByCharacterOffset(offset)
        refreshShift()
    }

    func showPage(_ page: Page) {
        self.page = page
        manualShift = false
        refreshShift()
    }

    func cycleLayout() {
        let all = Layout.allCases
        guard let index = all.firstIndex(of: layout) else { return }
        selectLayout(all[(index + 1) % all.count])
    }

    func selectLayout(_ selected: Layout) {
        layout = selected
        page = .letters
        manualShift = false
        UserDefaults(suiteName: VoiceBridge.appGroup)?.set(layout.rawValue, forKey: Self.layoutKey)
        preferencesChanged?()
        refreshShift()
    }

    func setSuggestionsEnabled(_ enabled: Bool) {
        suggestionsEnabled = enabled
        UserDefaults(suiteName: VoiceBridge.appGroup)?.set(enabled, forKey: "echo.keyboard.suggestions")
        preferencesChanged?()
    }

    func setAutocorrectEnabled(_ enabled: Bool) {
        autocorrectEnabled = enabled
        UserDefaults(suiteName: VoiceBridge.appGroup)?.set(enabled, forKey: "echo.keyboard.autocorrect")
        preferencesChanged?()
    }

    func toggleUzbekAlphabet() {
        usesModernUzbekAlphabet.toggle()
        if let preferences = UserDefaults(suiteName: VoiceBridge.appGroup) {
            let value = usesModernUzbekAlphabet ? "modern" : "current"
            preferences.set(value, forKey: Self.alphabetKey)
            // A Cyrillic output preference is independent of the Latin key layout.
            if preferences.string(forKey: Self.transcriptScriptKey) != "cyrillic" {
                preferences.set(value, forKey: Self.transcriptScriptKey)
            }
        }
        preferencesChanged?()
    }

    private func refreshAlphabet(from preferences: UserDefaults) {
        let previous = usesModernUzbekAlphabet
        switch preferences.string(forKey: Self.transcriptScriptKey) {
        case "modern": usesModernUzbekAlphabet = true
        case "current": usesModernUzbekAlphabet = false
        default: usesModernUzbekAlphabet = preferences.string(forKey: Self.alphabetKey) != "current"
        }
        if previous != usesModernUzbekAlphabet { preferencesChanged?() }
    }

    /// One tap capitalizes the next letter; a quick second tap locks caps.
    func shiftTapped() {
        let now = Date.now
        if shift == .once, now.timeIntervalSince(lastShiftTap) < Self.capsLockInterval {
            shift = .locked
        } else {
            shift = shift == .off ? .once : .off
        }
        manualShift = true
        lastShiftTap = now
    }

    /// Re-checks auto-capitalization after the text or cursor changed.
    func refreshShift() {
        guard shift != .locked, !manualShift else { return }
        shift = page == .letters && actions?.shouldCapitalize() == true ? .once : .off
    }

    // MARK: Bridge

    private func reload() {
        guard let store else { return }
        let latest = store.snapshot()
        if let preferences = UserDefaults(suiteName: VoiceBridge.appGroup) {
            refreshAlphabet(from: preferences)
        }
        microphoneMode = store.microphoneMode
        let wasTranscribing = isTranscribing
        if latest != snapshot { snapshot = latest }
        if isTranscribing != wasTranscribing { trackSlowness() }
        if latest.isAlive() {
            openingAppForDictation = false
            if notice != .none { show(.none) }
        }
        deliverTranscript(from: latest, store: store)
    }

    private func trackSlowness() {
        slowTimer?.cancel()
        isSlow = false
        guard isTranscribing else { return }
        slowTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.slowAfter)
            guard !Task.isCancelled, let self, self.isTranscribing else { return }
            self.isSlow = true
        }
    }

    private func deliverTranscript(from snapshot: VoiceBridge.Snapshot, store: VoiceBridge.Store) {
        guard let transcript = snapshot.transcript, transcript.id > store.acknowledgedTranscriptID else { return }
        store.acknowledgedTranscriptID = transcript.id
        guard Date.now.timeIntervalSince(transcript.createdAt) < VoiceBridge.transcriptLifetime else { return }
        actions?.insertDictation(transcript.text)
        refreshShift()
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        noticeTimeout?.cancel()
        guard notice == .openingApp else { return }
        noticeTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.openingTimeout)
            guard !Task.isCancelled, let self, !self.isSessionAlive else { return }
            self.openingAppForDictation = false
            self.notice = .openAppManually
        }
    }
}

/// A small offline Unicode catalog. Recents store catalog entries only, never
/// surrounding text, transcripts, photos, personal stickers or clipboard data.
enum EmojiCategory: String, CaseIterable, Sendable {
    case recent, smileys, gestures, people, animals, food, activities, travel, objects, symbols, flags
    var symbol: String {
        switch self {
        case .recent: "🕘"
        case .smileys: "🙂"
        case .gestures: "👋"
        case .people: "👤"
        case .animals: "🐾"
        case .food: "🍔"
        case .activities: "⚽"
        case .travel: "🚗"
        case .objects: "💡"
        case .symbols: "❤️"
        case .flags: "🏳️"
        }
    }
    var title: String {
        switch self {
        case .recent: "So‘nggi"
        case .smileys: "Kayfiyat"
        case .gestures: "Ishoralar"
        case .people: "Odamlar"
        case .animals: "Tabiat"
        case .food: "Taomlar"
        case .activities: "Mashg‘ulotlar"
        case .travel: "Sayohat"
        case .objects: "Buyumlar"
        case .symbols: "Belgilar"
        case .flags: "Bayroqlar"
        }
    }
}

enum EmojiCatalog {
    private static let entries: [EmojiCategory: [String]] = [
        .smileys: ["😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "🙂", "🙃", "😉", "😍", "🥰", "😘", "😎", "🤩", "🥳", "🤗", "🤔", "🫡", "😐", "🙄", "😴", "😔", "🥺", "😭", "😤", "😡", "🤯", "😱", "🤦", "🤷", "🫠", "😇", "🤓"],
        .gestures: ["👍", "👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿", "👎", "👏", "🙌", "🙏", "🙏🏽", "🤝", "💪", "💪🏽", "👌", "✌️", "🤞", "🤟", "🫶", "👋", "👋🏽", "🤙", "✋", "👊", "🤲", "☝️", "👉", "👈", "👇", "✍️"],
        .people: ["👶", "🧒", "👦", "👧", "👨", "👩", "🧑", "👴", "👵", "👩‍💻", "👨‍💻", "👩🏽‍💻", "👨🏻‍💻", "🧑🏿‍💻", "👨‍⚕️", "👩‍🏫", "👨‍🍳", "👩‍🎓", "👮", "🧕", "👳", "👑", "💃", "🕺", "👨‍👩‍👧‍👦", "👩‍👩‍👦", "👨‍👨‍👧", "🧑‍🦽", "🏃", "🚶"],
        .animals: ["🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐸", "🐵", "🐔", "🐧", "🐦", "🦋", "🐝", "🐢", "🐬", "🌸", "🌹", "🌻", "🌳", "🌿", "🍀", "☀️", "🌈", "🌙"],
        .food: ["🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🍒", "🍑", "🥭", "🍍", "🥑", "🥕", "🌽", "🍞", "🥐", "🥯", "🧀", "🥚", "🍗", "🥩", "🍔", "🍟", "🍕", "🌮", "🥟", "🍚", "🍰", "🎂", "🍫", "🍦", "☕", "🫖", "🥤", "💧"],
        .activities: ["⚽", "🏀", "🏈", "⚾", "🎾", "🏐", "🏓", "🏸", "🥊", "🏊", "🚴", "🏋️", "🎯", "🏆", "🥇", "🎮", "🎲", "🎨", "🎭", "🎤", "🎧", "🎸", "🎹", "🎬", "🎉", "🎊", "🎁", "🎈", "🎆", "✨"],
        .travel: ["🚗", "🚕", "🚌", "🚎", "🚓", "🚑", "🚒", "🚚", "🚲", "🛵", "🏍️", "🚆", "🚄", "✈️", "🚀", "🚁", "🚢", "⛵", "🏠", "🏢", "🏫", "🏥", "🕌", "🗽", "🗼", "🏔️", "🏖️", "🏕️", "🌍", "🗺️"],
        .objects: ["⌚", "📱", "💻", "⌨️", "🖥️", "📷", "📹", "💡", "🔦", "🔋", "🔌", "💰", "💳", "💎", "🔑", "🔒", "🛠️", "⚙️", "🧲", "📚", "📖", "📝", "✏️", "📌", "📎", "✂️", "📦", "📧", "📞", "⏰"],
        .symbols: ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "💕", "💯", "🔥", "⭐", "🌟", "💫", "✅", "❌", "❗", "❓", "⚠️", "♻️", "➕", "➖", "✖️", "➗", "➡️", "⬅️", "⬆️", "⬇️", "🔴", "🟢", "🔵", "🟣", "☑️", "🔔"],
        .flags: ["🇺🇿", "🇰🇿", "🇰🇬", "🇹🇯", "🇹🇲", "🇦🇿", "🇹🇷", "🇬🇪", "🇺🇦", "🇷🇺", "🇺🇸", "🇬🇧", "🇨🇦", "🇩🇪", "🇫🇷", "🇮🇹", "🇪🇸", "🇯🇵", "🇰🇷", "🇨🇳", "🇮🇳", "🇦🇪", "🇸🇦", "🇦🇺", "🇧🇷", "🏳️", "🏴", "🏁", "🚩", "🏳️‍🌈"]
    ]
    private static let supported = Set(entries.values.flatMap { $0 })
    static func items(in category: EmojiCategory) -> [String] { entries[category] ?? [] }
    static func contains(_ emoji: String) -> Bool { supported.contains(emoji) }
}
