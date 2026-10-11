import Foundation

extension HandoffCoordinator {
  func sendToPeer(_ peer: HandoffPeer) {
    guard let operation = begin() else { return }
    Task { [weak self] in await self?.runSend(to: peer, operation: operation) }
  }

  func runSend(to peer: HandoffPeer, operation: UUID) async {
    let peripherals = bluetooth.peripherals
    guard !peripherals.isEmpty else {
      finish(.failed(.noPeripherals), operation: operation)
      return
    }
    guard case .success = await peers.preflight(peer) else {
      finish(.failed(.peerUnavailable(peer.name)), operation: operation)
      return
    }

    bluetooth.beginRelease()
    var released = 0
    update(.releasing(released, peripherals.count), operation: operation)
    for peripheral in peripherals {
      guard operationGate.contains(operation) else { return }
      guard await bluetooth.release(peripheral) else {
        bluetooth.finishRelease(success: false)
        await rollback(
          peripherals, operation: operation, failure: .localReleaseFailed)
        return
      }
      released += 1
      update(.releasing(released, peripherals.count), operation: operation)
    }

    guard await waitForDisconnection(operation: operation) else {
      bluetooth.finishRelease(success: false)
      await rollback(
        peripherals, operation: operation, failure: .localReleaseTimedOut)
      return
    }

    update(.askingPeerToConnect(peer.name), operation: operation)
    switch await peers.requestConnectAll(on: peer) {
    case .success:
      bluetooth.finishRelease(success: true)
      finish(.succeeded(.onPeer(peer.name)), operation: operation)
    case .unreachable:
      await rollbackPeerFailure(peripherals, reason: "Peer unreachable", operation: operation)
    case .failure(let reason):
      await rollbackPeerFailure(peripherals, reason: reason, operation: operation)
    }
  }

  private func waitForDisconnection(operation: UUID) async -> Bool {
    for attempt in 0..<10 {
      guard operationGate.contains(operation) else { return false }
      if await bluetooth.connectionStatus() == .allDisconnected { return true }
      if attempt < 9 { await sleeper.sleep(nanoseconds: 500_000_000) }
    }
    return false
  }

  private func rollbackPeerFailure(
    _ peripherals: [HandoffPeripheral], reason: String, operation: UUID
  ) async {
    let restored = await reconnect(peripherals, operation: operation)
    finish(
      .failed(.peerConnectFailed(reason, restored: restored, total: peripherals.count)),
      operation: operation)
  }

  private func rollback(
    _ peripherals: [HandoffPeripheral], operation: UUID, failure: HandoffFailure
  ) async {
    _ = await reconnect(peripherals, operation: operation)
    finish(.failed(failure), operation: operation)
  }

  private func reconnect(_ peripherals: [HandoffPeripheral], operation: UUID) async -> Int {
    var restored = 0
    for peripheral in peripherals {
      guard operationGate.contains(operation) else { return restored }
      if await bluetooth.connect(peripheral) { restored += 1 }
    }
    return restored
  }
}
