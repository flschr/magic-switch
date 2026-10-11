import Combine
import Foundation

/// The single owner of a full-set handoff. UI and automation entry points only
/// express intent here; they never sequence Bluetooth and peer operations.
final class HandoffCoordinator: ObservableObject {
  static let shared = HandoffCoordinator()

  @Published private(set) var state: HandoffState = .idle

  let bluetoothStore: BluetoothPeripheralStore
  let networkStore: NetworkDeviceStore
  var operationGate = HandoffOperationGate()
  var activeOperation: UUID? { operationGate.activeOperation }
  var terminalReset: DispatchWorkItem?

  init(
    bluetoothStore: BluetoothPeripheralStore = .shared,
    networkStore: NetworkDeviceStore = .shared
  ) {
    self.bluetoothStore = bluetoothStore
    self.networkStore = networkStore
  }

  @discardableResult
  func begin(_ next: HandoffState = .checking) -> UUID? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let id = operationGate.begin() else { return nil }
    terminalReset?.cancel()
    state = next
    return id
  }

  func update(_ next: HandoffState, operation: UUID) {
    DispatchQueue.main.async { [weak self] in
      guard self?.operationGate.contains(operation) == true else { return }
      self?.state = next
    }
  }

  func finish(_ result: HandoffState, operation: UUID) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.operationGate.finish(operation) else { return }
      self.state = result
      let item = DispatchWorkItem { [weak self] in
        guard self?.activeOperation == nil, self?.state == result else { return }
        self?.state = .idle
      }
      self.terminalReset = item
      DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }
  }

  func notifyFailure(_ message: String, operation: UUID) {
    finish(.failed(message), operation: operation)
    NotificationManager.showNotification(
      title: "Switch Failed", body: message, identifier: "handoff-failed")
  }

  func perform(_ direction: SwitchDirection, peer: NetworkDevice? = nil) {
    switch direction {
    case .take: takeOnThisMac()
    case .send:
      guard let target = peer ?? trustedPeer else { return }
      sendToPeer(target)
    case .toggle:
      guard let target = peer ?? trustedPeer else {
        takeOnThisMac()
        return
      }
      toggle(with: target)
    }
  }

  var trustedPeer: NetworkDevice? {
    networkStore.networkDevices.first { $0.pendingFingerprint == nil }
  }
}
