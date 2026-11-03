import Foundation

@main
struct KeyboardSessionCommandRegression {
    @MainActor
    static func main() {
        let preferences = UserDefaults(suiteName: VoiceBridge.appGroup)!
        preferences.removePersistentDomain(forName: VoiceBridge.appGroup)
        defer { preferences.removePersistentDomain(forName: VoiceBridge.appGroup) }
        let store = VoiceBridge.Store()!
        checkInternalEmoji(store)
        checkSystemKeyboardHandoff(store)
        checkPolicyAndPresence(store)
        checkAlphabetAndCursorActions(store, preferences: preferences)
        checkFreshState(store)
        checkForegroundHandoff(store)
        checkLiveSessionAppearance(store)
        checkActivationAndFullAccess(store)
        print("Keyboard session policy, presence, fresh-state, and command regressions passed")
    }

    @MainActor
    private static func checkInternalEmoji(_ store: VoiceBridge.Store) {
        let name = "test.echo.emoji." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let recorder = ActionsRecorder()
        let model = recorder.makeModel(emojiDefaults: defaults)
        store.write(VoiceBridge.Snapshot(phase: .ready, sessionID: "emoji-ready", heartbeat: .now))
        model.appeared(hasFullAccess: false, needsGlobe: false)
        let previousCommand = store.command()?.id
        model.selectLayout(.english)
        model.showEmojiKeyboard()
        precondition(model.page == .emoji && model.selectedEmojiCategory == .smileys && !model.visibleEmoji.isEmpty)
        model.selectEmojiCategory(.people)
        precondition(model.visibleEmoji.contains("👩🏽‍💻"))
        precondition(EmojiCategory.allCases.flatMap { EmojiCatalog.items(in: $0) }.allSatisfy { $0.count == 1 },
                     "Every catalog entry must be one complete Unicode grapheme")
        let clusters = ["👩🏽‍💻", "👍🏽", "👨‍👩‍👧‍👦", "🇺🇿"]
        precondition(clusters.allSatisfy { $0.count == 1 }, "Fixture must exercise complete Unicode graphemes")
        for emoji in clusters { model.insertEmoji(emoji) }
        precondition(recorder.emojiInserted == clusters && recorder.typed.isEmpty,
                     "Emoji must reach the dedicated uncorrected proxy action as complete Unicode strings")
        precondition(model.page == .emoji && model.emojiRecents == clusters.reversed())
        model.insertEmoji("not emoji or transcript text")
        precondition(recorder.emojiInserted == clusters, "Recents must never store surrounding/private text")
        model.selectEmojiCategory(.recent)
        precondition(model.visibleEmoji == model.emojiRecents)
        model.showPage(.letters)
        precondition(model.layout == .english && model.page == .letters,
                     "ABC must restore typing without changing the selected language")
        model.showEmojiKeyboard()
        precondition(model.selectedEmojiCategory == .recent)
        for emoji in EmojiCatalog.items(in: .smileys).prefix(30) { model.insertEmoji(emoji) }
        precondition(model.emojiRecents.count == KeyboardModel.emojiRecentLimit && Set(model.emojiRecents).count == model.emojiRecents.count)
        let recent = model.emojiRecents.last!
        model.insertEmoji(recent)
        precondition(model.emojiRecents.first == recent && model.emojiRecents.count == KeyboardModel.emojiRecentLimit)
        let restored = KeyboardModel(emojiDefaults: defaults)
        precondition(restored.emojiRecents == model.emojiRecents && restored.selectedEmojiCategory == .recent,
                     "Only bounded emoji recents persist locally across keyboard instances")
        defaults.set(["private surrounding text", "🙂", "🙂", "👩🏽‍💻"], forKey: "echo.keyboard.emojiRecents")
        precondition(KeyboardModel(emojiDefaults: defaults).emojiRecents == ["🙂", "👩🏽‍💻"],
                     "Persisted history must be filtered and deduplicated before rendering")
        let dedicatedCount = recorder.emojiInserted.count
        model.actions?.insertEmoji = nil
        model.insertEmoji("🙂")
        precondition(recorder.typed == ["🙂"] && recorder.emojiInserted.count == dedicatedCount,
                     "The fallback must make exactly one atomic insert, never duplicate the cluster")
        precondition(store.command()?.id == previousCommand && store.snapshot().sessionID == "emoji-ready" && recorder.appOpens == 0,
                     "Offline emoji picking must preserve the host snapshot without needing Full Access")
        model.disappeared()
        model.appeared(hasFullAccess: true, needsGlobe: true)
        precondition(model.snapshot.sessionID == "emoji-ready" && model.snapshot.phase == .ready)
        model.selectLayout(.uzbek)
        model.disappeared()
    }

