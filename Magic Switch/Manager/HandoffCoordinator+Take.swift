import Foundation

extension HandoffCoordinator {
  func takeOnThisMac(onStarted: (() -> Void)? = nil) {
    guard let operation = begin() else { return }
    Task { [weak self] in
      await self?.runTake(operation: operation, onStarted: onStarted)
    }
  }

  func runTake(operation: UUID, onStarted: (() -> Void)?) async {
    let peripherals = bluetooth.peripherals
    guard !peripherals.isEmpty else {
      finish(.failed(.noPeripherals), operation: operation)
      return
    }
    if await bluetooth.connectionStatus() == .allConnected {
      finish(.succeeded(.alreadyHere), operation: operation)
      return
    }

    onStarted?()
    if let peer = peers.trustedPeer {
      update(.askingPeerToRelease(peer.name), operation: operation)
      // Taking is authoritative: a lost response can mean the peer already
      // released the devices. Always continue locally so they cannot be left
      // on neither Mac. A live peer that still owns them simply wins the
      // Bluetooth race and the local connect reports a clear failure.
      _ = await peers.requestReleaseAll(from: peer)
    }
    await connectLocally(peripherals, operation: operation)
  }

  private func connectLocally(_ peripherals: [HandoffPeripheral], operation: UUID) async {
    var connected = 0
    update(.connecting(connected, peripherals.count), operation: operation)
    for peripheral in peripherals {
      guard operationGate.contains(operation) else { return }
      if await bluetooth.connect(peripheral) { connected += 1 }
      bluetooth.armReconnect(for: peripheral)
      update(.connecting(connected, peripherals.count), operation: operation)
    }

    if connected == peripherals.count {
      finish(.succeeded(.onThisMac), operation: operation)
    } else {
      finish(
        .failed(.localConnectFailed(connected: connected, total: peripherals.count)),
        operation: operation)
    }
  }
}
