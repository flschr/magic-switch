import Foundation

extension HandoffCoordinator {
  func sendToPeer(_ peer: NetworkDevice) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !bluetoothStore.peripherals.isEmpty,
      !bluetoothStore.isAnyPeripheralTransitioning,
      let operation = begin()
    else { return }

    peer.checkHealth { [weak self] health in
      DispatchQueue.main.async {
        guard let self = self, self.activeOperation == operation else { return }
        guard case .success = health else {
          self.notifyFailure("\(peer.name) ist nicht erreichbar.", operation: operation)
          return
        }
        self.networkStore.executeCommand(.ping, on: peer) { [weak self] preflight in
          DispatchQueue.main.async {
            guard let self = self, self.activeOperation == operation else { return }
            guard case .success = preflight else {
              self.notifyFailure(
                "\(peer.name) antwortet nicht. Die Geräte bleiben hier.", operation: operation)
              return
            }
            self.releaseLocally(to: peer, operation: operation)
          }
        }
      }
    }
  }

  private func releaseLocally(to peer: NetworkDevice, operation: UUID) {
    let peripherals = bluetoothStore.peripherals
    bluetoothStore.beginFullSetRelease()
    update(.releasing(0, peripherals.count), operation: operation)
    let group = DispatchGroup()
    let lock = NSLock()
    var completed = 0
    var allSucceeded = true
    for peripheral in peripherals {
      group.enter()
      bluetoothStore.releaseForHandoff(peripheral) { [weak self] success in
        lock.lock()
        completed += 1
        allSucceeded = allSucceeded && success
        let progress = completed
        lock.unlock()
        self?.update(.releasing(progress, peripherals.count), operation: operation)
        group.leave()
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self = self else { return }
      guard allSucceeded else {
        self.bluetoothStore.finishFullSetRelease(success: false)
        self.rollback(operation: operation, reason: "Nicht alle Geräte konnten getrennt werden.")
        return
      }
      self.waitForLocalDisconnection(peer: peer, operation: operation)
    }
  }

  private func waitForLocalDisconnection(
    peer: NetworkDevice, operation: UUID, attempt: Int = 0
  ) {
    bluetoothStore.checkActualConnectionStatusAsync { [weak self] status in
      guard let self = self, self.activeOperation == operation else { return }
      if status == .allDisconnected {
        self.askPeerToConnect(peer, operation: operation)
      } else if attempt < 9 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          self.waitForLocalDisconnection(peer: peer, operation: operation, attempt: attempt + 1)
        }
      } else {
        self.bluetoothStore.finishFullSetRelease(success: false)
        self.rollback(operation: operation, reason: "Bluetooth hat die Geräte nicht freigegeben.")
      }
    }
  }

  private func askPeerToConnect(_ peer: NetworkDevice, operation: UUID) {
    update(.askingPeerToConnect(peer.name), operation: operation)
    networkStore.executeCommand(.connectAll, on: peer) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self, self.activeOperation == operation else { return }
        switch result {
        case .success:
          self.bluetoothStore.finishFullSetRelease(success: true)
          self.finish(
            .succeeded("Tastatur und Maus sind jetzt auf \(peer.name)."), operation: operation)
        case .failure(let error):
          self.rollback(operation: operation, reason: error.userMessage)
        }
      }
    }
  }

  private func rollback(operation: UUID, reason: String) {
    for peripheral in bluetoothStore.peripherals {
      bluetoothStore.connectPeripheral(peripheral)
    }
    notifyFailure(
      "\(reason) Die Geräte werden wieder mit diesem Mac verbunden.", operation: operation)
  }
}
