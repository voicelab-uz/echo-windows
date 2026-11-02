// Public-key-only verification. No Keychain or private key is used here.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard arguments.count == 4,
      let keyData = Data(base64Encoded: arguments[1]), keyData.count == 32,
      let signature = Data(base64Encoded: arguments[2]), signature.count == 64 else {
    fail("Usage: verify-update-signature PUBLIC_KEY_BASE64 SIGNATURE_BASE64 FILE")
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: data) else { fail("Ed25519 signature verification failed.") }
} catch {
    fail("Could not verify update signature: \(error.localizedDescription)")
}
