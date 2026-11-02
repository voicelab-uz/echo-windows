import UIKit

// Appended to the actual production NativeKeySurface source by the simulator
// harness. No replacement drawing code: assertions inspect rendered cap pixels.
extension NativeKeyboardSurface {
    func renderRegression(pressed: Bool) {
        if pressed, let index = keys.firstIndex(where: { $0.title == "a" }) {
            caps[index].backgroundColor = KeyboardAppearance.pressedCharacter
            let key = keys[index]
            let popup = NativeKeyPopup()
            popup.text = key.title; popup.font = KeyboardAppearance.popupFont(for: key.title)
            popup.textAlignment = .center; popup.textColor = KeyboardAppearance.foreground
            popup.backgroundColor = KeyboardAppearance.popup
            popup.frame = CGRect(x: key.frame.midX - 29, y: key.frame.minY - 42,
                                 width: 58, height: key.frame.height + 37)
            popup.stem = key.frame.insetBy(dx: 3, dy: 5).offsetBy(dx: -popup.frame.minX, dy: -popup.frame.minY)
            popup.updateShape(); addSubview(popup)
        }
    }
    func checkRegression(modeSwitches: () -> Int, inserted: () -> [String], deletes: () -> Int,
                         canvas: UIView, emojiImageURL: URL) {
        let before = modeSwitches()
        let originalLayout = model.layout
        let index = keys.firstIndex { if case .emoji = $0.action { return true }; return false }!
        precondition(keys[index].frame.width >= 44 && keys[index].frame.height >= 44)
        precondition(caps[index].accessibilityActivate())
        precondition(model.page == .emoji && modeSwitches() == before,
                     "One smiley activation must open local emoji, never switch keyboard or app")
        precondition(!emojiPanel.isHidden && caps.allSatisfy(\.isHidden))
        precondition(modeButton.frame.width >= 44 && modeButton.frame.height >= 44)
        precondition(modeButton.actions(forTarget: self, forControlEvent: .allTouchEvents)?.contains("modeInputEvent:event:") == true)
        modeButton.sendActions(for: .touchCancel)
        precondition(modeSwitches() == before, "Cancellation must not switch keyboards")
        modeButton.sendActions(for: .touchUpInside)
        precondition(modeSwitches() == before + 1, "Explicit Keyboards activation must switch once")
        modeButton.isHighlighted = true
        precondition(modeButton.backgroundColor == KeyboardAppearance.pressedFunction)
        modeButton.isHighlighted = false
        func buttons(_ view: UIView) -> [UIButton] {
            view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons($0) }
        }
        let category = buttons(emojiPanel).first { $0.tag == 1 && $0.accessibilityLabel == EmojiCategory.allCases[1].title }!
        category.sendActions(for: .touchUpInside)
        let grid = emojiPanel.subviews.compactMap { $0 as? UIScrollView }[1]
        let emojiButton = grid.subviews.compactMap { $0 as? UIButton }.first!
        let emoji = emojiButton.title(for: .normal)!
        precondition(emojiButton.frame.width >= 44 && emojiButton.frame.height >= 44)
        let count = inserted().count
        precondition(grid.touchesShouldCancel(in: emojiButton), "A drag beginning on emoji must cancel button tracking and scroll")
        emojiButton.sendActions(for: .touchDown)
        emojiButton.cancelTracking(with: nil)
        emojiButton.sendActions(for: .touchCancel)
        precondition(inserted().count == count, "Canceled emoji tracking must not insert")
        emojiButton.sendActions(for: .touchUpInside)
        precondition(inserted().count == count + 1 && inserted().last == emoji && model.page == .emoji,
                     "Emoji must insert exactly one full Unicode string while panel remains open")
        precondition(modeSwitches() == before + 1)
        canvas.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: canvas.bounds, format: format).image { canvas.layer.render(in: $0.cgContext) }
        try! image.pngData()!.write(to: emojiImageURL)
        let deleteButton = buttons(emojiPanel).first { $0.accessibilityLabel == "O‘chirish" }!
        let deleteCount = deletes(); deleteButton.sendActions(for: .touchUpInside)
        precondition(deletes() == deleteCount + 1)
        buttons(emojiPanel).first { $0.accessibilityLabel == "Harflarga qaytish" }!.sendActions(for: .touchUpInside)
        precondition(model.page == .letters && model.layout == originalLayout && emojiPanel.isHidden,
                     "ABC must restore the selected language layout")
    }
    func checkModernW(inserted: () -> [String]) {
        precondition(model.layout == .uzbek && model.usesModernUzbekAlphabet)
        let top = keys.filter { $0.frame.minY == 0 }
        precondition(top.count == 11 && top[1].title.lowercased() == "w" && top.last?.title.lowercased() == "ş")
        let index = 1, cap = caps[index], title = keys[index].title
        let availableWidth = cap.bounds.width - 2
        let minimumFont = UIFont.systemFont(ofSize: cap.font!.pointSize * 0.8)
        let minimumGlyphWidth = (title as NSString).size(withAttributes: [.font: minimumFont]).width
        precondition(minimumGlyphWidth <= availableWidth,
                     "W must fit the actual label width within its existing minimum font scale")
        precondition(cap.layer.cornerRadius == NativeKeyboardMetrics.cornerRadius && cap.bounds.height == 44)
        precondition(bounds.height == 216, "Eleven letters must not increase keyboard height")
        for x in 0..<Int(bounds.width) {
            precondition(keyIndex(at: CGPoint(x: CGFloat(x), y: 20)) != nil, "11-key row must have no dead touch gaps")
        }
        let previous = inserted().count
        precondition(cap.accessibilityActivate())
        precondition(inserted().count == previous + 1 && inserted().last == title, "Visible W must insert exactly its shown case")
    }
    func checkCornerPixels(in view: UIView) {
        let cap = caps[0]
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { view.layer.render(in: $0.cgContext) }
        let cg = image.cgImage!
        let pixels = cg.dataProvider!.data! as Data
        func rgb(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = y * cg.bytesPerRow + x * (cg.bitsPerPixel / 8)
            return Array(pixels[offset..<(offset + 3)])
        }
        let rect = cap.convert(cap.bounds, to: view)
        let corner = rgb(Int(rect.minX), Int(rect.minY))
        let backdrop = rgb(0, 0)
        let fill = rgb(Int(rect.minX + rect.width / 2), Int(rect.minY + 3))
        precondition(zip(corner, backdrop).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
                     "Actual rendered corner must reveal canvas, not a rectangular UILabel background")
        precondition(zip(fill, backdrop).contains { abs(Int($0) - Int($1)) > 10 }, "Cap fill must remain visible")
    }
}

