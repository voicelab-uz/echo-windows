import SwiftUI
import UIKit

/// UIKit owns each finger independently, so quick overlapping taps never compete
/// with SwiftUI button gestures. Model actions remain the only text insertion path.
struct NativeKeySurface: UIViewRepresentable {
    let model: KeyboardModel
    let revision: String

    func makeUIView(context: Context) -> NativeKeyboardSurface { NativeKeyboardSurface(model: model) }
    func updateUIView(_ view: NativeKeyboardSurface, context: Context) { view.refresh() }
    static func dismantleUIView(_ view: NativeKeyboardSurface, coordinator: ()) { view.cancelAllTouches() }
}

@MainActor
final class NativeKeyboardSurface: UIView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
    private let model: KeyboardModel
    private enum Action { case text(String), shift, delete, emoji, page(KeyboardModel.Page) }
    private struct Key {
        let action: Action
        let title: String
        var symbol: String? = nil
        var function = false
        var popup = false
        var frame: CGRect = .zero
    }
    @MainActor private final class Finger {
        var key: Int?
        var repeatTask: Task<Void, Never>?
        let popup = NativeKeyPopup()
        let chooser = UIView()
        var variants: [String] = []
        var selectedVariant: Int? = nil
        var activatedShift = false
        var trackpad: NativeSpacebarTrackpad?
        var lastPoint: CGPoint = .zero
        init(key: Int?) { self.key = key }
    }
    private var keys: [Key] = []
    private var caps: [AccessibleKeyCap] = []
    private var fingers: [UITouch: Finger] = [:]
    private var lastSize: CGSize = .zero
    private var layoutIdentity = ""
    private var renderIdentity = ""
    private var releasedPopups: [NativeKeyPopup] = []
    private let modeButton = NativeKeyboardModeButton(type: .custom)
    private var handledModeEvent = false
    private let emojiPanel = NativeEmojiPanel()

    init(model: KeyboardModel) {
        self.model = model
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        backgroundColor = .clear
        isAccessibilityElement = false
        modeButton.backgroundColor = .clear
        modeButton.addTarget(self, action: #selector(modeInputEvent(_:event:)), for: .allTouchEvents)
        modeButton.addTarget(self, action: #selector(modeTapFallback(_:event:)), for: .touchUpInside)
        modeButton.highlightChanged = { [weak self] in self?.updateHighlights() }
        modeButton.accessibilityLabel = "Klaviaturalar"
        modeButton.accessibilityHint = "Emoji tanlash uchun ushlab turing yoki yuqoriga suring."
        addSubview(emojiPanel)
        emojiPanel.isHidden = true
        emojiPanel.addSubview(modeButton)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: NativeKeyboardSurface, _: UITraitCollection) in
            view.updateHighlights()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let identity = "\(model.page)-\(model.layout)-\(model.usesModernUzbekAlphabet)-\(model.needsGlobe)"
        if identity != layoutIdentity { cancelAllTouches(); layoutIdentity = identity }
        let render = "\(identity)-\(model.selectedEmojiCategory)-\(model.emojiRecents.joined())-\(model.shift)-\(model.returnKeyLabel)-\(model.returnKeySymbol ?? "-")-\(bounds.width)-\(bounds.height)"
        guard render != renderIdentity else { return }
        renderIdentity = render
        rebuild()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize { lastSize = bounds.size; cancelAllTouches(); refresh() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelAllTouches() }
    }
    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let showingEmoji = model.page == .emoji
        emojiPanel.isHidden = !showingEmoji
        modeButton.isHidden = !showingEmoji
        caps.forEach { $0.isHidden = showingEmoji }
        if showingEmoji {
            keys = []
            emojiPanel.frame = bounds
            emojiPanel.configure(model: model, modeButton: modeButton, feedback: { [weak self] in self?.playKeyFeedback() },
                                 changed: { [weak self] in self?.refresh() })
            bringSubviewToFront(emojiPanel)
            return
        }
        let w = bounds.width, h = bounds.height / 4
        var next: [Key] = []
        func add(_ key: Key, _ x: CGFloat, _ y: Int, _ width: CGFloat) {
            var key = key; key.frame = CGRect(x: x, y: CGFloat(y) * h, width: width, height: h); next.append(key)
        }
        func textRow(_ row: [String], _ y: Int, _ width: CGFloat, _ inset: CGFloat) {
            for (i, value) in row.enumerated() {
                let title = model.page == .letters && model.shift != .off ? value.uppercased() : value
                add(Key(action: .text(value), title: title, popup: true), inset + CGFloat(i) * width, y, width)
            }
        }
        if model.page == .letters {
            let rows = model.letterRows
            let unit = w / CGFloat(rows[0].count)
            textRow(rows[0], 0, unit, 0)
            textRow(rows[1], 1, (w - unit) / CGFloat(rows[1].count), unit / 2)
            let thirdWidth = min(unit, (w - 2.6 * unit) / CGFloat(rows[2].count))
            let inset = (w - thirdWidth * CGFloat(rows[2].count)) / 2
            let shiftSymbol = model.shift == .locked ? "capslock.fill" : (model.shift == .once ? "shift.fill" : "shift")
            add(Key(action: .shift, title: model.shift == .locked ? "Caps lock" : "Shift", symbol: shiftSymbol, function: model.shift == .off), 0, 2, unit * 1.15)
            textRow(rows[2], 2, thirdWidth, inset)
            add(Key(action: .delete, title: "Delete", symbol: "delete.left", function: true), w - unit * 1.17, 2, unit * 1.17)
        } else {
            let rows = model.page == .numbers
                ? [["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]]
                : [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]]
            textRow(rows[0], 0, w / 10, 0); textRow(rows[1], 1, w / 10, 0)
            add(Key(action: .page(model.page == .numbers ? .symbols : .numbers), title: model.page == .numbers ? "#+=" : "123", function: true), 0, 2, w * 0.15)
            textRow([".", ",", "?", "!", "'"], 2, w * 0.14, w * 0.15)
            add(Key(action: .delete, title: "Delete", symbol: "delete.left", function: true), w * 0.85, 2, w * 0.15)
        }
        let bottom = NativeKeyboardMetrics.bottomRow(width: w, y: 3 * h, height: h)
        add(Key(action: .page(model.page == .letters ? .numbers : .letters), title: model.page == .letters ? "123" : "ABC", function: true), bottom.page.minX, 3, bottom.page.width)
        add(Key(action: .emoji, title: "Emoji", symbol: "face.smiling", function: true), bottom.emoji.minX, 3, bottom.emoji.width)
        add(Key(action: .text(" "), title: ""), bottom.space.minX, 3, bottom.space.width)
        add(Key(action: .text("\n"), title: model.returnKeyLabel, symbol: model.returnKeySymbol, function: true), bottom.returnKey.minX, 3, bottom.returnKey.width)
        keys = next
        while caps.count > keys.count { caps.removeLast().removeFromSuperview() }
        while caps.count < keys.count { let cap = AccessibleKeyCap(); caps.append(cap); addSubview(cap) }
        for (i, key) in keys.enumerated() {
            let cap = caps[i]
            // UIKit frame assignment is undefined with an existing transform.
            cap.transform = .identity
            cap.frame = key.frame.insetBy(dx: NativeKeyboardMetrics.horizontalGutter, dy: NativeKeyboardMetrics.verticalGutter)
            cap.text = key.symbol == nil ? key.title : nil
            cap.icon.image = key.symbol.flatMap { UIImage(systemName: $0) }
            cap.font = key.popup ? KeyboardAppearance.characterFont(for: key.title) : KeyboardAppearance.functionFont
            let isSpace: Bool = { if case .text(" ") = key.action { return true }; return false }()
            cap.localeBadge.text = isSpace ? (model.layout == .uzbek ? "O‘z" : model.layout.label) : nil
            cap.accessibilityLabel = isSpace ? "Bo‘sh joy" : key.title
            cap.isAccessibilityElement = true
            cap.isHidden = false
            cap.activation = { [weak self] in self?.activate(i) }
            cap.accessibilityCustomActions = variants(for: key).dropFirst().map { value in
                UIAccessibilityCustomAction(name: value) { [weak self] _ in
                    guard let self else { return false }
                    self.model.type(value); self.refresh(); return true
                }
            }
        }
        updateHighlights()
    }

    @objc private func modeInputEvent(_ sender: UIButton, event: UIEvent?) {
        guard let event else { return }
        if event.allTouches?.contains(where: { $0.view === sender && $0.phase == .began }) == true { playKeyFeedback() }
        handledModeEvent = model.showSystemKeyboardList(from: sender, with: event)
    }
    @objc private func modeTapFallback(_ sender: UIButton, event: UIEvent?) {
        // VoiceOver/programmatic activation can have no event. Never force-unwrap
        // it, and never turn a canceled touch into a keyboard switch.
        if event == nil || !handledModeEvent { model.actions?.nextKeyboard() }
    }

    /// Gaps belong to their nearest key within the row; leaving the keyboard cancels.
    private func keyIndex(at point: CGPoint, retaining previous: Int? = nil) -> Int? {
        NativeKeyHitTesting.index(at: point, bounds: bounds, frames: keys.map(\.frame), retaining: previous)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        clearReleasedPopups()
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let finger = Finger(key: keyIndex(at: touch.location(in: self)))
            finger.lastPoint = touch.location(in: self)
            fingers[touch] = finger
            if let index = finger.key {
                playKeyFeedback()
                switch keys[index].action {
                case .delete: model.deleteBackward(); startRepeating(finger)
                case .shift:
                    finger.activatedShift = true
                    model.shiftTapped()
                    // Subtle haptic for shift activation
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
                    refresh()
                case .text(" "):
                    finger.trackpad = NativeSpacebarTrackpad(origin: finger.lastPoint,
                        beganAt: touch.timestamp, spaceFrame: keys[index].frame)
                    startTrackpad(finger)
                default: startVariants(finger)
                }
            }
        }
        updateHighlights()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let finger = fingers[touch] else { continue }
            let location = touch.location(in: self)
            finger.lastPoint = location
            if finger.trackpad != nil {
                advanceTrackpad(finger, to: location, at: touch.timestamp)
                continue
            }
            if !finger.variants.isEmpty {
                let area = CGRect(x: finger.chooser.frame.minX, y: finger.chooser.frame.minY,
                                  width: finger.chooser.frame.width,
                                  height: max(50, (finger.key.map { keys[$0].frame.maxY } ?? bounds.maxY) - finger.chooser.frame.minY))
                finger.selectedVariant = area.contains(location)
                    ? min(finger.variants.count - 1, max(0, Int((location.x - area.minX) / 46))) : nil
                continue
            }
            let next = keyIndex(at: location, retaining: finger.key)
            if next != finger.key {
                finger.repeatTask?.cancel(); finger.repeatTask = nil
                finger.key = next
                if let next {
                    if case .delete = keys[next].action { model.deleteBackward(); startRepeating(finger) }
                    else { startVariants(finger) }
                }
            }
        }
        updateHighlights()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let finger = fingers.removeValue(forKey: touch) else { continue }
            finger.repeatTask?.cancel(); finger.chooser.removeFromSuperview()
            if var trackpad = finger.trackpad {
                let result = trackpad.finish(at: touch.location(in: self), timestamp: touch.timestamp, bounds: bounds)
                finger.popup.removeFromSuperview()
                if result.cursorOffset != 0 {
                    model.adjustCursor(byCharacterOffset: result.cursorOffset)
                    // Subtle haptic feedback for cursor movement
                    if abs(result.cursorOffset) > 0 {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
                if result.insertSpace { model.type(" "); refresh() }
                continue
            }
            if !finger.variants.isEmpty {
                finger.popup.removeFromSuperview()
                let location = touch.location(in: self)
                let bottom = finger.key.map { keys[$0].frame.maxY } ?? bounds.maxY
                let selectionArea = CGRect(x: finger.chooser.frame.minX, y: finger.chooser.frame.minY,
                                           width: finger.chooser.frame.width, height: bottom - finger.chooser.frame.minY)
                if selectionArea.contains(location), let selected = finger.selectedVariant {
                    model.type(finger.variants[selected])
                    // Haptic feedback for variant selection
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    refresh()
                }
                continue
            }
            if let index = keyIndex(at: touch.location(in: self), retaining: finger.key) {
                releasePopup(finger.popup)
                switch keys[index].action {
                case .delete:
                    if index != finger.key { activate(index) }
                case .shift:
                    if !finger.activatedShift { activate(index, click: false) }
                default: activate(index, click: false)
                }
            } else { finger.popup.removeFromSuperview() }
        }
        updateHighlights()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let finger = fingers.removeValue(forKey: touch) { finger.repeatTask?.cancel(); finger.popup.removeFromSuperview(); finger.chooser.removeFromSuperview() }
        }
        updateHighlights()
    }
    func cancelAllTouches() {
        clearReleasedPopups()
        for finger in fingers.values { finger.repeatTask?.cancel(); finger.popup.removeFromSuperview(); finger.chooser.removeFromSuperview() }
        fingers.removeAll(); modeButton.cancelTracking(with: nil); updateHighlights()
    }
    /// Only feedback lingers; text is committed synchronously on lift.
    /// The next touch dismisses this echo immediately, keeping fast typing clear.
    private func releasePopup(_ popup: NativeKeyPopup) {
        guard popup.superview != nil else { return }
        releasedPopups.append(popup)
        Task { @MainActor [weak self, weak popup] in
            try? await Task.sleep(for: .milliseconds(55))
            guard let self, let popup, self.releasedPopups.contains(where: { $0 === popup }) else { return }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.07,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                popup.alpha = 0
            } completion: { [weak self, weak popup] _ in
                guard let popup else { return }
                popup.removeFromSuperview()
                self?.releasedPopups.removeAll { $0 === popup }
            }
        }
    }
    private func clearReleasedPopups() {
        for popup in releasedPopups { popup.layer.removeAllAnimations(); popup.removeFromSuperview() }
        releasedPopups.removeAll()
    }

    private func variants(for key: Key) -> [String] {
        guard model.layout == .uzbek, model.page == .letters, case .text(let letter) = key.action else { return [] }
        // Direct modern keys retain familiar/foreign spellings on long press.
        switch letter {
        case "ş": return ["ş", "sh", "w"]
        case "ç": return ["ç", "ch", "c"]
        case "ö": return ["ö", "o‘"]
        case "ğ": return ["ğ", "g‘"]
        default: break
        }
        let alternate: String?
        switch letter {
        case "o": alternate = model.usesModernUzbekAlphabet ? "ö" : "oʻ"
        case "g": alternate = model.usesModernUzbekAlphabet ? "ğ" : "gʻ"
        case "s": alternate = model.usesModernUzbekAlphabet ? "ş" : "sh"
        case "c": alternate = model.usesModernUzbekAlphabet ? "ç" : "ch"
        default: alternate = nil
        }
        return alternate.map { [letter, $0] } ?? []
    }
    private func startVariants(_ finger: Finger) {
        guard let index = finger.key else { return }
        let options = variants(for: keys[index])
        guard !options.isEmpty else { return }
        finger.repeatTask = Task { @MainActor [weak self, weak finger] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let finger, finger.key == index else { return }
            finger.variants = options; finger.selectedVariant = 0
            // Play subtle haptic feedback when variants appear
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.updateHighlights()
        }
    }

    private func startRepeating(_ finger: Finger) {
        finger.repeatTask = Task { @MainActor [weak self, weak finger] in
            try? await Task.sleep(for: .milliseconds(400))
            var interval: UInt64 = 85
            var count = 0
            while !Task.isCancelled {
                guard let self, let finger, let index = finger.key, self.keys.indices.contains(index), case .delete = self.keys[index].action else { return }
                UIDevice.current.playInputClick(); self.model.deleteBackward()
                count += 1
                // Accelerate deletion after holding longer (like native keyboard)
                if count > 8 { interval = 50 }
                else if count > 4 { interval = 65 }
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    private func startTrackpad(_ finger: Finger) {
        finger.repeatTask = Task { @MainActor [weak self, weak finger] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let finger, finger.trackpad != nil else { return }
            // Light haptic when trackpad mode activates
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.advanceTrackpad(finger, to: finger.lastPoint, at: ProcessInfo.processInfo.systemUptime)
            self.updateHighlights()
        }
    }

    private func advanceTrackpad(_ finger: Finger, to point: CGPoint, at timestamp: TimeInterval) {
        guard var trackpad = finger.trackpad else { return }
        let offset = trackpad.move(to: point, timestamp: timestamp, bounds: bounds)
        finger.trackpad = trackpad
        if trackpad.isActive || trackpad.isCancelled {
            finger.key = nil
            finger.popup.removeFromSuperview()
        }
        if offset != 0 {
            model.adjustCursor(byCharacterOffset: offset)
            // Subtle haptic for each cursor step
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
    private func activate(_ index: Int, click: Bool = true) {
        guard keys.indices.contains(index) else { return }
        if click { playKeyFeedback() }
        switch keys[index].action {
        case .text(let text):
            if model.shift == .off, fingers.values.contains(where: { finger in
                guard finger.activatedShift, let key = finger.key, keys.indices.contains(key) else { return false }
                if case .shift = keys[key].action { return true }
                return false
            }) {
                model.shiftTapped()
            }
            model.type(text)
        case .shift: model.shiftTapped()
        case .delete: model.deleteBackward()
        case .emoji: model.showEmojiKeyboard()
        case .page(let page): model.showPage(page)
        }
        refresh()
    }
    private func playKeyFeedback() {
        UIDevice.current.playInputClick()
    }
    private func updateHighlights() {
        let normal = KeyboardAppearance.character
        let function = KeyboardAppearance.function
        if model.page == .emoji {
            modeButton.backgroundColor = modeButton.isHighlighted ? KeyboardAppearance.pressedFunction : function
        }
        let trackpadActive = fingers.values.contains { $0.trackpad?.isActive == true }
        for (index, cap) in caps.enumerated() where keys.indices.contains(index) {
            let pressed = fingers.values.contains { $0.key == index }
            UIView.performWithoutAnimation {
                cap.backgroundColor = pressed
                    ? (keys[index].function ? KeyboardAppearance.pressedFunction : KeyboardAppearance.pressedCharacter)
                    : (keys[index].function ? function : normal)
                // Native-style feedback changes the fill instantly; neither the
                // artwork nor its full touch cell shrinks or moves under a finger.
                cap.transform = .identity
                // More subtle shadow for pressed state like native keyboard
                cap.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0 : (pressed ? 0.08 : 0.22)
                cap.layer.shadowRadius = pressed ? 0 : 0.5
                cap.contentAlpha = trackpadActive ? 0 : 1
            }
        }
        for finger in fingers.values {
            if !finger.variants.isEmpty, let index = finger.key, keys.indices.contains(index) {
                finger.popup.removeFromSuperview()
                let key = keys[index], panel = finger.chooser
                panel.subviews.forEach { $0.removeFromSuperview() }
                let width = CGFloat(finger.variants.count) * 46
                panel.frame = CGRect(x: min(max(key.frame.midX - 23, 0), bounds.width - width),
                                     y: max(-42, key.frame.minY - 48), width: width, height: 50)
                panel.backgroundColor = KeyboardAppearance.popup
                panel.layer.cornerRadius = 9
                panel.layer.shadowColor = UIColor.black.cgColor
                panel.layer.shadowOffset = CGSize(width: 0, height: 2)
                panel.layer.shadowRadius = 8
                panel.layer.shadowOpacity = 0.25
                panel.isUserInteractionEnabled = false
                for (i, option) in finger.variants.enumerated() {
                    let label = UILabel(frame: CGRect(x: CGFloat(i) * 46 + 3, y: 3, width: 40, height: 44))
                    label.text = model.shift == .off ? option : option.uppercased()
                    label.textAlignment = .center; label.font = KeyboardAppearance.popupFont(for: option)
                    label.textColor = finger.selectedVariant == i ? .white : KeyboardAppearance.foreground
                    label.backgroundColor = finger.selectedVariant == i ? .systemBlue : .clear
                    label.layer.cornerRadius = 6; label.clipsToBounds = true
                    panel.addSubview(label)
                }
                addSubview(panel)
                continue
            }
            guard let index = finger.key, keys.indices.contains(index), keys[index].popup else { finger.popup.removeFromSuperview(); continue }
            let key = keys[index], popup = finger.popup
            popup.text = key.title; popup.font = KeyboardAppearance.popupFont(for: key.title)
            popup.textAlignment = .center; popup.textColor = KeyboardAppearance.foreground
            popup.backgroundColor = KeyboardAppearance.popup
            popup.isUserInteractionEnabled = false; popup.isAccessibilityElement = false
            let width = max(72, key.frame.width * 1.8)
            let top = max(-65, key.frame.minY - 65)
            popup.frame = CGRect(x: min(max(key.frame.midX - width / 2, 0), bounds.width - width),
                                 y: top, width: width, height: key.frame.maxY - 3 - top)
            popup.stem = key.frame.insetBy(dx: 3, dy: 6).offsetBy(dx: -popup.frame.minX, dy: -top)
            popup.updateShape()
            addSubview(popup)
        }
    }
}

/// A connected keycap balloon rather than a floating rectangular tooltip.
@MainActor
private final class NativeKeyPopup: UILabel {
    var stem: CGRect = .zero
    private let shape = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.mask = shape
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowRadius = 12
        layer.shadowOpacity = 0.3
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawText(in rect: CGRect) {
        super.drawText(in: CGRect(x: 0, y: 0, width: bounds.width, height: 50))
    }
    func updateShape() {
        let width = bounds.width, bottom = bounds.height
        let left = max(0, stem.minX), right = min(width, stem.maxX)
        let path = UIBezierPath()
        // Top rounded corners
        path.move(to: CGPoint(x: 13, y: 0))
        path.addLine(to: CGPoint(x: width - 13, y: 0))
        path.addQuadCurve(to: CGPoint(x: width, y: 13), controlPoint: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: width, y: 37))
        // Smooth connection to stem
        path.addCurve(to: CGPoint(x: right, y: 50),
                      controlPoint1: CGPoint(x: width, y: 44),
                      controlPoint2: CGPoint(x: right + 3, y: 48))
        path.addLine(to: CGPoint(x: right, y: bottom - 5))
        path.addQuadCurve(to: CGPoint(x: right - 5, y: bottom), controlPoint: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + 5, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - 5), controlPoint: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: 50))
        path.addCurve(to: CGPoint(x: 0, y: 37),
                      controlPoint1: CGPoint(x: left - 3, y: 48),
                      controlPoint2: CGPoint(x: 0, y: 44))
        path.addLine(to: CGPoint(x: 0, y: 13))
        path.addQuadCurve(to: CGPoint(x: 13, y: 0), controlPoint: .zero)
        path.close()
        shape.frame = bounds
        shape.path = path.cgPath
        shape.shadowPath = path.cgPath
    }
}

@MainActor
private final class AccessibleKeyCap: UIView {
    let icon = UIImageView()
    private let titleLabel = UILabel()
    let localeBadge = UILabel()
    var activation: (() -> Void)?
    var text: String? { get { titleLabel.text } set { titleLabel.text = newValue } }
    var font: UIFont? { get { titleLabel.font } set { titleLabel.font = newValue } }
    var contentAlpha: CGFloat {
        get { titleLabel.alpha }
        set { titleLabel.alpha = newValue; icon.alpha = newValue; localeBadge.alpha = newValue }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        // UILabel paints its own rectangular background when unclipped. A UIView
        // owns the rounded fill; the transparent label cannot square its corners.
        layer.cornerRadius = NativeKeyboardMetrics.cornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = KeyboardAppearance.keyShadow.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 0.5)
        layer.shadowRadius = 0
        clipsToBounds = false
        isUserInteractionEnabled = false
        isAccessibilityElement = true; accessibilityTraits = [.keyboardKey]
        titleLabel.backgroundColor = .clear
        titleLabel.textAlignment = .center; titleLabel.textColor = KeyboardAppearance.foreground
        titleLabel.adjustsFontSizeToFitWidth = true; titleLabel.minimumScaleFactor = 0.8
        localeBadge.textColor = KeyboardAppearance.secondaryForeground.withAlphaComponent(0.5)
        localeBadge.font = .systemFont(ofSize: 9, weight: .regular)
        localeBadge.textAlignment = .right
        icon.contentMode = .scaleAspectFit; icon.tintColor = KeyboardAppearance.foreground
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        addSubview(titleLabel); addSubview(icon); addSubview(localeBadge)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = bounds.insetBy(dx: 1, dy: 0)
        icon.frame = CGRect(x: max(0, (bounds.width - 24) / 2), y: max(0, (bounds.height - 24) / 2), width: min(24, bounds.width), height: min(24, bounds.height))
        localeBadge.frame = CGRect(x: 5, y: max(0, bounds.height - 15), width: max(0, bounds.width - 10), height: 12)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }
    override func accessibilityActivate() -> Bool { activation?(); return true }
}

