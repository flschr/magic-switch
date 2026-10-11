import Foundation

@testable import HandoffCore

struct ImmediateSleeper: HandoffSleeping {
  func sleep(nanoseconds: UInt64) async { await Task.yield() }
}

@MainActor
final class BluetoothFake: BluetoothHandoffServicing {
  let peripherals: [HandoffPeripheral]
  var isTransitioning = false
  var statuses: [HandoffConnectionStatus]
  var connectResults: [Bool]
  var releaseCalls: [String] = []
  var connectCalls: [String] = []
  var finishReleaseValues: [Bool] = []
  var claimedOperation: UUID?

  init(
    peripherals: [HandoffPeripheral], statuses: [HandoffConnectionStatus],
    connectResults: [Bool] = []
  ) {
    self.peripherals = peripherals
    self.statuses = statuses
    self.connectResults = connectResults
  }

  func connectionStatus() async -> HandoffConnectionStatus {
    statuses.isEmpty ? .allDisconnected : statuses.removeFirst()
  }

  func claimHandoff(_ operation: UUID) -> Bool {
    guard claimedOperation == nil else { return false }
    claimedOperation = operation
    return true
  }

  func finishHandoff(_ operation: UUID) {
    if claimedOperation == operation { claimedOperation = nil }
  }

  func beginRelease() {}

  func release(_ peripheral: HandoffPeripheral) async -> Bool {
    releaseCalls.append(peripheral.id)
    return true
  }

  func finishRelease(success: Bool) { finishReleaseValues.append(success) }

  func connect(_ peripheral: HandoffPeripheral) async -> Bool {
    connectCalls.append(peripheral.id)
    return connectResults.isEmpty ? true : connectResults.removeFirst()
  }

  func armReconnect(for peripheral: HandoffPeripheral) {}
}

@MainActor
final class PeerFake: PeerHandoffServicing {
  let trustedPeer: HandoffPeer?
  var preflightResult: HandoffPeerResult = .success
  var releaseResult: HandoffPeerResult
  var connectResult: HandoffPeerResult
  var releaseCalls = 0
  var preflightCalls = 0
  var connectCalls = 0

  init(
    peer: HandoffPeer?, releaseResult: HandoffPeerResult = .success,
    connectResult: HandoffPeerResult = .success
  ) {
    trustedPeer = peer
    self.releaseResult = releaseResult
    self.connectResult = connectResult
  }

  func preflight(_ peer: HandoffPeer) async -> HandoffPeerResult {
    preflightCalls += 1
    return preflightResult
  }

  func requestReleaseAll(from peer: HandoffPeer) async -> HandoffPeerResult {
    releaseCalls += 1
    return releaseResult
  }

  func requestConnectAll(on peer: HandoffPeer) async -> HandoffPeerResult {
    connectCalls += 1
    return connectResult
  }
}
