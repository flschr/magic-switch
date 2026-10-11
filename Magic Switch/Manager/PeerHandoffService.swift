import Foundation

@MainActor
final class PeerHandoffService: PeerHandoffServicing {
  private let networkStore: NetworkDeviceStore
  private let pairingStore: PairingStore

  init(networkStore: NetworkDeviceStore, pairingStore: PairingStore) {
    self.networkStore = networkStore
    self.pairingStore = pairingStore
  }

  var trustedPeer: HandoffPeer? {
    guard pairingStore.isPaired,
      let peer = networkStore.networkDevices.first(where: { $0.pendingFingerprint == nil })
    else { return nil }
    return HandoffPeer(id: peer.id, name: peer.name)
  }

  func preflight(_ peer: HandoffPeer) async -> HandoffPeerResult {
    await execute(.ping, on: peer)
  }

  func requestReleaseAll(from peer: HandoffPeer) async -> HandoffPeerResult {
    await execute(.unregisterAll, on: peer)
  }

  func requestConnectAll(on peer: HandoffPeer) async -> HandoffPeerResult {
    await execute(.connectAll, on: peer)
  }

  private func execute(_ command: DeviceCommand, on peer: HandoffPeer) async -> HandoffPeerResult {
    guard let device = resolve(peer) else { return .unreachable }
    return await withCheckedContinuation { continuation in
      networkStore.executeCommand(command, on: device) { result in
        switch result {
        case .success:
          continuation.resume(returning: .success)
        case .failure(.connectionFailed), .failure(.connectTimeout):
          continuation.resume(returning: .unreachable)
        case .failure(let error):
          continuation.resume(returning: .failure(error.userMessage))
        }
      }
    }
  }

  private func resolve(_ peer: HandoffPeer) -> NetworkDevice? {
    networkStore.networkDevices.first { $0.id == peer.id && $0.pendingFingerprint == nil }
  }
}
