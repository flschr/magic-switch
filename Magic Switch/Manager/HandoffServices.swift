import Foundation

@MainActor
protocol BluetoothHandoffServicing: AnyObject {
  var peripherals: [HandoffPeripheral] { get }
  var isTransitioning: Bool { get }

  func claimHandoff(_ operation: UUID) -> Bool
  func finishHandoff(_ operation: UUID)
  func connectionStatus() async -> HandoffConnectionStatus
  func beginRelease()
  func release(_ peripheral: HandoffPeripheral) async -> Bool
  func finishRelease(success: Bool)
  func connect(_ peripheral: HandoffPeripheral) async -> Bool
  func armReconnect(for peripheral: HandoffPeripheral)
}

@MainActor
protocol PeerHandoffServicing: AnyObject {
  var trustedPeer: HandoffPeer? { get }

  func preflight(_ peer: HandoffPeer) async -> HandoffPeerResult
  func requestReleaseAll(from peer: HandoffPeer) async -> HandoffPeerResult
  func requestConnectAll(on peer: HandoffPeer) async -> HandoffPeerResult
}

protocol HandoffSleeping: Sendable {
  func sleep(nanoseconds: UInt64) async
}

struct SystemHandoffSleeper: HandoffSleeping {
  func sleep(nanoseconds: UInt64) async {
    try? await Task.sleep(nanoseconds: nanoseconds)
  }
}