    @MainActor
    private static func checkSystemKeyboardHandoff(_ store: VoiceBridge.Store) {
        let recorder = ActionsRecorder()
        let model = recorder.makeModel()
        let sender = NSObject()
        let touchDown = NSObject(), drag = NSObject(), release = NSObject(), cancel = NSObject()
        var forwarded: [ObjectIdentifier] = []
        model.actions?.handleInputModeList = { view, event in
            precondition(view === sender, "The real UIKit sender must reach the system picker")
            forwarded.append(ObjectIdentifier(event))
        }
        store.write(VoiceBridge.Snapshot(phase: .ready, heartbeat: .now))
        let previousCommand = store.command()?.id
        // Switching keyboards is available without network or Full Access, even
        // when iOS supplies its separate globe beneath our visible smiley key.
        model.appeared(hasFullAccess: false, needsGlobe: false)
        for event in [touchDown, drag, release, cancel] {
            precondition(model.showSystemKeyboardList(from: sender, with: event))
        }
        precondition(forwarded == [touchDown, drag, release, cancel].map(ObjectIdentifier.init),
                     "Tap, hold/swipe and cancellation phases must reach UIKit unchanged")
        precondition(recorder.typed.isEmpty && recorder.appOpens == 0 && store.command()?.id == previousCommand,
                     "Opening system keyboards must not type, launch Echo or send dictation commands")
        model.disappeared()
        store.write(VoiceBridge.Snapshot(phase: .ready, heartbeat: .now))
        model.appeared(hasFullAccess: true, needsGlobe: true)
        precondition(model.showSystemKeyboardList(from: sender, with: touchDown))
        precondition(recorder.appOpens == 0 && store.command()?.id == previousCommand,
                     "Returning from Emoji to Echo must preserve the live ready session")
        model.actions?.handleInputModeList = nil
        precondition(!model.showSystemKeyboardList(from: sender, with: release),
                     "A missing controller reports failure so the view can use its tap fallback")
        model.disappeared()
    }

