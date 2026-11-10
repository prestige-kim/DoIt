import Foundation
import CryptoKit

enum VerifyError: Error { case invalid }

// 인자는 공개 키·공개 서명·zip 경로뿐이다. 개인 키·키체인을 사용하지 않는다.
do {
    guard CommandLine.arguments.count == 4,
          let key = Data(base64Encoded: CommandLine.arguments[1]), key.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64 else {
        throw VerifyError.invalid
    }
    let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    guard verifier.isValidSignature(signature, for: data) else {
        throw VerifyError.invalid
    }
} catch {
    FileHandle.standardError.write(Data("release-signature-rejected count=1\n".utf8))
    exit(1)
}
