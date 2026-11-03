import Foundation

@main
struct EchoAuthRetryAfterRegression {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(name: String, header: String?, seconds: TimeInterval)] = [
            ("delta seconds", "120", 120),
            ("zero has minimum backoff", "0", 1),
            ("excessive duration is bounded", "999999", 3_600),
            ("missing header", nil, 30),
            ("empty header", "", 30),
            ("negative is invalid", "-5", 30),
            ("fraction is invalid", "1.5", 30),
            ("nonfinite is invalid", "NaN", 30),
            ("surrounding whitespace", " 45 ", 45),
            ("unrecognized value", "garbage", 30),
            ("HTTP date", "Tue, 14 Nov 2023 22:15:20 GMT", 120),
            ("past date has minimum backoff", "Tue, 14 Nov 2023 22:00:00 GMT", 1),
        ]
        for item in cases {
            let deadline = EchoAuthError.retryDeadline(from: item.header, now: now)
            precondition(deadline.timeIntervalSince(now) == item.seconds,
                         "Retry-After regression: \(item.name)")
        }
        print("PASS: \(cases.count) auth Retry-After regression cases")
    }
}