    @MainActor
    private static func checkAlphabetAndCursorActions(_ store: VoiceBridge.Store,
                                                      preferences: UserDefaults) {
        let recorder = ActionsRecorder()
        let model = recorder.makeModel()
        store.write(VoiceBridge.Snapshot())
        model.appeared(hasFullAccess: true, needsGlobe: true)
        precondition(model.letterRows.map { $0.joined() } == ["qwertyuiopş", "asdfghjklö", "zxçvbnmğ"],
                     "The modern keyboard must display all four Uzbek letters directly")
        precondition(model.letterRows[0][1] == "w" && model.letterRows[0].last == "ş",
                     "W must retain its QWERTY position while Ş remains directly available")
        model.type("w")
        model.shiftTapped()
        model.type("w")
        model.type("ş")
        model.shiftTapped()
        model.type("ö")
        precondition(recorder.typed == ["w", "W", "ş", "Ö"])
        precondition(recorder.cursorOffsets.isEmpty, "Normal typing must never enter trackpad movement")
        model.adjustCursor(byCharacterOffset: 3)
        model.adjustCursor(byCharacterOffset: -2)
        model.adjustCursor(byCharacterOffset: 0)
        precondition(recorder.cursorOffsets == [3, -2] && recorder.typed == ["w", "W", "ş", "Ö"],
                     "Trackpad actions must move the cursor without adding text")
        model.selectLayout(.english)
        precondition(model.letterRows.map { $0.joined() } == ["qwertyuiop", "asdfghjkl", "zxcvbnm"],
                     "English must retain W/C and the standard QWERTY layout")
        model.selectLayout(.uzbek)
        model.toggleUzbekAlphabet()
        precondition(model.letterRows.map { $0.joined() } == ["qwertyuiop", "asdfghjkl", "zxcvbnm"])
        precondition(preferences.string(forKey: "echo.dictation.uzbekScript") == "current")
        model.toggleUzbekAlphabet()
        precondition(preferences.string(forKey: "echo.dictation.uzbekScript") == "modern")
        preferences.set("cyrillic", forKey: "echo.dictation.uzbekScript")
        model.toggleUzbekAlphabet()
        precondition(preferences.string(forKey: "echo.dictation.uzbekScript") == "cyrillic",
                     "A Latin layout change must not erase a chosen Cyrillic transcript script")
        model.toggleUzbekAlphabet()
        preferences.set("current", forKey: "echo.dictation.uzbekScript")
        store.write(VoiceBridge.Snapshot(phase: .ready, heartbeat: .now))
        model.micTapped()
        precondition(!model.usesModernUzbekAlphabet && recorder.appOpens == 0,
                     "A shared script change must refresh a visible keyboard before its next action")
        // A previously enabled preference is deliberately inert in current builds.
        preferences.set(true, forKey: "echo.keyboard.haptics")
        model.disappeared()
        model.appeared(hasFullAccess: true, needsGlobe: true)
        preferences.set("modern", forKey: "echo.dictation.uzbekScript")
        preferences.set("modern", forKey: "echo.uzbek.alphabet")
        model.disappeared()
    }

    private static func checkPolicyAndPresence(_ store: VoiceBridge.Store) {
        precondition(store.microphoneMode == .readySession,
                     "The approved five-minute ready policy must be the initial default")
        store.microphoneMode = .recordingOnly
        precondition(VoiceBridge.Store()!.microphoneMode == .recordingOnly,
                     "An explicit recording-only choice must survive Store recreation")
        store.microphoneMode = .readySession
        precondition(VoiceBridge.Store()!.microphoneMode == .readySession)

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        precondition(!store.keyboardIsVisible(at: now))
        store.setKeyboardVisible(true, at: now)
        precondition(store.keyboardIsVisible(at: now))
        precondition(store.keyboardIsVisible(at: now.addingTimeInterval(5.9)))
        precondition(!store.keyboardIsVisible(at: now.addingTimeInterval(6)),
                     "A dead keyboard must not keep the microphone ready indefinitely")
        store.setKeyboardVisible(true, at: now.addingTimeInterval(4))
        precondition(store.keyboardIsVisible(at: now.addingTimeInterval(8)),
                     "A new visibility heartbeat must renew the lease")
        store.setKeyboardVisible(false, at: now.addingTimeInterval(8))
        precondition(!store.keyboardIsVisible(at: now.addingTimeInterval(8)),
                     "Disappearance must release keyboard presence immediately")
        store.setKeyboardVisible(true, at: now.addingTimeInterval(1))
        precondition(!store.keyboardIsVisible(at: now),
                     "A future heartbeat must not create an unbounded visibility lease")
        store.setKeyboardVisible(false, at: now)

        let idleAt = now.addingTimeInterval(-VoiceBridge.sessionIdleTimeout)
        precondition(!VoiceBridge.shouldEndKeyboardSession(
            lastActivity: now, now: now.addingTimeInterval(299.9),
            appIsActive: false, keyboardIsVisible: false))
        precondition(VoiceBridge.shouldEndKeyboardSession(
            lastActivity: idleAt, now: now,
            appIsActive: false, keyboardIsVisible: false),
                     "A hidden session must end at the five-minute idle boundary")
        precondition(!VoiceBridge.shouldEndKeyboardSession(
            lastActivity: idleAt, now: now,
            appIsActive: true, keyboardIsVisible: false),
                     "A foreground app must not lose its activated session")
        precondition(!VoiceBridge.shouldEndKeyboardSession(
            lastActivity: idleAt, now: now,
            appIsActive: false, keyboardIsVisible: true),
                     "Using the keyboard must not expire an already activated session")
    }

