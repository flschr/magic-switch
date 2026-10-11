import Combine
import Foundation

@MainActor
final class HandoffCoordinator: ObservableObject {
  @Published private(set) var state: HandoffState = .idle

  let bluetooth: BluetoothHandoffServicing
  let peers: PeerHandoffServicing
  let sleeper: HandoffSleeping
  var operationGate = HandoffOperationGate()
  var terminalReset: Task<Void, Never>?

  init(
    bluetooth: BluetoothHandoffServicing,
    peers: PeerHandoffServicing,
    sleeper: HandoffSleeping = SystemHandoffSleeper()
  ) {
    self.bluetooth = bluetooth
    self.peers = peers
    self.sleeper = sleeper
  }

  func perform(_ direction: HandoffDirection, peer: HandoffPeer? = nil) {
    switch direction {
    case .take:
      takeOnThisMac()
    case .send:
      guard let target = peer ?? peers.trustedPeer else {
        failWithoutOperation(.noPeer)
        return
      }
      sendToPeer(target)
    case .toggle:
      toggle(with: peer ?? peers.trustedPeer)
    }
  }

  @discardableResult
  func begin() -> UUID? {
    guard operationGate.activeOperation == nil else { return nil }
    guard !bluetooth.isTransitioning, let operation = operationGate.begin() else {
      showTerminal(.failed(.busy))
      return nil
    }
    guard bluetooth.claimHandoff(operation) else {
      _ = operationGate.finish(operation)
      showTerminal(.failed(.busy))
      return nil
    }
    terminalReset?.cancel()
    state = .checking
    return operation
  }

  func update(_ next: HandoffState, operation: UUID) {
    guard operationGate.contains(operation) else { return }
    state = next
  }

  func finish(_ result: HandoffState, operation: UUID) {
    guard operationGate.finish(operation) else { return }
    bluetooth.finishHandoff(operation)
    showTerminal(result)
  }

  private func showTerminal(_ result: HandoffState) {
    state = result
    terminalReset = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled, self?.operationGate.activeOperation == nil else { return }
      self?.state = .idle
    }
  }

  func failWithoutOperation(_ failure: HandoffFailure) {
    guard operationGate.activeOperation == nil else { return }
    showTerminal(.failed(failure))
  }

  func toggle(with peer: HandoffPeer?) {
    guard let operation = begin() else { return }
    Task { [weak self] in
      guard let self else { return }
      switch await bluetooth.connectionStatus() {
      case .allConnected:
        guard let peer else {
          finish(.failed(.noPeer), operation: operation)
          return
        }
        await runSend(to: peer, operation: operation)
      case .allDisconnected:
        await runTake(operation: operation, onStarted: nil)
      case .partial:
        finish(.failed(.mixedState), operation: operation)
      }
    }
  }
}
