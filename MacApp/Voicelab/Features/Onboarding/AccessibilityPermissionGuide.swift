import AppKit
import ApplicationServices
import SwiftUI

/// A real file drag source beside System Settings. It never changes TCC or treats
/// a completed drag as permission; only the OS trust check can dismiss it as granted.
@MainActor
final class AccessibilityPermissionGuide {
    /// Launch Services may keep the previous product name for the same bundle ID.
    /// This is a hint only; it must never be used as evidence of a permission grant.
    static var settingsAlias: String? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let names = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier).compactMap { url -> String? in
            guard url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
                  let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            return name == "Echo" ? nil : name
        }
        return names.sorted().first
    }

    private var panel: NSPanel?
    private var tracking: Task<Void, Never>?
    private var content: NSHostingView<PermissionDragGuide>?

    func show(language: WelcomeLanguage) {
        dismiss()
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityLabel(language.permissionsCopy.dragInstruction)
        let content = NSHostingView(rootView: PermissionDragGuide(language: language, settingsAlias: Self.settingsAlias) { [weak self] in
            self?.dismiss()
        })
        panel.contentView = content
        self.content = content
        self.panel = panel
        tracking = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if AccessibilityAccess.current.isGranted { self.dismiss(); return }
                self.positionBesideSettings()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    func dismiss() {
        tracking?.cancel()
        tracking = nil
        panel?.orderOut(nil)
        panel = nil
        content = nil
    }

    private func positionBesideSettings() {
        guard let panel else { return }
        guard let settings = NSWorkspace.shared.frontmostApplication,
              settings.bundleIdentifier == "com.apple.systempreferences",
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.filter({
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == settings.processIdentifier &&
                  ($0[kCGWindowLayer as String] as? Int) == 0
              }).max(by: { Self.windowArea($0) < Self.windowArea($1) }),
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let quartzFrame = CGRect(dictionaryRepresentation: bounds),
              let desktopTop = NSScreen.screens.first?.frame.maxY
        else { panel.orderOut(nil); return }
        // CG window coordinates start at the primary display's top-left; AppKit
        // uses bottom-left coordinates, including displays with negative origins.
        let settingsFrame = CGRect(x: quartzFrame.minX, y: desktopTop - quartzFrame.maxY,
                                   width: quartzFrame.width, height: quartzFrame.height)
        guard let screen = NSScreen.screens.max(by: {
            $0.frame.intersection(settingsFrame).area < $1.frame.intersection(settingsFrame).area
        }) else { panel.orderOut(nil); return }
        let width = min(420.0, screen.visibleFrame.width - 24)
        // Measure after fixing the width so translated instructions can wrap.
        if content?.rootView.width != width { content?.rootView.width = width }
        let height = content?.fittingSize.height ?? 228
        let frame = Self.frame(beside: settingsFrame, visibleScreen: screen.visibleFrame,
                               size: CGSize(width: width, height: height))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private static func windowArea(_ window: [String: Any]) -> CGFloat {
        guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return 0 }
        return frame.area
    }

    static func frame(beside settings: CGRect, visibleScreen screen: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, screen.width - 24)
        let height = min(size.height, screen.height - 24)
        // Align with the settings content, rather than pointing at its sidebar.
        let x = min(max(settings.maxX - width - 20, screen.minX + 12), screen.maxX - width - 12)
        // Prefer below Settings; overlap only its bottom edge when space is tight.
        let y = max(screen.minY + 12, min(settings.minY - height - 12, screen.maxY - height - 12))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private struct PermissionDragGuide: View {
    let language: WelcomeLanguage
    var settingsAlias: String? = nil
    let dismiss: () -> Void
    var width: CGFloat = 420
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cueRaised = false
    private var copy: PermissionsCopy { language.permissionsCopy }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                instruction(1, copy.dragInstruction)
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24).contentShape(.rect)
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(copy.closeHelp)
                    .accessibilityIdentifier("permissions-drag-close")
            }
            appDragSource
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    instruction(2, copy.accessibilityInstruction)
                    // Illustration, not an interactive or permission-status switch.
                    Capsule().fill(Color(nsColor: .systemBlue))
                        .frame(width: 28, height: 17)
                        .overlay(alignment: .trailing) {
                            Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                        }
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityHidden(true)
                }
                Text(copy.dragConfirmation)
                    .font(WelcomeType.font(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
                if let settingsAlias {
                    Text(copy.settingsAlias.replacingOccurrences(of: "{app}", with: settingsAlias))
                        .font(WelcomeType.font(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 30)
                }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            } label: {
                Label(copy.dragFinder, systemImage: "folder")
            }
                .font(WelcomeType.font(size: 11)).buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 30)
                .accessibilityIdentifier("permissions-drag-finder")
        }
        .padding(18).frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number, format: .number).font(WelcomeType.font(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(.primary.opacity(0.08), in: .circle)
                .accessibilityHidden(true)
            Text(text).font(WelcomeType.font(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appDragSource: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 36, height: 36)
            Text("Echo").font(WelcomeType.font(size: 15, weight: .semibold))
            Spacer()
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .offset(y: cueRaised ? -3 : 3)
                .frame(width: 28)
                .task(id: reduceMotion) {
                    cueRaised = false
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.85).repeatCount(4, autoreverses: true)) {
                        cueRaised = true
                    }
                }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.14),
                                                              style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(.rect)
        .overlay {
            ApplicationBundleDragSource(applicationURL: Bundle.main.bundleURL)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Echo. \(copy.dragInstruction)")
        .accessibilityIdentifier("permissions-drag-app")
    }
}
