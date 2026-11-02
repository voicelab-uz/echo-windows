import Foundation

private final class ProxyFixture: NSObject {
    var value: AnyObject?
    @objc func documentIdentifier() -> AnyObject? { value }
}

@main
struct KeyboardDocumentIdentityRegression {
    static func main() {
        let proxy = ProxyFixture()
        // UIKit's imported Swift getter traps here because its ObjC contract is
        // nonnull. Exercise the actual production getter with the nil object.
        precondition(KeyboardDocumentIdentity.read(from: proxy) == nil)
        let first = UUID()
        proxy.value = first as NSUUID
        precondition(KeyboardDocumentIdentity.read(from: proxy) == first)
        proxy.value = nil
        precondition(KeyboardDocumentIdentity.read(from: proxy) == nil)
        let next = UUID()
        proxy.value = next as NSUUID
        precondition(KeyboardDocumentIdentity.read(from: proxy) == next)
        precondition(first != next)
        proxy.value = "invalid identity" as NSString
        precondition(KeyboardDocumentIdentity.read(from: proxy) == nil)
        precondition(KeyboardDocumentIdentity.read(from: NSObject()) == nil)
        print("Keyboard document identity nil-bridge regressions passed")
    }
}
