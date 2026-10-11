import Foundation

@MainActor
final class BluetoothHandoffService: BluetoothHandoffServicing {
  private let store: BluetoothPeripheralStore

  init(store: BluetoothPeripheralStore) {
    self.store = store
  }

  var peripherals: [HandoffPeripheral] {
    store.peripherals.map { HandoffPeripheral(id: $0.id, name: $0.name) }
  }

  var isTransitioning: Bool { store.isAnyPeripheralTransitioning }

  func claimHandoff(_ operation: UUID) -> Bool {
    store.claimFullSetHandoff(operation)
  }

  func finishHandoff(_ operation: UUID) {
    store.finishFullSetHandoff(operation)
  }

  func connectionStatus() async -> HandoffConnectionStatus {
    await withCheckedContinuation { continuation in
      store.checkActualConnectionStatusAsync { status in
        switch status {
        case .allConnected: continuation.resume(returning: .allConnected)
        case .allDisconnected: continuation.resume(returning: .allDisconnected)
        case .partial: continuation.resume(returning: .partial)
        }
      }
    }
  }

  func beginRelease() {
    store.beginFullSetRelease()
  }

  func release(_ peripheral: HandoffPeripheral) async -> Bool {
    guard let device = resolve(peripheral) else { return false }
    return await withCheckedContinuation { continuation in
      store.releaseForHandoff(device) { success in
        continuation.resume(returning: success)
      }
    }
  }

  func finishRelease(success: Bool) {
    store.finishFullSetRelease(success: success)
  }

  func connect(_ peripheral: HandoffPeripheral) async -> Bool {
    guard let device = resolve(peripheral) else { return false }
    return await withCheckedContinuation { continuation in
      store.connectPeripheralFromPeer(device) { success in
        continuation.resume(returning: success)
      }
    }
  }

  func armReconnect(for peripheral: HandoffPeripheral) {
    store.armReconnectForTakeover(peripheral.id)
  }

  private func resolve(_ peripheral: HandoffPeripheral) -> BluetoothPeripheral? {
    store.peripherals.first { $0.id == peripheral.id }
  }
}
