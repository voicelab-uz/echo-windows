import Foundation
import Observation
import VoiceLabCore

@MainActor @Observable
final class QuestionnaireModel {
    enum Failure { case loading, saving, conflict, authentication }
    private(set) var index = 0
    private(set) var answers: [String: ContextAnswer] = [:]
    private(set) var isLoaded = false
    private(set) var isFinished = false
    private(set) var busy = false
    private(set) var failure: Failure?
    private(set) var revision = 0
    @ObservationIgnored var canStartWork: () -> Bool = { true }
    @ObservationIgnored private let service: any OnboardingContextServing
    @ObservationIgnored private var pending: ContextSubmission?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    var question: ContextQuestion { ContextQuestion.allCases[index] }
    var answer: ContextAnswer { answers[question.rawValue] ?? ContextAnswer() }
    var editable: Bool { isLoaded && !busy && pending == nil && failure != .conflict && failure != .authentication }
    var canAdvance: Bool {
        editable && !answer.skipped && Self.isValid(answer, for: question)
    }
    private static func isValid(_ answer: ContextAnswer, for question: ContextQuestion) -> Bool {
        let detail = answer.other.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.skipped { return answer.choices.isEmpty && detail.isEmpty }
        return !answer.choices.isEmpty && answer.choices.count <= question.limit
            && answer.choices.allSatisfy(question.options.contains)
            && (!answer.choices.contains("other") || !detail.isEmpty)
            && detail.unicodeScalars.count <= 280 && !detail.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    @ObservationIgnored private let readDraft: () -> QuestionnaireDraft?
    @ObservationIgnored private let writeDraft: (QuestionnaireDraft) -> Void
    @ObservationIgnored private let flushDraft: () async throws -> Void
    init(service: any OnboardingContextServing,
         readDraft: @escaping () -> QuestionnaireDraft? = { nil },
         writeDraft: @escaping (QuestionnaireDraft) -> Void = { _ in },
         flushDraft: @escaping () async throws -> Void = {}) {
        self.service = service; self.readDraft = readDraft; self.writeDraft = writeDraft; self.flushDraft = flushDraft
    }
    private func checkpoint() {
        writeDraft(QuestionnaireDraft(revision: revision, index: index, answers: answers, pending: pending, reviewing: isLoaded && !isFinished))
    }

    func load() {
        guard !busy, !isLoaded else { return }
        run { model, id in
            do {
                let profile = try await model.service.onboardingContext()
                guard model.current(id) else { return }
                model.answers = profile?.answers ?? [:]; model.revision = profile?.revision ?? 0
                model.isLoaded = true; model.isFinished = profile?.completedAt != nil
                model.index = ContextQuestion.allCases.firstIndex { model.answers[$0.rawValue] == nil } ?? 0
                if let draft = model.readDraft() {
                    if let pending = draft.pending {
                        if profile?.revision == pending.expectedRevision + 1 && profile?.answers == pending.answers && (profile?.completedAt != nil) == pending.completed {
                            // The server committed before the previous process could acknowledge it.
                            model.answers = draft.answers
                            model.index = min(draft.index + 1, ContextQuestion.allCases.count - 1)
                        } else {
                            model.answers = draft.answers; model.index = min(max(draft.index, 0), ContextQuestion.allCases.count - 1)
                            model.pending = pending; model.isFinished = false; model.failure = .saving
                        }
                    } else if draft.revision == model.revision && (!model.isFinished || draft.reviewing == true) {
                        model.isFinished = false
                        model.answers = draft.answers; model.index = min(max(draft.index, 0), ContextQuestion.allCases.count - 1)
                    }
                }
                model.busy = false
                model.checkpoint()
            } catch {
                if model.current(id) {
                    model.busy = false
                    model.failure = Self.needsAuthentication(error) ? .authentication : .loading
                }
            }
        }
    }
    func toggle(_ option: String) {
        guard editable, question.options.contains(option) else { return }
        var value = answer; value.skipped = false
        if value.choices.contains(option) { value.choices.removeAll { $0 == option } }
        else if question.limit == 1 || option == "none" { value.choices = [option] }
        else {
            value.choices.removeAll { $0 == "none" }
            guard value.choices.count < question.limit else { return }
            value.choices.append(option)
        }
        value.choices.sort()
        if !value.choices.contains("other") { value.other = "" }
        answers[question.rawValue] = value
        checkpoint()
    }
    func setOther(_ text: String) {
        guard editable else { return }
        var value = answer; value.other = text; answers[question.rawValue] = value; checkpoint()
    }
    func back() { guard editable, index > 0 else { return }; index -= 1; failure = nil; checkpoint() }
    func review() { guard !busy else { return }; isFinished = false; index = ContextQuestion.allCases.count - 1; checkpoint() }
    func save(language: String, skip: Bool = false) {
        guard editable, skip || canAdvance else { return }
        if skip { answers[question.rawValue] = ContextAnswer(skipped: true) }
        else {
            var value = answer; value.other = value.other.trimmingCharacters(in: .whitespacesAndNewlines)
            answers[question.rawValue] = value
        }
        // Back navigation can leave an unfinished later answer in the local draft.
        // Keep that draft, but send only valid answers to the server.
        let submittedAnswers = answers.filter { key, value in
            guard let question = ContextQuestion(rawValue: key) else { return false }
            return Self.isValid(value, for: question)
        }.mapValues { value in
            var value = value
            value.other = value.other.trimmingCharacters(in: .whitespacesAndNewlines)
            return value
        }
        pending = ContextSubmission(revision: revision, answers: submittedAnswers, language: language,
                                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                                    completed: index == ContextQuestion.allCases.count - 1)
        checkpoint()
        retry()
    }
    func retry() {
        guard !busy, let submission = pending else { return }
        run { model, id in
            do {
                try await model.flushDraft()
                guard model.current(id) else { return }
                let profile = try await model.service.saveOnboardingContext(submission)
                guard model.current(id) else { return }
                model.revision = profile.revision; model.pending = nil; model.busy = false
                model.isFinished = submission.completed
                if !model.isFinished { model.index = min(model.index + 1, ContextQuestion.allCases.count - 1) }
                model.checkpoint()
            } catch {
                guard model.current(id) else { return }
                model.busy = false
                if Self.needsAuthentication(error) { model.failure = .authentication }
                else if case VoiceLabError.server(let status, _, _) = error, status == 409 { model.failure = .conflict }
                else {
                    // A validation rejection is definitive: let the user edit before a new attempt.
                    if case VoiceLabError.server(let status, _, _) = error, status == 422 { model.pending = nil; model.checkpoint() }
                    model.failure = .saving
                }
            }
        }
    }
    func reload() { guard !busy else { return }; pending = nil; writeDraft(QuestionnaireDraft(revision: -1, index: 0, answers: [:], pending: nil)); isLoaded = false; load() }
    func cancel() {
        generation = UUID(); operation?.cancel(); busy = false
        if pending != nil { failure = .saving }
    }
    func reset() { cancel(); answers = [:]; revision = 0; pending = nil; isLoaded = false; isFinished = false; failure = nil; index = 0 }
    private static func needsAuthentication(_ error: any Error) -> Bool {
        guard let error = error as? VoiceLabError else { return false }
        switch error {
        case .signedOut, .invalidAccessToken, .sessionChanged: return true
        default: return false
        }
    }
    private func current(_ id: UUID) -> Bool { generation == id && !Task.isCancelled }
    private func run(_ action: @escaping @MainActor (QuestionnaireModel, UUID) async -> Void) {
        guard canStartWork() else { return }
        busy = true; failure = nil; let id = UUID(); generation = id
        operation = Task { [weak self] in guard let self else { return }; await action(self, id) }
    }
}
