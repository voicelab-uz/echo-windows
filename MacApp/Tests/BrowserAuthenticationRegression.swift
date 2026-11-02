import Foundation
import VoiceLabCore

/// Exercises real Network callbacks and cancellation without launching a browser or logging in.
@main
struct BrowserAuthenticationRegression {
    @MainActor
    static func main() async throws {
        try validateHTTPRequests()
        validateCallbackPages()
        try validateLocalizedCallbackPages()
        if CommandLine.arguments.contains("--parser-only") {
            print(
                "PASS: callback HTTP parsing, all 16 localizations and nonce-protected tab-close responses."
            )
            return
        }
        try await completeFromBackgroundThread()
        try await cancelWhileWaiting()
        try await browserOpenFailure()
        try await expiration()
        print(
            "PASS: loopback callback, wrong state, background delivery, cancellation, browser failure and timeout."
        )
    }

    @MainActor
    private static func validateCallbackPages() {
        for accepted in [false, true] {
            let response = LoopbackAuthenticationCallback.response(
                status: accepted ? "200 OK" : "400 Bad Request", accepted: accepted)
            let page = String(decoding: response, as: UTF8.self)
            let parts = page.components(separatedBy: "\r\n\r\n")
            precondition(parts.count == 2)
            let headers = parts[0]
            let body = parts[1]
            precondition(headers.contains("Content-Length: \(body.utf8.count)\r\n"))
            precondition(headers.contains("Cache-Control: no-store"))
            precondition(headers.contains("Referrer-Policy: no-referrer"))
            precondition(!headers.contains("unsafe-inline"))
            let nonce = headers.components(separatedBy: "script-src 'nonce-")[1]
                .components(separatedBy: "'")[0]
            precondition(UUID(uuidString: nonce) != nil)
            precondition(body.contains("window.close()") == accepted)
            precondition(body.contains("<script nonce=\"\(nonce)\">") == accepted)
            precondition(body.contains("history.replaceState(null, '', '/callback')") == accepted)
            precondition(!body.contains("window.open(") && !body.contains("window.opener"))
            precondition(body.contains("<style nonce=\"\(nonce)\">"))
        }
    }

    @MainActor
    private static func validateLocalizedCallbackPages() throws {
        let bundlePath = ProcessInfo.processInfo.environment["ECHO_TEST_LOCALIZATION_BUNDLE"]!
        let bundle = Bundle(path: bundlePath)!
        let suite = "test.echo.browser-localization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = AppLocalization(defaults: defaults, bundle: bundle)
        let successKey = "Tasdiqlash qabul qilindi. Echo oynasi avtomatik ochilmoqda. Bu tabni yopishingiz mumkin."
        let failureKey = "Kirish havolasi yaroqsiz. Echo oynasidan qayta urinib ko‘ring."
        let hintKey = "You can close this tab with Command + W."
        for language in InterfaceLanguage.allCases {
            localization.language = language
            let localizedBundle = Bundle(path: bundle.path(forResource: language.rawValue, ofType: "lproj")!)!
            let microphone = localizedBundle.localizedString(
                forKey: "NSMicrophoneUsageDescription", value: "missing", table: "InfoPlist")
            precondition(microphone != "missing" && microphone.contains("Echo"))
            if language == .en {
                precondition(microphone == "Echo uses your microphone to turn your speech into text.")
            }
            for accepted in [false, true] {
                let page = String(decoding: LoopbackAuthenticationCallback.response(
                    status: accepted ? "200 OK" : "400 Bad Request", accepted: accepted,
                    localization: localization), as: UTF8.self)
                let direction = language.isRightToLeft ? "rtl" : "ltr"
                precondition(page.contains("<html lang=\"\(language.rawValue)\" dir=\"\(direction)\">"))
                // Check the actual compiled catalogs, not a stub translation provider.
                for key in [accepted ? successKey : failureKey, hintKey] {
                    let text = localizedBundle.localizedString(forKey: key, value: "missing", table: nil)
                    precondition(text != "missing")
                    precondition(page.contains(htmlEscaped(text)))
                }
                let parts = page.components(separatedBy: "\r\n\r\n")
                precondition(parts.count == 2)
                precondition(parts[0].contains("Content-Length: \(parts[1].utf8.count)\r\n"))
                precondition(!page.contains("dac_test") && !page.contains("?code="))
                if language == .en {
                    precondition(!page.contains("Tasdiqlash") && !page.contains("Kirish havolasi"))
                }
            }
        }

        // Even a future translation containing markup must stay inert text.
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-callback-escaping-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let resources = fixture.appendingPathComponent("Contents/Resources/en.lproj")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.echo.escape.\(UUID().uuidString)", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: fixture.appendingPathComponent("Contents/Info.plist"))
        let injected = "Safe <script>alert(\"x\")</script> & 'quoted'"
        let strings = Dictionary(uniqueKeysWithValues: [successKey, failureKey, hintKey].map { ($0, injected) })
        try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
            .write(to: resources.appendingPathComponent("Localizable.strings"))
        let unsafeLocalization = AppLocalization(defaults: defaults, bundle: Bundle(url: fixture)!)
        unsafeLocalization.language = .en
        for accepted in [false, true] {
            let page = String(decoding: LoopbackAuthenticationCallback.response(
                status: accepted ? "200 OK" : "400 Bad Request", accepted: accepted,
                localization: unsafeLocalization), as: UTF8.self)
            precondition(page.contains("Safe &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;quoted&#39;"))
            precondition(!page.contains(injected))
            precondition(!page.contains("<script>"))
            precondition(page.contains("window.close()") == accepted)
        }
    }

