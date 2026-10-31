import SwiftUI
import VoiceLabCore

struct QuestionnaireConcept: View {
    @Binding var language: WelcomeLanguage
    let model: QuestionnaireModel
    let onBack: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var copy: QuestionnaireCopy { language.questionnaireCopy }

    var body: some View {
        let question = model.question
        let options = Array(zip(question.options, copy.options[question.rawValue] ?? []))
        GeometryReader { viewport in
            let compact = viewport.size.width < 980
            let paneWidth = viewport.size.width * 0.44
            let inset = max(32, (paneWidth - 360) / 2)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if model.isLoaded {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("\(model.index + 1) / \(ContextQuestion.allCases.count)")
                                        .font(WelcomeType.font(size: 12, weight: .medium)).monospacedDigit()
                                        .foregroundStyle(WelcomePalette.muted)
                                    Text(copy.headings[model.index])
                                        .font(WelcomeType.font(size: compact ? 30 : 34, weight: .semibold))
                                        .tracking(language.usesLatin ? -0.9 : 0)
                                        .accessibilityAddTraits(.isHeader)
                                    Text(question.limit == 1 ? copy.single : copy.multiple)
                                        .font(WelcomeType.font(size: 13))
                                        .foregroundStyle(WelcomePalette.muted)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                QuestionnaireChoiceLayout(spacing: 8, rightToLeft: language.isRightToLeft) {
                                    ForEach(options, id: \.0) { option, label in
                                        choice(option, label: label, question: question)
                                    }
                                }
                                if model.answer.choices.contains("other") {
                                    VStack(alignment: .trailing, spacing: 6) {
                                        TextField(copy.otherPrompt, text: Binding(get: { model.answer.other }, set: model.setOther))
                                            .font(WelcomeType.font(size: 13))
                                            .textFieldStyle(.plain).padding(12)
                                            .background(WelcomePalette.ink.opacity(0.025), in: .rect(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WelcomePalette.ink.opacity(0.18)))
                                            .disabled(!model.editable)
                                            .accessibilityIdentifier("context-other")
                                        Text("\(model.answer.other.unicodeScalars.count) / 280")
                                            .font(WelcomeType.font(size: 10)).monospacedDigit()
                                            .foregroundStyle(model.answer.other.unicodeScalars.count > 280 ? WelcomePalette.coral : WelcomePalette.muted)
                                    }
                                }
                            } else if model.busy {
                                ProgressView().controlSize(.small)
                                Text(copy.loading).font(WelcomeType.font(size: 14)).foregroundStyle(WelcomePalette.muted)
                            }
                            if let failure = model.failure { errorContent(failure) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 28).padding(.bottom, 20)
                        .id(question)
                        .transition(.opacity)
                    }
                    .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
                    footer
                }
                .padding(.top, OnboardingNavigationBar.height)
                .padding(.horizontal, inset)
                .frame(width: paneWidth)
                .background(WelcomePalette.canvas)
                QuestionnaireIllustration(question: question, language: language, answer: model.answer)
                    .padding(.top, OnboardingNavigationBar.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SetupBackdrop())
            }
            .overlay(alignment: .top) {
                OnboardingNavigationBar(language: $language, backIdentifier: "context-back", onBack: onBack)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: model.index)
        .onChange(of: model.index) { old, new in if new > old { OnboardingHaptics.play(.navigation) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-context")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button(language.permissionsCopy.back, action: onBack)
                    .buttonStyle(OnboardingSecondaryButton())
                    .disabled(model.busy || (model.isLoaded && !model.editable))
                    .accessibilityIdentifier("context-back")
                Spacer(minLength: 8)
                Button(copy.skip) { model.save(language: language.rawValue, skip: true) }
                    .buttonStyle(.plain)
                    .font(WelcomeType.font(size: 12, weight: .medium))
                    .foregroundStyle(WelcomePalette.muted)
                    .fixedSize()
                    .disabled(!model.editable)
                    .accessibilityIdentifier("context-skip")
                Button { model.save(language: language.rawValue) } label: {
                    HStack(spacing: 10) {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.busy ? (model.isLoaded ? copy.saving : copy.loading) : TryItCopy.catalog[language.rawValue]!.next)
                    }
                    .font(WelcomeType.font(size: 14, weight: .semibold))
                    .padding(.horizontal, 26).frame(minWidth: 96).frame(height: 40)
                    .contentShape(.rect)
                }
                .buttonStyle(WelcomePrimaryButton())
                .disabled(!model.canAdvance)
                .opacity(model.canAdvance || model.busy ? 1 : 0.45)
                .accessibilityIdentifier("context-next")
            }
            Text(copy.purpose)
                .font(WelcomeType.font(size: 10))
                .foregroundStyle(WelcomePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 28).padding(.top, 16)
    }

    private func errorContent(_ failure: QuestionnaireModel.Failure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(failure == .conflict ? copy.conflict : failure == .loading ? copy.loadError : copy.saveError)
                .font(WelcomeType.font(size: 13)).foregroundStyle(WelcomePalette.coral)
                .fixedSize(horizontal: false, vertical: true)
            Button(failure == .conflict ? copy.reload : copy.retry) {
                if failure == .saving {
                    if model.editable { model.save(language: language.rawValue) } else { model.retry() }
                } else { model.reload() }
            }
            .buttonStyle(.plain).font(WelcomeType.font(size: 13, weight: .semibold))
            .accessibilityIdentifier("context-retry")
        }
    }

    private func choice(_ option: String, label: String, question: ContextQuestion) -> some View {
        // Outgoing choices may render during the next question's transition.
        // Keep their identity and labels bound to the question that created them.
        let selected = model.answers[question.rawValue]?.choices.contains(option) == true
        return Button {
            guard model.question == question else { return }
            let before = model.answer
            model.toggle(option)
            if before != model.answer { OnboardingHaptics.play(.selection) }
        } label: {
            HStack(spacing: 7) {
                QuestionnaireOptionIcon(option: option)
                Text(label)
                    .font(WelcomeType.font(size: 12, weight: .medium))
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: 36)
            .background(selected ? WelcomePalette.lavender : WelcomePalette.canvas, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WelcomePalette.ink.opacity(selected ? 0.65 : 0.16)))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain).disabled(!model.editable || model.question != question)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("context-choice-\(option)")
    }
}
/// Wrap intrinsic-size choices into rows; long translations can use the full width.
private struct QuestionnaireChoiceLayout: Layout {
    let spacing: CGFloat
    let rightToLeft: Bool
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 320, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: rightToLeft ? bounds.maxX - frame.maxX : bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}

extension WelcomeLanguage {
    var questionnaireCopy: QuestionnaireCopy { QuestionnaireCopy.catalog[rawValue]! }
}
struct QuestionnaireCopy: Decodable {
    let stage, single, multiple, otherPrompt, loading, saving, skip, retry, reload, purpose: String
    let loadError, saveError, conflict: String
    let headings: [String]
    let options: [String: [String]]
    static let catalog: [String: QuestionnaireCopy] = {
        guard let url = Bundle.main.url(forResource: "QuestionnaireLanguages", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: QuestionnaireCopy].self, from: data),
              WelcomeLanguage.allCases.allSatisfy({ language in
                  guard let copy = catalog[language.rawValue], copy.headings.count == ContextQuestion.allCases.count else { return false }
                  return ContextQuestion.allCases.allSatisfy { copy.options[$0.rawValue]?.count == $0.options.count }
              }) else { fatalError("Missing questionnaire translations.") }
        return catalog
    }()
}
