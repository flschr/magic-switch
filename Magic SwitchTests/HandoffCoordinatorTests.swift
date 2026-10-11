import XCTest

@testable import HandoffCore

@MainActor
final class HandoffCoordinatorTests: XCTestCase {
  private let keyboard = HandoffPeripheral(id: "keyboard", name: "Keyboard")
  private let mouse = HandoffPeripheral(id: "mouse", name: "Mouse")
  private let peer = HandoffPeer(id: "peer", name: "Other Mac")

  func testDoubleTakeStartsOnlyOneTransaction() async {
    let bluetooth = BluetoothFake(peripherals: [keyboard, mouse], statuses: [.allDisconnected])
    let peers = PeerFake(peer: peer, releaseResult: .success)
    let coordinator = makeCoordinator(bluetooth: bluetooth, peers: peers)

    coordinator.takeOnThisMac()
    coordinator.takeOnThisMac()
    await waitForTerminal(coordinator)

    XCTAssertEqual(peers.releaseCalls, 1)
    XCTAssertEqual(bluetooth.connectCalls, [keyboard.id, mouse.id])
    XCTAssertEqual(coordinator.state, .succeeded(.onThisMac))
  }

  func testLostPeerReleaseAcknowledgementStillTakesLocally() async {
    let bluetooth = BluetoothFake(peripherals: [keyboard], statuses: [.allDisconnected])
    let peers = PeerFake(peer: peer, releaseResult: .failure("denied"))
    let coordinator = makeCoordinator(bluetooth: bluetooth, peers: peers)

    coordinator.takeOnThisMac()
    await waitForTerminal(coordinator)

    XCTAssertEqual(bluetooth.connectCalls, [keyboard.id])
    XCTAssertEqual(bluetooth.releaseCalls, [])
    XCTAssertEqual(coordinator.state, .succeeded(.onThisMac))
  }

  func testUnreachablePeerStillAttemptsSafeLocalTake() async {
    let bluetooth = BluetoothFake(peripherals: [keyboard], statuses: [.allDisconnected])
    let peers = PeerFake(peer: peer, releaseResult: .unreachable)
    let coordinator = makeCoordinator(bluetooth: bluetooth, peers: peers)

    coordinator.takeOnThisMac()
    await waitForTerminal(coordinator)

    XCTAssertEqual(bluetooth.connectCalls, [keyboard.id])
    XCTAssertEqual(coordinator.state, .succeeded(.onThisMac))
  }

  func testPeerConnectFailureWaitsForRollback() async {
    let bluetooth = BluetoothFake(
      peripherals: [keyboard, mouse], statuses: [.allDisconnected], connectResults: [true, true])
    let peers = PeerFake(peer: peer, connectResult: .failure("pair failed"))
    let coordinator = makeCoordinator(bluetooth: bluetooth, peers: peers)

    coordinator.sendToPeer(peer)
    await waitForTerminal(coordinator)

    XCTAssertEqual(bluetooth.releaseCalls, [keyboard.id, mouse.id])
    XCTAssertEqual(bluetooth.connectCalls, [keyboard.id, mouse.id])
    XCTAssertEqual(
      coordinator.state,
      .failed(.peerConnectFailed("pair failed", restored: 2, total: 2)))
  }

  func testReleaseTimeoutRollsBackLocally() async {
    let bluetooth = BluetoothFake(
      peripherals: [keyboard], statuses: Array(repeating: .allConnected, count: 10))
    let peers = PeerFake(peer: peer)
    let coordinator = makeCoordinator(bluetooth: bluetooth, peers: peers)

    coordinator.sendToPeer(peer)
    await waitForTerminal(coordinator)

    XCTAssertEqual(bluetooth.connectCalls, [keyboard.id])
    XCTAssertEqual(bluetooth.finishReleaseValues, [false])
    XCTAssertEqual(coordinator.state, .failed(.localReleaseTimedOut))
  }

  func testMixedToggleFailsWithoutMutation() async {
    let bluetooth = BluetoothFake(peripherals: [keyboard], statuses: [.partial])
    let peers = PeerFake(peer: peer)
    let coordinator = makeCoordinator(bluetooth: bluetooth, peers: peers)

    coordinator.toggle(with: peer)
    await waitForTerminal(coordinator)

    XCTAssertTrue(bluetooth.releaseCalls.isEmpty)
    XCTAssertTrue(bluetooth.connectCalls.isEmpty)
    XCTAssertEqual(coordinator.state, .failed(.mixedState))
  }

  func testExistingBluetoothTransitionReturnsBusyFeedback() {
    let bluetooth = BluetoothFake(peripherals: [keyboard], statuses: [.allDisconnected])
    bluetooth.isTransitioning = true
    let coordinator = makeCoordinator(bluetooth: bluetooth, peers: PeerFake(peer: peer))

    coordinator.takeOnThisMac()

    XCTAssertEqual(coordinator.state, .failed(.busy))
    XCTAssertTrue(bluetooth.connectCalls.isEmpty)
  }

  func testSendUsesOnePreflightAndCompletesOnPeer() async {
    let bluetooth = BluetoothFake(
      peripherals: [keyboard, mouse], statuses: [.allDisconnected])
    let peers = PeerFake(peer: peer)
    let coordinator = makeCoordinator(bluetooth: bluetooth, peers: peers)

    coordinator.sendToPeer(peer)
    await waitForTerminal(coordinator)

    XCTAssertEqual(peers.preflightCalls, 1)
    XCTAssertEqual(peers.connectCalls, 1)
    XCTAssertEqual(bluetooth.finishReleaseValues, [true])
    XCTAssertNil(bluetooth.claimedOperation)
    XCTAssertEqual(coordinator.state, .succeeded(.onPeer(peer.name)))
  }

  private func makeCoordinator(
    bluetooth: BluetoothFake, peers: PeerFake
  ) -> HandoffCoordinator {
    HandoffCoordinator(bluetooth: bluetooth, peers: peers, sleeper: ImmediateSleeper())
  }

  private func waitForTerminal(_ coordinator: HandoffCoordinator) async {
    for _ in 0..<100 where coordinator.state.isRunning || coordinator.state == .idle {
      await Task.yield()
    }
  }
}
