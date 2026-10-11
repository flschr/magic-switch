import XCTest
@testable import HandoffCore

final class HandoffCoordinatorTests: XCTestCase {
  func testSecondOperationIsRejectedWhileFirstIsActive() {
    var gate = HandoffOperationGate()
    XCTAssertNotNil(gate.begin())
    XCTAssertNil(gate.begin())
  }

  func testStaleCompletionCannotFinishNewerOperation() {
    var gate = HandoffOperationGate()
    let first = gate.begin()!
    XCTAssertTrue(gate.finish(first))
    let second = gate.begin()!
    XCTAssertFalse(gate.finish(first))
    XCTAssertTrue(gate.contains(second))
  }

  func testRunningStatesDisablePrimaryAction() {
    XCTAssertFalse(HandoffState.idle.isRunning)
    XCTAssertTrue(HandoffState.checking.isRunning)
    XCTAssertTrue(HandoffState.connecting(1, 2).isRunning)
    XCTAssertTrue(HandoffState.releasing(1, 2).isRunning)
    XCTAssertFalse(HandoffState.failed("retry").isRunning)
  }

  func testTerminalStateCarriesVisibleDiagnostic() {
    XCTAssertEqual(HandoffState.failed("peer timed out").statusMessage, "peer timed out")
    XCTAssertEqual(HandoffState.succeeded("done").statusMessage, "done")
    XCTAssertNil(HandoffState.checking.statusMessage)
  }

  func testPeerFailureKeepsCurrentConnection() {
    XCTAssertEqual(
      HandoffRecoveryPolicy.action(for: .peerRelease),
      .keepCurrentConnection)
  }

  func testTimeoutAndPeerConnectFailureRollbackLocally() {
    XCTAssertEqual(
      HandoffRecoveryPolicy.action(for: .localReleaseTimeout),
      .reconnectLocally)
    XCTAssertEqual(
      HandoffRecoveryPolicy.action(for: .peerConnect),
      .reconnectLocally)
  }

  func testLocalTakeFailureRequestsPowerCycleRetry() {
    XCTAssertEqual(
      HandoffRecoveryPolicy.action(for: .localConnect),
      .retryAfterPowerCycle)
  }
}