@main @MainActor final class KeyboardRenderingApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController(); window.rootViewController = controller
        self.window = window; window.makeKeyAndVisible()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            runFixtures(controller)
        }
        return true
    }
    func runFixtures(_ controller: UIViewController) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var switches = 0
        var inserted: [String] = []
        var deletes = 0
        for (name, style, pressed) in [("light", UIUserInterfaceStyle.light, false), ("dark", .dark, false), ("dark-pressed", .dark, true)] {
            controller.overrideUserInterfaceStyle = style
            let canvas = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 280))
            canvas.overrideUserInterfaceStyle = style; canvas.backgroundColor = KeyboardAppearance.keyboardCanvas
            controller.view.addSubview(canvas)
            let model = KeyboardModel()
            model.actions = KeyboardActions(insertText: { inserted.append($0) }, insertDictation: { _ in }, deleteBackward: { deletes += 1 },
                nextKeyboard: { switches += 1 }, shouldCapitalize: { false }, openApp: { false },
                openSettings: { false }, openSubscription: { false })
            model.selectLayout(.english)
            let surface = NativeKeyboardSurface(model: model)
            surface.frame = CGRect(x: 0, y: 64, width: 393, height: 216)
            canvas.addSubview(surface); surface.refresh(); canvas.layoutIfNeeded(); surface.layoutIfNeeded()
            surface.checkRegression(modeSwitches: { switches }, inserted: { inserted }, deletes: { deletes },
                                    canvas: canvas, emojiImageURL: directory.appendingPathComponent("keyboard-emoji-\(name).png"))
            surface.checkCornerPixels(in: canvas)
            surface.renderRegression(pressed: pressed); canvas.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 3
            let image = UIGraphicsImageRenderer(bounds: canvas.bounds, format: format).image { canvas.layer.render(in: $0.cgContext) }
            try! image.pngData()!.write(to: directory.appendingPathComponent("keyboard-\(name).png"))
            canvas.removeFromSuperview()
        }
        for width: CGFloat in [320, 375, 393] {
            for uppercase in [false, true] {
                let canvas = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 280))
                canvas.overrideUserInterfaceStyle = .dark; canvas.backgroundColor = KeyboardAppearance.keyboardCanvas
                controller.view.addSubview(canvas)
                let model = KeyboardModel()
                model.actions = KeyboardActions(insertText: { inserted.append($0) }, insertDictation: { _ in }, deleteBackward: {},
                    nextKeyboard: {}, shouldCapitalize: { false }, openApp: { false }, openSettings: { false }, openSubscription: { false })
                model.selectLayout(.uzbek)
                if !model.usesModernUzbekAlphabet { model.toggleUzbekAlphabet() }
                if uppercase { model.shiftTapped() }
                let surface = NativeKeyboardSurface(model: model)
                surface.frame = CGRect(x: 0, y: 64, width: width, height: 216)
                canvas.addSubview(surface); surface.refresh(); canvas.layoutIfNeeded()
                surface.checkCornerPixels(in: canvas)
                let format = UIGraphicsImageRendererFormat(); format.scale = 3
                let image = UIGraphicsImageRenderer(bounds: canvas.bounds, format: format).image { canvas.layer.render(in: $0.cgContext) }
                try! image.pngData()!.write(to: directory.appendingPathComponent("keyboard-modern-\(Int(width))-\(uppercase ? "upper" : "lower").png"))
                surface.checkModernW(inserted: { inserted })
                canvas.removeFromSuperview()
            }
        }
        try! Data("Actual UIKit modern11-key W geometry/font/insertion at320/375/393, corner pixels, one-tap local emoji, Unicode insertion/delete/ABC, Keyboards handoff/cancellation/highlight, light/dark/pressed renders passed\n".utf8)
            .write(to: directory.appendingPathComponent("passed.txt"))
    }
}
