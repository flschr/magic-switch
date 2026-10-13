import XCTest

@testable import HandoffCore

final class ApplicationIntegrityTests: XCTestCase {
  func testInvalidBundleMessageExplainsSafeTransfer() {
    let message = KeychainFailureMessage.message(for: -67028)

    XCTAssertTrue(message.contains("changed after signing"))
    XCTAssertTrue(message.contains("ZIP or DMG"))
    XCTAssertTrue(message.contains("never the .app"))
  }

  func testMissingEntitlementMessageExplainsSigningFailure() {
    let message = KeychainFailureMessage.message(for: -34018)

    XCTAssertTrue(message.contains("signing permissions"))
    XCTAssertTrue(message.contains("Reinstall"))
  }

  func testUnknownStatusRemainsActionable() {
    let message = KeychainFailureMessage.message(for: -1)

    XCTAssertTrue(message.contains("error -1"))
    XCTAssertTrue(message.contains("Applications"))
  }
}
