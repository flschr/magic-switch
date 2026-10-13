import Foundation
import XCTest

@testable import HandoffCore

@MainActor
final class PairingStoreTests: XCTestCase {
  func testLegacyServiceIsNeverUsedByCurrentKeychain() {
    XCTAssertEqual(SecurityPairingKeychain.service, "org.fischr.magic-switch.pairing-key.v1")
    XCTAssertNotEqual(SecurityPairingKeychain.service, "com.magicswitch.psk-v3")
  }

  func testExistingKeyLoadsAsPaired() {
    let key = Data(repeating: 0x2A, count: 32)
    let store = PairingStore(keychain: PairingKeychainFake(data: key))

    XCTAssertTrue(store.isPaired)
    XCTAssertEqual(store.fingerprint, PairingStore.fingerprint(forKey: key))
    XCTAssertNil(store.storageIssue)
  }

  func testSuccessfulUnpairClearsStateAndDeletesKey() async {
    let keychain = PairingKeychainFake(data: Data(repeating: 0x2A, count: 32))
    let store = PairingStore(keychain: keychain)

    let result = await unpair(store)

    guard case .success = result else {
      return XCTFail("Expected unpair to succeed, got \(result)")
    }
    XCTAssertFalse(store.isPaired)
    XCTAssertNil(store.fingerprint)
    XCTAssertNil(keychain.data)
  }

  func testFailedUnpairPreservesPairedStateAndReportsExactFailure() async {
    let keychain = PairingKeychainFake(data: Data(repeating: 0x2A, count: 32))
    keychain.deleteError = .keychainFailed(KeychainFailureMessage.invalidOwnerStatus)
    let store = PairingStore(keychain: keychain)

    let result = await unpair(store)

    guard case .failure(.keychainFailed(-25244)) = result else {
      return XCTFail("Expected -25244, got \(result)")
    }
    XCTAssertTrue(store.isPaired)
    XCTAssertNotNil(store.fingerprint)
    XCTAssertEqual(store.storageIssue, .keychainFailed(-25244))
  }

  func testPairStoresDerivedKeyAndPublishesPairedState() async {
    let keychain = PairingKeychainFake()
    let store = PairingStore(keychain: keychain)

    let result = await pair(store, code: "0123-4567-89AB")

    guard case .success = result else {
      return XCTFail("Expected pairing to succeed, got \(result)")
    }
    XCTAssertTrue(store.isPaired)
    XCTAssertEqual(keychain.data?.count, 32)
    XCTAssertNotNil(store.fingerprint)
  }

  func testReadFailureIsNotMisrepresentedAsCleanUnpairedState() {
    let keychain = PairingKeychainFake()
    keychain.readError = .keychainFailed(-50)

    let store = PairingStore(keychain: keychain)

    XCTAssertFalse(store.isPaired)
    XCTAssertEqual(store.storageIssue, .keychainFailed(-50))
  }

  func testWriteFailureDoesNotPublishPairedState() async {
    let keychain = PairingKeychainFake()
    keychain.writeError = .keychainFailed(-34018)
    let store = PairingStore(keychain: keychain)

    let result = await pair(store, code: "0123-4567-89AB")

    guard case .failure(.keychainFailed(-34018)) = result else {
      return XCTFail("Expected -34018, got \(result)")
    }
    XCTAssertFalse(store.isPaired)
    XCTAssertNil(store.fingerprint)
    XCTAssertNil(keychain.data)
  }

  private func unpair(_ store: PairingStore) async -> Result<Void, PairingError> {
    await withCheckedContinuation { continuation in
      store.unpair { continuation.resume(returning: $0) }
    }
  }

  private func pair(
    _ store: PairingStore, code: String
  ) async -> Result<Void, PairingError> {
    await withCheckedContinuation { continuation in
      store.pair(withCode: code) { continuation.resume(returning: $0) }
    }
  }
}

private final class PairingKeychainFake: PairingKeyStoring {
  var data: Data?
  var readError: PairingError?
  var writeError: PairingError?
  var deleteError: PairingError?

  init(data: Data? = nil) {
    self.data = data
  }

  func read() throws -> Data? {
    if let readError { throw readError }
    return data
  }

  func write(_ data: Data) throws {
    if let writeError { throw writeError }
    self.data = data
  }

  func delete() throws {
    if let deleteError { throw deleteError }
    data = nil
  }
}