    @MainActor
    private static func checkFreshState(_ store: VoiceBridge.Store) {
        for cached in [VoiceBridge.Snapshot(),
                       VoiceBridge.Snapshot(phase: .ready, heartbeat: .now.addingTimeInterval(-10))] {
            let recorder = ActionsRecorder()
            let model = recorder.makeModel()
            store.write(cached)
            model.appeared(hasFullAccess: true, needsGlobe: true)
            precondition(!model.isSessionAlive)
            // No yield or notification delivery: test the host-write/tap race.
            store.write(VoiceBridge.Snapshot(phase: .ready, heartbeat: .now))
            model.micTapped()
            precondition(store.command()?.action == .start)
            precondition(recorder.appOpens == 0,
                         "Fresh live state must win over a cached off/stale snapshot")
            model.disappeared()
        }

        let recorder = ActionsRecorder()
        let model = recorder.makeModel()
        store.write(VoiceBridge.Snapshot(phase: .ready, heartbeat: .now))
        model.appeared(hasFullAccess: true, needsGlobe: true)
        precondition(model.isSessionAlive)
        let commandID = store.command()?.id
        store.write(VoiceBridge.Snapshot())
        model.micTapped()
        precondition(recorder.appOpens == 1,
                     "Fresh off state must not send Start to a dead session")
        precondition(store.command()?.id == commandID)
        model.disappeared()

        let staleRecorder = ActionsRecorder()
        let staleModel = staleRecorder.makeModel()
        store.write(VoiceBridge.Snapshot(phase: .ready, heartbeat: .now.addingTimeInterval(-10)))
        staleModel.appeared(hasFullAccess: true, needsGlobe: true)
        staleModel.micTapped()
        precondition(staleRecorder.appOpens == 1,
                     "An actually stale session must still offer foreground activation")
        staleModel.disappeared()
    }

    @MainActor
    private static func checkForegroundHandoff(_ store: VoiceBridge.Store) {
        let recorder = ActionsRecorder()
        let model = recorder.makeModel()
        store.write(VoiceBridge.Snapshot())
        model.appeared(hasFullAccess: true, needsGlobe: true)
        model.micTapped()
        model.micTapped()
        precondition(recorder.appOpens == 1,
                     "Repeated taps must not request another launch during handoff")
        model.disappeared()
        model.appeared(hasFullAccess: true, needsGlobe: true)
        model.micTapped()
        precondition(recorder.appOpens == 1,
                     "A view transition must not erase a pending foreground handoff")
        store.write(VoiceBridge.Snapshot(phase: .ready, heartbeat: .now))
        model.micTapped()
        precondition(store.command()?.action == .start && recorder.appOpens == 1,
                     "A live host acknowledgment must permit Start without another launch")
        model.disappeared()

        let failedRecorder = ActionsRecorder()
        failedRecorder.openSucceeds = false
        let failedModel = failedRecorder.makeModel()
        store.write(VoiceBridge.Snapshot())
        failedModel.appeared(hasFullAccess: true, needsGlobe: true)
        failedModel.micTapped()
        failedModel.micTapped()
        precondition(failedRecorder.appOpens == 2,
                     "An unsuccessful URL launch must remain immediately retryable")
        precondition(failedModel.notice == .openAppManually)
        failedModel.disappeared()
    }

