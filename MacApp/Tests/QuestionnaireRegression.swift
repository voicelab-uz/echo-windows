import Foundation
import VoiceLabCore

@main struct QuestionnaireRegression {
    @MainActor static func main() async throws {
        let service = ContextService()
        let model = QuestionnaireModel(service: service)
        model.toggle("friend"); model.save(language: "en", skip: true)
        precondition(!model.canAdvance && service.submissions.isEmpty)
        model.load(); model.load()
        try await until { service.loads == 1 }
        service.finishLoad(nil)
        try await until { model.isLoaded }
        model.toggle("other")
        precondition(!model.canAdvance)
        model.setOther(String(repeating: "ʻ", count: 281)); precondition(!model.canAdvance)
        model.setOther("Telegram\nchannel"); precondition(!model.canAdvance)
        model.setOther("  Oʻzbek dasturchilar  "); precondition(model.canAdvance)
        model.save(language: "uz"); model.save(language: "uz")
        try await until { service.submissions.count == 1 }
        precondition(model.index == 0 && model.busy && !model.editable, "Wait for the server before advancing.")
        service.failSave(URLError(.timedOut))
        try await until { model.failure == .saving }
        model.toggle("youtube")
        precondition(model.answer.choices == ["other"] && !model.editable)
        model.retry()
        try await until { service.submissions.count == 2 }
        precondition(service.submissions[0] == service.submissions[1], "An ambiguous timeout must retry the same mutation, not create another revision.")
        precondition(service.submissions[1].answers["discovery"]?.other == "Oʻzbek dasturchilar")
        service.acknowledge()
        try await until { model.index == 1 }
        precondition(model.revision == 1)
        for option in model.question.options { model.toggle(option) }
        precondition(model.answer.choices.count == 5, "Select all applies to every offered option.")
        model.save(language: "en", skip: true)
        try await until { service.submissions.count == 3 }
        precondition(service.submissions.last?.answers["intent"] == ContextAnswer(skipped: true))
        service.acknowledge(); try await until { model.index == 2 }
        model.toggle("developer"); model.toggle("student")
        precondition(model.answer.choices == ["student"], "Single choices replace the previous selection.")
        model.save(language: "en")
        try await until { service.submissions.count == 4 }
        service.failSave(VoiceLabError.server(status: 409, message: "conflict", requestID: nil))
        try await until { model.failure == .conflict }
        precondition(!model.canAdvance && !model.editable)
        let saved = service.profile
        model.reload(); try await until { service.loads == 2 }; service.finishLoad(saved)
        try await until { model.isLoaded && !model.busy }
        precondition(model.question == .work && model.answer.choices.isEmpty, "Reload canonical answers after a conflict.")
        model.save(language: "en", skip: true)
        try await until { service.submissions.count == 5 }; service.acknowledge()
        try await until { model.question == .writing }
        model.save(language: "en", skip: true)
        try await until { service.submissions.count == 6 }; service.acknowledge()
        try await until { model.question == .meetingApps }
        model.toggle("zoom"); model.toggle("teams"); model.toggle("none")
        precondition(model.answer.choices == ["none"])
        model.toggle("google_meet"); precondition(model.answer.choices == ["google_meet"])
        model.save(language: "en")
        try await until { service.submissions.count == 7 }; service.acknowledge()
        try await until { model.question == .meetingProblems }
        model.save(language: "en", skip: true)
        try await until { service.submissions.count == 8 }
        precondition(!model.isFinished && service.submissions.last!.completed)
        service.acknowledge(); try await until { model.isFinished }
        let completed = service.profile!
        precondition(completed.answers.count == 6 && completed.completedAt != nil)
        model.reset(); model.load(); try await until { service.loads == 3 }
        service.finishLoad(completed); try await until { model.isFinished }
        model.review(); precondition(model.index == 5 && !model.isFinished)
        model.back(); precondition(model.index == 4)
        model.reset(); model.load(); try await until { service.loads == 4 }
        model.reset(); service.finishLoad(completed)
        try await Task.sleep(for: .milliseconds(20))
        precondition(!model.isLoaded && !model.isFinished, "Ignore late replies after account reset or window close.")
        model.load(); try await until { service.loads == 5 }
        service.failLoad(); try await until { model.failure == .loading }
        precondition(!model.canAdvance && !model.editable, "An unavailable API must not look like saved or skipped answers.")
        model.reload(); try await until { service.loads == 6 }
        service.loadWaiter?.resume(throwing: VoiceLabError.signedOut); service.loadWaiter = nil
        try await until { model.failure == .authentication }
        precondition(!model.editable, "An expired account must return to Sign In before saving.")
        try await restartJournal()
        print("PASS: authenticated loading, Unicode detail validation, single/multi choices, explicit skips, server-ack navigation, stable retries, conflict reload, draft resume, completion, and stale replies.")
    }
    @MainActor static func restartJournal() async throws {
        var journal: QuestionnaireDraft?
        var diskFails = false
        func make(_ service: ContextService) -> QuestionnaireModel {
            QuestionnaireModel(service: service, readDraft: { journal }, writeDraft: { journal = $0 },
                               flushDraft: { if diskFails { throw VoiceLabError.storage("disk full") } })
        }
        let service = ContextService()
        let first = make(service)
        first.load(); try await until { service.loads == 1 }; service.finishLoad(nil)
        try await until { first.isLoaded }
        first.toggle("other"); first.setOther("Oʻzbek community")
        journal = try JSONDecoder().decode(QuestionnaireDraft.self, from: JSONEncoder().encode(journal!))
        let reopened = make(service)
        reopened.load(); try await until { service.loads == 2 }; service.finishLoad(nil)
        try await until { reopened.isLoaded }
        precondition(reopened.answer.other == "Oʻzbek community", "Unsubmitted edits must survive restart.")
        diskFails = true
        reopened.save(language: "uz")
        try await until { reopened.failure == .saving }
        precondition(service.submissions.isEmpty, "Never send an unjournaled mutation when disk persistence fails.")
        let mutation = journal!.pending!
        journal = try JSONDecoder().decode(QuestionnaireDraft.self, from: JSONEncoder().encode(journal!))
        diskFails = false
        let retry = make(service)
        retry.load(); try await until { service.loads == 3 }; service.finishLoad(nil)
        try await until { retry.failure == .saving }
        retry.retry(); try await until { service.submissions.count == 1 }
        precondition(service.submissions[0] == mutation, "Relaunch must reuse the exact pending body and mutation UUID.")
        service.acknowledge(); try await until { retry.index == 1 }
        precondition(journal?.pending == nil)
        retry.toggle("dictation"); retry.save(language: "en")
        try await until { service.submissions.count == 2 }
        retry.cancel()
        service.acknowledge() // Server committed, but the previous window cannot consume its response.
        let recovered = make(service)
        recovered.load(); try await until { service.loads == 4 }; service.finishLoad(service.profile)
        try await until { recovered.isLoaded }
        precondition(recovered.index == 2 && recovered.revision == 2 && recovered.failure == nil)
        precondition(service.submissions.count == 2, "An acknowledged server snapshot needs no duplicate save.")
        recovered.toggle("other") // Leave a later answer unfinished, then edit an earlier page.
        recovered.back()
        recovered.save(language: "en")
        try await until { service.submissions.count == 3 }
        precondition(service.submissions.last?.answers["work"] == nil, "An unfinished later answer must not invalidate an earlier save.")
        precondition(journal?.answers["work"]?.choices == ["other"], "Keep unfinished input in the encrypted draft.")
        recovered.cancel(); service.acknowledge()
        let afterBack = make(service)
        afterBack.load(); try await until { service.loads == 5 }; service.finishLoad(service.profile)
        try await until { afterBack.isLoaded }
        precondition(afterBack.question == .work && afterBack.answer.choices == ["other"], "Lost-response recovery also preserves unfinished later input.")
        afterBack.setOther("Research")
        afterBack.save(language: "en")
        try await until { service.submissions.count == 4 }
        service.failSave(VoiceLabError.signedOut)
        try await until { afterBack.failure == .authentication }
        let beforeLogin = journal!.pending!
        afterBack.reset() // Production clears the in-memory model while Sign In is shown.
        afterBack.load(); try await until { service.loads == 6 }; service.finishLoad(service.profile)
        try await until { afterBack.failure == .saving }
        afterBack.retry(); try await until { service.submissions.count == 5 }
        precondition(service.submissions.last == beforeLogin, "Reauthentication must preserve and retry the exact pending answer.")
        service.acknowledge(); try await until { afterBack.question == .writing }
        print("PASS: encrypted-journal round trip, unsent edits, disk failure before upload, exact mutation retry after relaunch, and lost-response reconciliation.")
    }
    @MainActor static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        preconditionFailure("Timed out")
    }
}

