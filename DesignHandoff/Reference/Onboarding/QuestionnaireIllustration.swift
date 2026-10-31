import SwiftUI
import VoiceLabCore

/// Quiet, local illustrations. They never capture audio, inspect apps, or start a meeting.
struct QuestionnaireIllustration: View {
    let question: ContextQuestion
    let language: WelcomeLanguage
    let answer: ContextAnswer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0
    private let violet = Color(red: 0.48, green: 0.44, blue: 0.69)
    private let peach = Color(red: 0.96, green: 0.82, blue: 0.72)
    private let sage = Color(red: 0.75, green: 0.83, blue: 0.78)

    var body: some View {
        GeometryReader { geometry in
            let scale = min((geometry.size.width - 40) / 480, (geometry.size.height - 40) / 440, 1.15)
            ZStack {
                Group {
                    switch question {
                    case .discovery: discovery
                    case .intent: voiceAndNotes
                    case .work: workspace
                    case .writing: writing
                    case .meetingApps: meeting
                    case .meetingProblems: checklist
                    }
                }
                .id(question)
                .transition(.opacity)
                .frame(width: 480, height: 440)
                .scaleEffect(max(0.3, scale))
                .frame(width: 480 * max(0.3, scale), height: 440 * max(0.3, scale))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .environment(\.layoutDirection, .leftToRight)
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.35), value: question)
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.25), value: answer.choices)
        .task(id: Playback(question: question, reduced: reduceMotion)) { await play() }
    }

    private var discovery: some View {
        ZStack {
            Circle().strokeBorder(violet.opacity(0.12), lineWidth: 1).frame(width: 320, height: 320)
            Circle().strokeBorder(violet.opacity(0.08), lineWidth: 1).frame(width: 228, height: 228)
            Path { path in
                path.move(to: CGPoint(x: 100, y: 130))
                path.addCurve(to: CGPoint(x: 236, y: 214), control1: CGPoint(x: 200, y: 100), control2: CGPoint(x: 130, y: 220))
                path.move(to: CGPoint(x: 380, y: 303))
                path.addCurve(to: CGPoint(x: 242, y: 228), control1: CGPoint(x: 280, y: 345), control2: CGPoint(x: 345, y: 225))
            }
            .trim(from: 0, to: phase == 0 ? 0.1 : 1)
            .stroke(violet.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 6]))
            symbolTile("bubble.left.and.bubble.right", color: peach, size: 68).rotationEffect(.degrees(-10)).offset(x: -140, y: -90)
            symbolTile("play.rectangle", color: .white, size: 58).rotationEffect(.degrees(9)).offset(x: 118, y: -112)
            symbolTile("magnifyingglass", color: sage, size: 64).rotationEffect(.degrees(-7)).offset(x: 140, y: 84)
            symbolTile("paperplane", color: .white, size: 54).rotationEffect(.degrees(8)).offset(x: -115, y: 128)
            echoMark(size: 92)
                .scaleEffect(phase == 1 && !reduceMotion ? 1.04 : 1)
        }
    }

    private var voiceAndNotes: some View {
        ZStack {
            paper(width: 244, height: 242) {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "text.alignleft").font(.system(size: 23, weight: .medium)).foregroundStyle(violet)
                    inkLines(widths: [170, 188, 142, 174], visible: phase > 0)
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(sage.opacity(0.9))
                        line(width: 92, color: violet.opacity(0.16))
                    }.opacity(phase > 1 ? 1 : 0)
                }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.rotationEffect(.degrees(-5)).offset(x: -48, y: -30)
            paper(width: 176, height: 164) {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(violet)
                    inkLines(widths: [116, 93, 105], visible: phase > 1)
                }.padding(24)
            }.rotationEffect(.degrees(7)).offset(x: 115, y: 76)
            audioRibbon.offset(x: -25, y: 153)
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 20).fill(WelcomePalette.ink)
                RoundedRectangle(cornerRadius: 13).fill(WelcomePalette.canvas).padding(8)
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                    .fill(WelcomePalette.ink).frame(width: 68, height: 14)
                VStack(spacing: 22) {
                    symbolTile(roleSymbol, color: WelcomePalette.lavender, size: 76)
                        .contentTransition(.opacity)
                    if let label = selectedLabel {
                        Text(label).font(WelcomeType.font(size: 22, weight: .semibold))
                            .multilineTextAlignment(.center).lineLimit(2).contentTransition(.opacity)
                    } else {
                        HStack(spacing: 22) {
                            ForEach(["curlybraces", "pencil.and.outline", "chart.bar", "graduationcap"], id: \.self) { symbol in
                                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(violet.opacity(0.6))
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(0..<13) { i in
                            Capsule().fill(violet.opacity(0.45))
                                .frame(width: 5, height: phase == 1 ? CGFloat([8, 17, 11, 26, 33, 18, 40, 20, 32, 16, 25, 12, 7][i]) : 5)
                        }
                    }.frame(height: 40)
                }.padding(.horizontal, 28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(width: 360, height: 248)
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                .fill(Color(red: 0.78, green: 0.79, blue: 0.81)).frame(width: 410, height: 13)
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                        .fill(WelcomePalette.ink.opacity(0.17)).frame(width: 72, height: 5)
                }
        }
        .shadow(color: WelcomePalette.ink.opacity(0.1), radius: 18, y: 20)
    }

    private var writing: some View {
        ZStack {
            paper(width: 206, height: 244) {
                VStack(alignment: .leading, spacing: 23) {
                    Image(systemName: "note.text").font(.system(size: 23)).foregroundStyle(violet)
                    inkLines(widths: [142, 118, 150, 131, 95], visible: true)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.rotationEffect(.degrees(-9)).offset(x: -94, y: -23)
            paper(width: 268, height: 208) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Image(systemName: "envelope").font(.system(size: 24)).foregroundStyle(violet)
                        Spacer()
                        Circle().fill(peach).frame(width: 24, height: 24)
                    }
                    inkLines(widths: [201, 174, 193], visible: phase > 0)
                    HStack { Spacer(); Image(systemName: "paperplane.fill").font(.system(size: 17)).foregroundStyle(violet) }
                }.padding(24)
            }.rotationEffect(.degrees(5)).offset(x: 68, y: 8)
            audioRibbon.offset(x: 20, y: 150)
        }
    }

    private var meeting: some View {
        ZStack {
            paper(width: 348, height: 268) {
                VStack(spacing: 12) {
                    HStack(spacing: 5) {
                        ForEach(0..<3) { _ in Circle().fill(WelcomePalette.ink.opacity(0.15)).frame(width: 6, height: 6) }
                        Spacer()
                        Image(systemName: "video").font(.system(size: 13)).foregroundStyle(violet)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                        ForEach(0..<4) { index in
                            RoundedRectangle(cornerRadius: 9)
                                .fill([peach.opacity(0.65), WelcomePalette.lavender, sage.opacity(0.6), Color(red: 0.91, green: 0.86, blue: 0.79)][index])
                                .overlay {
                                    Image(systemName: "person.crop.square.fill")
                                        .font(.system(size: 44, weight: .ultraLight))
                                        .foregroundStyle(WelcomePalette.ink.opacity(0.6))
                                }
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(violet.opacity(phase == index % 3 ? 0.65 : 0), lineWidth: 1.5))
                                .frame(height: 78)
                        }
                    }
                    HStack(spacing: 22) {
                        Image(systemName: "mic"); Image(systemName: "video"); Image(systemName: "rectangle.on.rectangle")
                        Image(systemName: "phone.down.fill").foregroundStyle(WelcomePalette.coral)
                    }.font(.system(size: 12)).padding(.top, 3)
                }.padding(18)
            }.rotationEffect(.degrees(-3)).offset(x: -30, y: -22)
            paper(width: 153, height: 188) {
                VStack(alignment: .leading, spacing: 18) {
                    echoMark(size: 30)
                    inkLines(widths: [105, 88, 99, 69], visible: phase > 0)
                    Image(systemName: "checkmark").foregroundStyle(violet).opacity(phase == 2 ? 1 : 0)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.rotationEffect(.degrees(6)).offset(x: 140, y: 96)
        }
    }

    private var checklist: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(sage.opacity(0.45)).frame(width: 248, height: 310)
                .rotationEffect(.degrees(-8)).offset(x: -20, y: 4)
            paper(width: 270, height: 316) {
                VStack(alignment: .leading, spacing: 25) {
                    HStack { echoMark(size: 30); Spacer(); Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(violet) }
                    ForEach(0..<4) { index in
                        HStack(spacing: 13) {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(violet.opacity(0.4), lineWidth: 1).frame(width: 20, height: 20)
                                .overlay {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(violet)
                                        .opacity(index <= phase ? 1 : 0)
                                }
                            VStack(alignment: .leading, spacing: 7) {
                                line(width: CGFloat([145, 125, 138, 109][index]), color: WelcomePalette.ink.opacity(0.2))
                                line(width: CGFloat([105, 87, 99, 72][index]), color: WelcomePalette.ink.opacity(0.08))
                            }
                        }
                    }
                }.padding(28)
            }.rotationEffect(.degrees(3))
            symbolTile("checkmark", color: peach, size: 62)
                .rotationEffect(.degrees(-10)).offset(x: 142, y: 132)
                .scaleEffect(phase == 2 && !reduceMotion ? 1.06 : 1)
        }
    }

    private var audioRibbon: some View {
        HStack(spacing: 18) {
            echoMark(size: 28)
            HStack(spacing: 4) {
                ForEach(0..<17) { index in
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: 3, height: phase == 0 ? 4 : CGFloat([7, 12, 22, 14, 28, 19, 10, 25, 32, 23, 15, 27, 16, 9, 20, 13, 6][index]))
                }
            }.frame(width: 116, height: 32)
            Image(systemName: phase == 2 ? "checkmark" : "mic.fill").font(.system(size: 14)).foregroundStyle(.white)
        }.padding(.horizontal, 17).frame(height: 58)
            .background(WelcomePalette.control, in: .capsule)
            .shadow(color: WelcomePalette.ink.opacity(0.12), radius: 12, y: 8)
    }
    private var selectedLabel: String? {
        guard let id = answer.choices.first, let index = question.options.firstIndex(of: id) else { return nil }
        return language.questionnaireCopy.options[question.rawValue]?[index]
    }
    private var roleSymbol: String {
        switch answer.choices.first {
        case "developer": "curlybraces"
        case "student", "educator": "graduationcap"
        case "writer", "creator": "pencil.and.outline"
        case "healthcare": "cross.case"
        case "legal": "building.columns"
        case "sales", "marketing", "data_analysis": "chart.bar"
        case "founder", "operations", "product": "square.stack.3d.up"
        case "support", "recruiting", "consultant": "person.2"
        default: "keyboard"
        }
    }
    private func echoMark(size: CGFloat) -> some View {
        Image("EchoLogo").resizable().scaledToFit().frame(width: size, height: size)
    }
    private func symbolTile(_ symbol: String, color: Color, size: CGFloat) -> some View {
        Image(systemName: symbol).font(.system(size: size * 0.38, weight: .regular))
            .foregroundStyle(WelcomePalette.ink.opacity(0.8)).frame(width: size, height: size)
            .background(color, in: .rect(cornerRadius: size * 0.24))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(WelcomePalette.ink.opacity(0.07)))
            .shadow(color: WelcomePalette.ink.opacity(0.05), radius: 6, y: 4)
    }
    private func line(width: CGFloat, color: Color) -> some View {
        Capsule().fill(color).frame(width: width, height: 5)
    }
    private func inkLines(widths: [CGFloat], visible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                line(width: width, color: WelcomePalette.ink.opacity(index == 0 ? 0.3 : 0.13))
                    .scaleEffect(x: visible ? 1 : 0.12, anchor: .leading).opacity(visible ? 1 : 0.3)
            }
        }
    }
    private func paper<Content: View>(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content().frame(width: width, height: height)
            .background(WelcomePalette.canvas, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WelcomePalette.ink.opacity(0.09)))
            .shadow(color: WelcomePalette.ink.opacity(0.08), radius: 16, y: 10)
    }
    private struct Playback: Equatable { let question: ContextQuestion; let reduced: Bool }
    @MainActor private func play() async {
        phase = reduceMotion ? 2 : 0
        guard !reduceMotion else { return }
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(1800))
                withAnimation(.easeInOut(duration: 0.65)) { phase = 1 }
                try await Task.sleep(for: .milliseconds(2200))
                withAnimation(.easeInOut(duration: 0.65)) { phase = 2 }
                try await Task.sleep(for: .milliseconds(4000))
                withAnimation(.easeOut(duration: 0.45)) { phase = 0 }
            }
        } catch { /* The view's task is cancelled on navigation. */ }
    }
}
