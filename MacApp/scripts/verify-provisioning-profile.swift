// Verify Apple's CMS signature before exposing the signed profile payload.
// Public certificates only; this helper never accesses a private signing key.
import CryptoKit
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Profile verification: " + message + "\n").utf8))
    exit(1)
}
func checked(_ status: OSStatus) {
    guard status == errSecSuccess else { fail("Security operation failed (\(status)).") }
}
guard CommandLine.arguments.count == 2 else { fail("Expected one provisioning-profile path.") }
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else { fail("Invalid profile size.") }
    var decoder: CMSDecoder?
    checked(CMSDecoderCreate(&decoder))
    guard let decoder else { fail("Could not create CMS decoder.") }
    checked(data.withUnsafeBytes { bytes in
        guard let address = bytes.baseAddress else { fail("Missing profile bytes.") }
        return CMSDecoderUpdateMessage(decoder, address, data.count)
    })
    checked(CMSDecoderFinalizeMessage(decoder))
    var signers = 0
    checked(CMSDecoderGetNumSigners(decoder, &signers))
    guard signers == 1 else { fail("Expected exactly one Apple profile signer.") }
    var status = CMSSignerStatus.unsigned
    var trust: SecTrust?
    var certificateStatus: OSStatus = errSecSuccess
    checked(CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false,
                                      &status, &trust, &certificateStatus))
    guard status == .valid, let trust else { fail("Invalid CMS signature.") }
    checked(SecTrustSetNetworkFetchAllowed(trust, false))
    var trustError: CFError?
    guard SecTrustEvaluateWithError(trust, &trustError),
          let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let leaf = chain.first, let anchor = chain.last else {
        fail("The CMS signer is not trusted (\(trustError.map { CFErrorGetCode($0) } ?? 0)).")
    }
    // Public SHA-256 fingerprints independently read from Apple's PKI roots:
    // https://www.apple.com/certificateauthority/ (Apple Inc., G2, G3).
    let appleRoots: Set<String> = [
        "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
        "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
        "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
    ]
    let fingerprint = SHA256.hash(data: SecCertificateCopyData(anchor) as Data)
        .map { String(format: "%02x", $0) }.joined()
    guard appleRoots.contains(fingerprint) else { fail("CMS chain does not end at a supported Apple root.") }
    var name: CFString?
    checked(SecCertificateCopyCommonName(leaf, &name))
    guard let name, ["Mac OS X Provisioning Profile Signing", "Apple iPhone OS Provisioning Profile Signing", "Apple Provisioning Profile Signing"].contains(name as String)
    else { fail("CMS signer is not Apple's provisioning-profile signer.") }
    var content: CFData?
    checked(CMSDecoderCopyContent(decoder, &content))
    guard let content else { fail("Missing signed profile payload.") }
    FileHandle.standardOutput.write(content as Data)
} catch { fail("Could not read the provisioning profile.") }