@MainActor private final class NativeKeyboardModeButton: UIButton {
    var highlightChanged: (() -> Void)?
    override var isHighlighted: Bool { didSet { highlightChanged?() } }
}

/// Shared by rendering and geometry checks; all bottom controls retain full cells.
enum NativeKeyboardMetrics {
    static let horizontalGutter: CGFloat = 3
    static let verticalGutter: CGFloat = 6
    static let cornerRadius: CGFloat = 7.0
    static func bottomRow(width: CGFloat, y: CGFloat, height: CGFloat) -> (page: CGRect, emoji: CGRect, space: CGRect, returnKey: CGRect) {
        let small = max(44, min(54, width * 0.125))
        let enter = max(76, width * 0.25)
        return (CGRect(x: 0, y: y, width: small, height: height),
                CGRect(x: small, y: y, width: small, height: height),
                CGRect(x: small * 2, y: y, width: max(0, width - small * 2 - enter), height: height),
                CGRect(x: width - enter, y: y, width: enter, height: height))
    }
}

/// A local Unicode keyboard: selecting emoji inserts text in the current host.
/// The separate Keyboards control retains Apple's public input-mode picker.
@MainActor
private final class NativeEmojiPanel: UIView {
    private let categories = EmojiPanelScrollView()
    private let grid = EmojiPanelScrollView()
    private let abc = EmojiPanelButton(type: .custom)
    private let delete = EmojiPanelButton(type: .custom)
    private let empty = UILabel()
    private var categoryButtons: [UIButton] = []
    private var emojiButtons: [UIButton] = []
    private var model: KeyboardModel?
    private var feedback: (() -> Void)?
    private var changed: (() -> Void)?
    private var gridIdentity = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        categories.showsHorizontalScrollIndicator = false
        grid.alwaysBounceVertical = true; grid.showsVerticalScrollIndicator = false
        grid.delaysContentTouches = false; grid.canCancelContentTouches = true
        addSubview(categories); addSubview(grid); addSubview(abc); addSubview(delete)
        abc.setTitle("ABC", for: .normal); abc.accessibilityLabel = "Harflarga qaytish"
        abc.addTarget(self, action: #selector(showLetters), for: .touchUpInside)
        delete.setImage(UIImage(systemName: "delete.left"), for: .normal)
        delete.accessibilityLabel = "O’chirish"
        delete.addTarget(self, action: #selector(deleteCharacter), for: .touchUpInside)
        empty.text = "So’nggi emojilar shu yerda ko’rinadi"
        empty.font = .systemFont(ofSize: 14); empty.textColor = KeyboardAppearance.secondaryForeground
        empty.textAlignment = .center; empty.numberOfLines = 2; grid.addSubview(empty)
        for (index, category) in EmojiCategory.allCases.enumerated() {
            let button = EmojiPanelButton(type: .custom)
            button.tag = index; button.setTitle(category.symbol, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 24)
            button.accessibilityLabel = category.title
            button.addTarget(self, action: #selector(selectCategory(_:)), for: .touchUpInside)
            categories.addSubview(button); categoryButtons.append(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(model: KeyboardModel, modeButton: UIButton, feedback: @escaping () -> Void, changed: @escaping () -> Void) {
        self.model = model; self.feedback = feedback; self.changed = changed
        let selected = model.selectedEmojiCategory
        for (index, button) in categoryButtons.enumerated() {
            let active = EmojiCategory.allCases[index] == selected
            button.isSelected = active
            button.accessibilityTraits = active ? [.button, .selected] : [.button]
            button.backgroundColor = active ? KeyboardAppearance.function : .clear
        }
        let identity = "\(selected)-\(model.visibleEmoji.joined())"
        if identity != gridIdentity {
            gridIdentity = identity
            emojiButtons.forEach { $0.removeFromSuperview() }; emojiButtons.removeAll()
            for emoji in model.visibleEmoji {
                let button = EmojiPanelButton(type: .custom)
                button.setTitle(emoji, for: .normal); button.accessibilityLabel = emoji
                button.titleLabel?.font = .systemFont(ofSize: 30)
                button.addTarget(self, action: #selector(insertEmoji(_:)), for: .touchUpInside)
                grid.addSubview(button); emojiButtons.append(button)
            }
            empty.isHidden = !emojiButtons.isEmpty
            grid.contentOffset = .zero
        }
        modeButton.setTitle("Klaviaturalar", for: .normal)
        modeButton.setTitleColor(KeyboardAppearance.foreground, for: .normal)
        modeButton.titleLabel?.font = .systemFont(ofSize: 13)
        modeButton.layer.cornerRadius = NativeKeyboardMetrics.cornerRadius
        modeButton.backgroundColor = KeyboardAppearance.function
        layoutControls(modeButton: modeButton)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let modeButton = subviews.first(where: { $0 is NativeKeyboardModeButton }) as? UIButton {
            layoutControls(modeButton: modeButton)
        }
    }
    private func layoutControls(modeButton: UIButton) {
        let width = bounds.width
        categories.frame = CGRect(x: 0, y: 0, width: width, height: 44)
        for (index, button) in categoryButtons.enumerated() {
            button.frame = CGRect(x: CGFloat(index) * 44, y: 0, width: 44, height: 44)
        }
        categories.contentSize = CGSize(width: CGFloat(categoryButtons.count) * 44, height: 44)
        grid.frame = CGRect(x: 0, y: 44, width: width, height: max(44, bounds.height - 88))
        let columns = max(1, Int(width / 44)); let cell = width / CGFloat(columns)
        for (index, button) in emojiButtons.enumerated() {
            button.frame = CGRect(x: CGFloat(index % columns) * cell, y: CGFloat(index / columns) * 44,
                                  width: cell, height: 44)
        }
        grid.contentSize = CGSize(width: width, height: CGFloat((emojiButtons.count + columns - 1) / columns) * 44)
        empty.frame = CGRect(x: 24, y: 20, width: max(0, width - 48), height: 60)
        let footerY = bounds.height - 44
        abc.frame = CGRect(x: 3, y: footerY, width: 61, height: 44)
        modeButton.frame = CGRect(x: 70, y: footerY, width: 126, height: 44)
        delete.frame = CGRect(x: width - 64, y: footerY, width: 61, height: 44)
    }
    @objc private func showLetters() { feedback?(); model?.showPage(.letters); changed?() }
    @objc private func deleteCharacter() { feedback?(); model?.deleteBackward() }
    @objc private func selectCategory(_ sender: UIButton) {
        guard EmojiCategory.allCases.indices.contains(sender.tag) else { return }
        feedback?(); model?.selectEmojiCategory(EmojiCategory.allCases[sender.tag]); changed?()
    }
    @objc private func insertEmoji(_ sender: UIButton) {
        guard let emoji = sender.title(for: .normal) else { return }
        feedback?(); model?.insertEmoji(emoji); changed?()
    }
}

/// Drags that begin on an emoji belong to scrolling once UIKit's pan starts;
/// UIButton tracking is canceled so releasing a scroll never inserts an emoji.
@MainActor
private final class EmojiPanelScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

@MainActor
private final class EmojiPanelButton: UIButton {
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? KeyboardAppearance.pressedFunction : (isSelected ? KeyboardAppearance.function : .clear) }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = NativeKeyboardMetrics.cornerRadius
        setTitleColor(KeyboardAppearance.foreground, for: .normal)
        tintColor = KeyboardAppearance.foreground
        titleLabel?.font = .systemFont(ofSize: 16)
        imageView?.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Pure hit testing keeps the full key cell tappable, including its visual gutters.
/// Variable-width space/return keys retain their actual boundaries.
enum NativeKeyHitTesting {
    static func index(at point: CGPoint, bounds: CGRect, frames: [CGRect], retaining previous: Int? = nil) -> Int? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        if let previous, frames.indices.contains(previous), frames[previous].insetBy(dx: -3, dy: -3).contains(point) {
            return previous
        }
        if let exact = frames.firstIndex(where: { $0.contains(point) }) { return exact }
        let rowHeight = bounds.height / 4
        let row = min(3, Int((point.y - bounds.minY) / rowHeight))
        return frames.indices.filter { Int((frames[$0].midY - bounds.minY) / rowHeight) == row }
            .min { abs(frames[$0].midX - point.x) < abs(frames[$1].midX - point.x) }
    }
}

/// Only a touch that began on Space creates this gesture. A hold consumes the
/// space even without movement; cursor steps retain sub-character drag distance.
struct NativeSpacebarTrackpad {
    static let holdDelay: TimeInterval = 0.15  // Faster activation like native
    static let pointsPerCharacter: CGFloat = 6  // More responsive horizontal movement
    static let pointsPerLine: CGFloat = 15  // Sensitive vertical movement
    private let beganAt: TimeInterval
    private let spaceFrame: CGRect
    private let origin: CGPoint
    private var consumedX: CGFloat
    private var consumedY: CGFloat
    private(set) var isActive = false
    private(set) var isCancelled = false

    struct Result { let cursorOffset: Int; let insertSpace: Bool }

    init(origin: CGPoint, beganAt: TimeInterval, spaceFrame: CGRect) {
        self.beganAt = beganAt
        self.spaceFrame = spaceFrame
        self.origin = origin
        consumedX = origin.x
        consumedY = origin.y
    }

    mutating func move(to point: CGPoint, timestamp: TimeInterval, bounds: CGRect) -> Int {
        guard !isCancelled else { return 0 }
        guard bounds.contains(point) else { cancel(); return 0 }
        guard timestamp >= beganAt else { return 0 }

        // Activate on hold or any movement (like native iOS)
        let horizontalDistance = abs(point.x - origin.x)
        let verticalDistance = abs(point.y - origin.y)
        if timestamp - beganAt >= Self.holdDelay || horizontalDistance > 8 || verticalDistance > 8 {
            isActive = true
        }
        guard isActive else { return 0 }

        // Calculate horizontal offset
        let offsetX = Int((point.x - consumedX) / Self.pointsPerCharacter)
        consumedX += CGFloat(offsetX) * Self.pointsPerCharacter

        // Calculate vertical offset (negative = up, positive = down)
        let offsetY = Int((point.y - consumedY) / Self.pointsPerLine)
        consumedY += CGFloat(offsetY) * Self.pointsPerLine

        // Native iOS behavior: vertical movement jumps lines more naturally
        // Approximate 35 characters per line for typical text width
        return offsetX + (offsetY * 35)
    }

    mutating func finish(at point: CGPoint, timestamp: TimeInterval, bounds: CGRect) -> Result {
        let offset = move(to: point, timestamp: timestamp, bounds: bounds)
        return Result(cursorOffset: offset, insertSpace: !isActive && !isCancelled &&
            timestamp >= beganAt && spaceFrame.contains(point) && bounds.contains(point))
    }

    mutating func cancel() { isCancelled = true; isActive = false }
}
