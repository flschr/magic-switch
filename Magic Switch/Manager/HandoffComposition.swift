import Foundation

@MainActor
enum HandoffComposition {
  static func makeCoordinator(
    bluetoothStore: BluetoothPeripheralStore = .shared,
    networkStore: NetworkDeviceStore = .shared,
    pairingStore: PairingStore = .shared
  ) -> HandoffCoordinator {
    HandoffCoordinator(
      bluetooth: BluetoothHandoffService(store: bluetoothStore),
      peers: PeerHandoffService(networkStore: networkStore, pairingStore: pairingStore))
  }
}
