import Combine
import CryptoKit
import Foundation
import Security

enum PairingError: Error, Equatable {
  case invalidCode
  case derivationFailed
  case keychainFailed(OSStatus)

  var userMessage: String {
    switch self {
    case .invalidCode:
      return "Invalid code."
    case .derivationFailed:
      return "Couldn't derive a key from that code."
    case .keychainFailed(let status):
      return KeychainFailureMessage.message(for: status)
    }
  }
}

/// Owns pairing state and serializes all mutations. Keychain persistence and
/// code derivation live in focused collaborators so neither concern can
/// silently change the other's lifecycle semantics.
final class PairingStore: ObservableObject {
  static let shared = PairingStore(keychain: SecurityPairingKeychain())

  @Published private(set) var isPaired = false
  @Published private(set) var fingerprint: String?
  @Published private(set) var installationIssue: ApplicationIntegrityIssue?
  @Published private(set) var storageIssue: PairingError?

  private let keychain: PairingKeyStoring
  private let mutationQueue = DispatchQueue(
    label: "org.fischr.magic-switch.pairing", qos: .userInitiated)

  init(keychain: PairingKeyStoring) {
    self.keychain = keychain
    refreshState()
  }

  func currentKey() -> SymmetricKey? {
    guard let data = try? keychain.read() else { return nil }
    return SymmetricKey(data: data)
  }

  func pair(
    withCode code: String,
    completion: @escaping (Result<Void, PairingError>) -> Void
  ) {
    mutationQueue.async { [weak self] in
      guard let self else { return }
      let normalized = Self.normalize(code)
      guard Self.isValid(normalized) else {
        DispatchQueue.main.async { completion(.failure(.invalidCode)) }
        return
      }

      do {
        let key = try Self.deriveKey(fromCode: normalized)
        try self.keychain.write(key)
        DispatchQueue.main.async {
          self.isPaired = true
          self.fingerprint = Self.fingerprint(forKey: key)
          self.storageIssue = nil
          completion(.success(()))
        }
      } catch let error as PairingError {
        DispatchQueue.main.async { completion(.failure(error)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(.derivationFailed)) }
      }
    }
  }

  func unpair(completion: ((Result<Void, PairingError>) -> Void)? = nil) {
    mutationQueue.async { [weak self] in
      guard let self else { return }
      do {
        try self.keychain.delete()
        DispatchQueue.main.async {
          self.isPaired = false
          self.fingerprint = nil
          self.storageIssue = nil
          completion?(.success(()))
        }
      } catch let error as PairingError {
        DispatchQueue.main.async {
          self.storageIssue = error
          completion?(.failure(error))
        }
      } catch {
        let error = PairingError.keychainFailed(errSecInternalError)
        DispatchQueue.main.async {
          self.storageIssue = error
          completion?(.failure(error))
        }
      }
    }
  }

  func refreshState() {
    installationIssue = ApplicationIntegrity.currentIssue()
    do {
      if let data = try keychain.read() {
        isPaired = true
        fingerprint = Self.fingerprint(forKey: data)
      } else {
        isPaired = false
        fingerprint = nil
      }
      storageIssue = nil
    } catch let error as PairingError {
      isPaired = false
      fingerprint = nil
      storageIssue = error
    } catch {
      isPaired = false
      fingerprint = nil
      storageIssue = .keychainFailed(errSecInternalError)
    }
  }
}
