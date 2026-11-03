import Foundation
import VoiceLabCore

@MainActor
protocol TryItServing {
    func restore() async throws -> Bool
    func signIn() async throws
    func transcribe(file: URL) async throws -> Transcript
}
