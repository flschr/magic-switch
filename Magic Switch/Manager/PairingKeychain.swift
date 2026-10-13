import Foundation
import Security

protocol PairingKeyStoring {
  func read() throws -> Data?
  func write(_ data: Data) throws
  func delete() throws
}

struct SecurityPairingKeychain: PairingKeyStoring {
  // Never fall back to com.magicswitch.psk-v3. That item may be owned by a
  // differently signed app; reading it after unpair would resurrect a key
  // that this app cannot update or delete.
  static let service = "org.fischr.magic-switch.pairing-key.v1"
  static let account = "shared"

  func read() throws -> Data? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw PairingError.keychainFailed(status)
    }
    return data
  }

  func write(_ data: Data) throws {
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw PairingError.keychainFailed(updateStatus)
    }

    var attributes = baseQuery
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    attributes[kSecAttrSynchronizable as String] = false
    attributes[kSecValueData as String] = data
    let addStatus = SecItemAdd(attributes as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw PairingError.keychainFailed(addStatus)
    }
  }

  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PairingError.keychainFailed(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
    ]
  }
}