    private static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    @MainActor
    private static func validateHTTPRequests() throws {
        let redirect = URL(string: "http://127.0.0.1:49152/callback")!
        let valid = "GET /callback?code=dac_test&state=ok HTTP/1.1\r\nHost: 127.0.0.1:49152\r\n\r\n"
        precondition(
            LoopbackAuthenticationCallback.callbackURL(from: Data(valid.utf8), redirectURI: redirect) != nil)
        for invalid in [
            valid.replacingOccurrences(of: "GET ", with: "POST "),
            valid.replacingOccurrences(of: "Host: 127.0.0.1:49152", with: "Host: example.com"),
            valid.replacingOccurrences(of: "/callback?", with: "/other?"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nHost: 127.0.0.1:49152\r\n\r\n"),
        ] {
            precondition(
                LoopbackAuthenticationCallback.callbackURL(from: Data(invalid.utf8), redirectURI: redirect)
                    == nil)
        }
    }

    @MainActor
    private static func completeFromBackgroundThread() async throws {
        let transport = AuthorizationTransport()
        let auth = makeAuthentication(transport)
        var delivery: Task<Void, Error>?
        let browser = BrowserAuthentication { _ in
            let callback = transport.callback
            delivery = Task.detached {
                var wrong = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
                wrong.queryItems = [
                    URLQueryItem(name: "code", value: "dac_test"),
                    URLQueryItem(name: "state", value: "wrong"),
                ]
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                let (_, rejected) = try await session.data(from: wrong.url!)
                precondition((rejected as? HTTPURLResponse)?.statusCode == 400)
                let (body, accepted) = try await session.data(from: callback)
                precondition((accepted as? HTTPURLResponse)?.statusCode == 200)
                precondition(String(decoding: body, as: UTF8.self).contains("window.close()"))
            }
            return true
        }
        let received = try await browser.authenticate(using: auth)
        precondition(received == transport.callback)
        try await delivery!.value
    }

    @MainActor
    private static func cancelWhileWaiting() async throws {
        var opened = false
        let browser = BrowserAuthentication { _ in
            opened = true
            return true
        }
        let auth = makeAuthentication(AuthorizationTransport())
        let task = Task { try await browser.authenticate(using: auth) }
        for _ in 0..<500 {
            if opened { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(opened)
        task.cancel()
        do {
            _ = try await task.value
            preconditionFailure("Canceled login must not succeed")
        } catch is CancellationError {}
    }

    @MainActor
    private static func browserOpenFailure() async throws {
        let browser = BrowserAuthentication { _ in false }
        do {
            _ = try await browser.authenticate(using: makeAuthentication(AuthorizationTransport()))
            preconditionFailure("Failed browser launch must not wait forever")
        } catch BrowserAuthenticationError.browserUnavailable {}
    }

    @MainActor
    private static func expiration() async throws {
        let browser = BrowserAuthentication { _ in true }
        do {
            _ = try await browser.authenticate(
                using: makeAuthentication(AuthorizationTransport(expiration: 1)))
            preconditionFailure("Expired login must not wait forever")
        } catch BrowserAuthenticationError.timedOut {}
    }

    private static func makeAuthentication(_ transport: AuthorizationTransport) -> Authentication {
        Authentication(http: HTTPClient(transport: transport), secrets: EphemeralSecrets())
    }
}

private final class AuthorizationTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var receivedCallback: URL?
    private let expiration: Int
    init(expiration: Int = 30) { self.expiration = expiration }
    var callback: URL { lock.withLock { receivedCallback! } }

    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        let fields = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        let callback = URL(string: "\(fields["redirect_uri"]!)?code=dac_test&state=\(fields["state"]!)")!
        lock.withLock { receivedCallback = callback }
        let response = """
            {"authorization_url":"https://voicelab.uz/app/sign-in?desktop_auth_id=dau_test",
             "authorization_request_id":"dau_test","expires_in":\(expiration)}
            """
        return (
            Data(response.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
        )
    }
}

private final class EphemeralSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func remove(_ key: String) throws { lock.withLock { values[key] = nil } }
}
