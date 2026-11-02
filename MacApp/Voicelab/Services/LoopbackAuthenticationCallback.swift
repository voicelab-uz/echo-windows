import Foundation
import Network
import VoiceLabCore

/// A short-lived HTTP receiver bound only to this Mac's loopback interface.
/// Framework callbacks explicitly hop to MainActor before accessing state.
@MainActor
final class LoopbackAuthenticationCallback {
    private var listener: NWListener?
    private var startup: CheckedContinuation<URL, Error>?
    private var completion: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var attempt: AuthorizationAttempt?
    private var connections: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var acceptingCallback = false

    func start() async throws -> URL {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.stateUpdateHandler = { @Sendable [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { @Sendable [weak self] connection in
                Task { @MainActor in
                    guard let self, self.listener != nil else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            scheduleTimeout(seconds: 10)
            listener.start(queue: .main)
        }
    }

    func wait(
        for attempt: AuthorizationAttempt, openURL: @MainActor (URL) -> Bool
    ) async throws -> URL {
        try Task.checkCancellation()
        guard listener != nil else { throw BrowserAuthenticationError.callbackUnavailable }
        self.attempt = attempt
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            scheduleTimeout(seconds: max(0, attempt.expiresAt.timeIntervalSinceNow))
            if !openURL(attempt.url) { finish(.failure(BrowserAuthenticationError.browserUnavailable)) }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func listenerChanged(_ state: NWListener.State) {
        guard let listener else { return }
        switch state {
        case .ready:
            guard let port = listener.port, port.rawValue >= 1024,
                let url = URL(string: "http://127.0.0.1:\(port.rawValue)/callback")
            else {
                finish(.failure(BrowserAuthenticationError.callbackUnavailable))
                return
            }
            timeout?.cancel()
            let continuation = startup
            startup = nil
            continuation?.resume(returning: url)
        case .failed:
            finish(.failure(BrowserAuthenticationError.callbackUnavailable))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.close(id)
        }
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - buffer.count) {
            @Sendable [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(buffer, connection: connection, id: id)
                } else if error != nil || complete || buffer.count >= 8192 {
                    self.close(id)
                } else {
                    self.receive(connection, id: id, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection, id: UUID) {
        guard !acceptingCallback, let attempt,
            let callback = Self.callbackURL(from: data, redirectURI: attempt.redirectURI),
            (try? attempt.validate(callback: callback)) != nil
        else {
            respond(connection, id: id, status: "400 Bad Request", accepted: nil)
            return
        }
        acceptingCallback = true
        // Receiving a valid callback is the authentication handoff. A browser
        // that stops reading must not hold it until the whole attempt expires.
        deadlines[id]?.cancel()
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.finish(.success(callback))
        }
        respond(connection, id: id, status: "200 OK", accepted: callback)
    }

    /// State/PKCE validation stays in VoiceLabCore and runs before consuming the attempt.
    static func callbackURL(from data: Data, redirectURI: URL) -> URL? {
        guard let request = String(data: data, encoding: .utf8) else { return nil }
        let lines = request.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[0] == "GET",
            ["HTTP/1.0", "HTTP/1.1"].contains(String(requestLine[2])),
            requestLine[1].hasPrefix("/callback?"),
            let port = redirectURI.port
        else { return nil }
        let headers = lines.dropFirst().prefix(while: { !$0.isEmpty })
        let hosts = headers.compactMap { line -> String? in
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].lowercased() == "host" else { return nil }
            return pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard hosts == ["127.0.0.1:\(port)"] else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(requestLine[1])")
    }

    private func respond(_ connection: NWConnection, id: UUID, status: String, accepted: URL?) {
        connection.send(
            content: Self.response(status: status, accepted: accepted != nil),
            completion: .contentProcessed {
                @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.close(id)
                    if let accepted { self.finish(.success(accepted)) }
                }
            })
    }

    /// Only a validated callback may close its own tab. No browser automation or
    /// keyboard shortcuts: those could close a different tab after focus changes.
    static func response(
        status: String, accepted: Bool, localization: AppLocalization = .shared
    ) -> Data {
        let nonce = UUID().uuidString
        let messageKey =
            accepted
            ? "Tasdiqlash qabul qilindi. Echo oynasi avtomatik ochilmoqda. Bu tabni yopishingiz mumkin."
            : "Kirish havolasi yaroqsiz. Echo oynasidan qayta urinib ko‘ring."
        let message = escapeHTML(localization.localizedText(messageKey))
        let closeHint = escapeHTML(localization.localizedText("You can close this tab with Command + W."))
        let language = escapeHTML(localization.language.rawValue)
        let direction = localization.language.isRightToLeft ? "rtl" : "ltr"
        let script =
            accepted
            ? """
            <script nonce="\(nonce)">
            // Remove the one-time code from the visible URL before handing off.
            try { history.replaceState(null, '', '/callback'); } catch (_) {}
            setTimeout(() => {
                window.close();
                // Some browsers disallow closing tabs with a navigation history.
                document.getElementById('fallback').hidden = false;
            }, 250);
            </script>
            """ : ""
        let body = Data(
            """
            <!doctype html><html lang="\(language)" dir="\(direction)"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1"><title>Echo</title>
            <style nonce="\(nonce)">
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
            main { max-width: 400px; padding: 32px; text-align: center; }
            h1 { font-size: 32px; letter-spacing: -1px; }
            p { line-height: 1.6; opacity: .75; }
            </style></head>
            <body><main><h1>Echo</h1><p>\(message)</p>
            <p id="fallback" hidden>\(closeHint)</p>
            </main>\(script)</body></html>
            """.utf8)
        let headers =
            [
                "HTTP/1.1 \(status)", "Content-Type: text/html; charset=utf-8",
                "Content-Length: \(body.count)", "Connection: close", "Cache-Control: no-store",
                "Referrer-Policy: no-referrer",
                "Content-Security-Policy: default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            ].joined(separator: "\r\n") + "\r\n\r\n"
        return Data(headers.utf8) + body
    }

    /// Localized copy is text, never markup or script. Escape ampersands first
    /// so the entities introduced by subsequent replacements remain intact.
    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func scheduleTimeout(seconds: TimeInterval) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.finish(.failure(BrowserAuthenticationError.timedOut))
        }
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { close(id) }
        attempt = nil
        let start = startup
        let end = completion
        startup = nil
        completion = nil
        start?.resume(with: result)
        end?.resume(with: result)
    }
}
