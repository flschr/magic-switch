import CommonCrypto
import CryptoKit
import Foundation
import Security

extension PairingStore {
  static let codeLength = 12
  static let codeAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  private static let pbkdfSalt = "MagicSwitch-PSK-v2"
  private static let pbkdfIterations: UInt32 = 600_000
  private static let pbkdfKeyLength = 32

  static func generateCode() -> String {
    let alphabet = Array(codeAlphabet)
    var bytes = [UInt8](repeating: 0, count: codeLength)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(
      status == errSecSuccess,
      "SecRandomCopyBytes failed with status \(status); refusing to generate a weak pairing code."
    )
    return String(bytes.map { alphabet[Int($0) % alphabet.count] })
  }

  static func formatCode(_ code: String) -> String {
    var rest = Substring(normalize(code))
    var chunks: [String] = []
    while !rest.isEmpty {
      chunks.append(String(rest.prefix(4)))
      rest = rest.dropFirst(4)
    }
    return chunks.joined(separator: "-")
  }

  static func endsAtGroupBoundary(_ code: String) -> Bool {
    let count = normalize(code).count
    return count > 0 && count < codeLength && count % 4 == 0
  }

  static func normalize(_ input: String) -> String {
    let substituted = input.uppercased().map { character -> Character in
      switch character {
      case "I", "L": return "1"
      case "O": return "0"
      case "U": return "V"
      default: return character
      }
    }
    return String(substituted).filter { codeAlphabet.contains($0) }
  }

  static func isValid(_ code: String) -> Bool {
    let normalized = normalize(code)
    return normalized.count == codeLength
      && normalized.allSatisfy { codeAlphabet.contains($0) }
  }

  static func deriveKey(fromCode code: String) throws -> Data {
    guard let codeData = code.data(using: .utf8),
      let saltData = pbkdfSalt.data(using: .utf8)
    else {
      throw PairingError.derivationFailed
    }

    var derived = Data(count: pbkdfKeyLength)
    let status: Int32 = derived.withUnsafeMutableBytes { derivedBytes in
      saltData.withUnsafeBytes { saltBytes in
        codeData.withUnsafeBytes { codeBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            codeBytes.bindMemory(to: Int8.self).baseAddress,
            codeData.count,
            saltBytes.bindMemory(to: UInt8.self).baseAddress,
            saltData.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            pbkdfIterations,
            derivedBytes.bindMemory(to: UInt8.self).baseAddress,
            pbkdfKeyLength
          )
        }
      }
    }
    guard status == kCCSuccess else { throw PairingError.derivationFailed }
    return derived
  }

  static func fingerprint(forKey key: Data) -> String {
    SHA256.hash(data: key).prefix(4).map { String(format: "%02X", $0) }.joined()
  }

  static func fingerprint(forKey key: SymmetricKey) -> String {
    key.withUnsafeBytes { fingerprint(forKey: Data($0)) }
  }
}
