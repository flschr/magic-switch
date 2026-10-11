import Foundation

extension HandoffCoordinator {
  func takeOnThisMac(onStarted: (() -> Void)? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !bluetoothStore.peripherals.isEmpty,
      !bluetoothStore.isAnyPeripheralTransitioning,
      let operation = begin()
    else { return }

    bluetoothStore.checkActualConnectionStatusAsync { [weak self] status in
      guard let self = self, self.activeOperation == operation else { return }
      if status == .allConnected {
        self.finish(
          .succeeded("Tastatur und Maus sind bereits auf diesem Mac."), operation: operation)
        return
      }
      onStarted?()
      guard PairingStore.shared.isPaired, let peer = self.trustedPeer else {
        self.connectLocally(operation: operation)
        return
      }
      self.update(.askingPeerToRelease(peer.name), operation: operation)
      self.networkStore.executeCommand(.unregisterAll, on: peer) { [weak self] result in
        DispatchQueue.main.async {
          guard let self = self, self.activeOperation == operation else { return }
          switch result {
          case .success, .failure(.connectionFailed), .failure(.connectTimeout):
            self.connectLocally(operation: operation)
          case .failure(let error):
            self.notifyFailure(
              "\(peer.name) konnte die Geräte nicht freigeben: \(error.userMessage)",
              operation: operation)
          }
        }
      }
    }
  }

  func toggle(with peer: NetworkDevice) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard activeOperation == nil, !bluetoothStore.isAnyPeripheralTransitioning else { return }
    bluetoothStore.checkActualConnectionStatusAsync { [weak self] status in
      guard let self = self, self.activeOperation == nil else { return }
      switch status {
      case .allConnected: self.sendToPeer(peer)
      case .allDisconnected: self.takeOnThisMac()
      case .partial:
        NotificationManager.showNotification(
          title: "Mixed device state",
          body: "Bring all devices to one Mac, then try again.",
          identifier: "handoff-mixed-state")
      }
    }
  }

  private func connectLocally(operation: UUID) {
    let peripherals = bluetoothStore.peripherals
    guard !peripherals.isEmpty else {
      finish(.failed("Keine Geräte eingerichtet."), operation: operation)
      return
    }
    update(.connecting(0, peripherals.count), operation: operation)
    let group = DispatchGroup()
    let lock = NSLock()
    var completed = 0
    var successes = 0
    for peripheral in peripherals {
      group.enter()
      bluetoothStore.connectPeripheralFromPeer(peripheral) { [weak self] success in
        lock.lock()
        completed += 1
        if success { successes += 1 }
        let progress = completed
        lock.unlock()
        self?.update(.connecting(progress, peripherals.count), operation: operation)
        group.leave()
      }
      bluetoothStore.armReconnectForTakeover(peripheral.id)
    }
    group.notify(queue: .main) { [weak self] in
      guard let self = self else { return }
      if successes == peripherals.count {
        self.finish(
          .succeeded("Tastatur und Maus sind jetzt auf diesem Mac."), operation: operation)
      } else {
        self.notifyFailure(
          "\(successes) von \(peripherals.count) Geräten verbunden. Schalte fehlende Geräte kurz aus und wieder ein.",
          operation: operation)
      }
    }
  }
}