    @MainActor
    private static func checkLiveSessionAppearance(_ store: VoiceBridge.Store) {
        let recorder = ActionsRecorder()
        let model = recorder.makeModel()
        store.write(VoiceBridge.Snapshot(phase: .ready, heartbeat: .now))
        model.appeared(hasFullAccess: true, needsGlobe: true)
        precondition(store.keyboardIsVisible(at: .now))
        model.micTapped()
        precondition(store.command()?.action == .start)
        let firstCommandID = store.command()?.id
        model.disappeared()
        precondition(!store.keyboardIsVisible(at: .now))
        precondition(store.command()?.id == firstCommandID,
                     "Hiding the keyboard must not send Cancel or End Session")
        store.write(VoiceBridge.Snapshot(phase: .recording, heartbeat: .now))
        model.appeared(hasFullAccess: true, needsGlobe: true)
        model.micTapped()
        precondition(store.command()?.action == .stop)
        model.disappeared()
        store.write(VoiceBridge.Snapshot(phase: .ready, heartbeat: .now))
        model.appeared(hasFullAccess: true, needsGlobe: true)
        model.micTapped()
        precondition(store.command()?.action == .start && recorder.appOpens == 0,
                     "A second utterance in a live session must stay in the keyboard")
        model.endSessionTapped()
        precondition(store.command()?.action == .endSession && recorder.appOpens == 0)
        model.disappeared()
        for phase in [VoiceBridge.Phase.starting, .transcribing] {
            store.write(VoiceBridge.Snapshot(phase: phase, heartbeat: .now))
            model.appeared(hasFullAccess: true, needsGlobe: true)
            let commandID = store.command()?.id
            model.micTapped()
            precondition(recorder.appOpens == 0 && store.command()?.id == commandID,
                         "An in-flight transition must never trigger a launch")
            model.disappeared()
        }
    }

    @MainActor
    private static func checkActivationAndFullAccess(_ store: VoiceBridge.Store) {
        let recorder = ActionsRecorder()
        let model = recorder.makeModel()
        store.write(VoiceBridge.Snapshot())
        model.appeared(hasFullAccess: true, needsGlobe: true)
        model.showsPreferences = true
        model.activateSessionTapped()
        precondition(recorder.sessionActivations == 1 && recorder.appOpens == 0)
        precondition(!model.showsPreferences)
        model.disappeared()
        let activationURL = URLComponents(string: VoiceBridge.readySessionURLString)!
        precondition(activationURL.host == "dictate")
        precondition(activationURL.queryItems == [URLQueryItem(name: "session", value: "ready")])
        let deniedRecorder = ActionsRecorder()
        let deniedModel = deniedRecorder.makeModel()
        deniedModel.appeared(hasFullAccess: false, needsGlobe: true)
        deniedModel.micTapped()
        deniedModel.activateSessionTapped()
        precondition(deniedRecorder.appOpens == 0 && deniedRecorder.sessionActivations == 0,
                     "Voice actions must require Full Access")
        deniedModel.disappeared()
    }
}

@MainActor
private final class ActionsRecorder {
    var appOpens = 0
    var sessionActivations = 0
    var openSucceeds = true
    var typed: [String] = []
    var cursorOffsets: [Int] = []
    var emojiInserted: [String] = []

    func makeModel(emojiDefaults: UserDefaults = .standard) -> KeyboardModel {
        let model = KeyboardModel(emojiDefaults: emojiDefaults)
        model.actions = KeyboardActions(
            insertText: { self.typed.append($0) }, insertDictation: { _ in }, deleteBackward: {},
            nextKeyboard: {}, shouldCapitalize: { false },
            openApp: { self.appOpens += 1; return self.openSucceeds },
            openSettings: { false }, openSubscription: { false },
            activateKeyboardSession: { self.sessionActivations += 1; return self.openSucceeds },
            adjustCursorByCharacterOffset: { self.cursorOffsets.append($0) },
            insertEmoji: { self.emojiInserted.append($0) }
        )
        return model
    }
}
