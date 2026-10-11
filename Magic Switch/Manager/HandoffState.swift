import Foundation

struct HandoffPeripheral: Equatable, Identifiable, Sendable {
  let id: String
  let name: String
}

struct HandoffPeer: Equatable, Identifiable, Sendable {
  let id: String
  let name: String
}

enum HandoffDirection: Sendable {
  case take
  case send
  case toggle
}

enum HandoffConnectionStatus: Sendable {
  case allConnected
  case allDisconnected
  case partial
}

enum HandoffPeerResult: Equatable, Sendable {
  case success
  case unreachable
  case failure(String)
}

enum HandoffSuccess: Equatable, Sendable {
  case alreadyHere
  case onThisMac
  case onPeer(String)
}

enum HandoffFailure: Equatable, Sendable {
  case busy
  case noPeripherals
  case noPeer
  case peerUnavailable(String)
  case mixedState
  case localReleaseFailed
  case localReleaseTimedOut
  case peerConnectFailed(String, restored: Int, total: Int)
  case localConnectFailed(connected: Int, total: Int)
}

enum HandoffState: Equatable, Sendable {
  case idle
  case checking
  case askingPeerToRelease(String)
  case releasing(Int, Int)
  case connecting(Int, Int)
  case askingPeerToConnect(String)
  case succeeded(HandoffSuccess)
  case failed(HandoffFailure)

  var isRunning: Bool {
    switch self {
    case .checking, .askingPeerToRelease, .releasing, .connecting, .askingPeerToConnect:
      return true
    case .idle, .succeeded, .failed:
      return false
    }
  }
}