@MainActor final class ContextService: OnboardingContextServing {
    var loads = 0
    var submissions: [ContextSubmission] = []
    var profile: OnboardingContext?
    var loadWaiter: CheckedContinuation<OnboardingContext?, any Error>?
    var saveWaiter: CheckedContinuation<OnboardingContext, any Error>?
    func onboardingContext() async throws -> OnboardingContext? {
        loads += 1
        return try await withCheckedThrowingContinuation { loadWaiter = $0 }
    }
    func saveOnboardingContext(_ submission: ContextSubmission) async throws -> OnboardingContext {
        submissions.append(submission)
        return try await withCheckedThrowingContinuation { saveWaiter = $0 }
    }
    func finishLoad(_ value: OnboardingContext?) { loadWaiter?.resume(returning: value); loadWaiter = nil }
    func failLoad() { loadWaiter?.resume(throwing: URLError(.notConnectedToInternet)); loadWaiter = nil }
    func failSave(_ error: any Error) { saveWaiter?.resume(throwing: error); saveWaiter = nil }
    func acknowledge() {
        let input = submissions.last!
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        var object = try! JSONSerialization.jsonObject(with: encoder.encode(input)) as! [String: Any]
        object["user_id"] = "account-a"; object["revision"] = input.expectedRevision + 1
        object["created_at"] = "2026-10-21T00:00:00Z"; object["updated_at"] = "2026-10-21T00:00:00Z"
        if input.completed { object["completed_at"] = "2026-10-21T00:00:00Z" }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        profile = try! decoder.decode(OnboardingContext.self, from: JSONSerialization.data(withJSONObject: object))
        saveWaiter?.resume(returning: profile!); saveWaiter = nil
    }
}
