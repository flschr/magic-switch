import Foundation

enum HandoffState: Equatable {
  case idle
  case checking
  case askingPeerToRelease(String)
  case releasing(Int, Int)
  case connecting(Int, Int)
  case askingPeerToConnect(String)
  case succeeded(String)
  case failed(String)

  var isRunning: Bool {
    switch self {
    case .checking, .askingPeerToRelease, .releasing, .connecting, .askingPeerToConnect:
      return true
    case .idle, .succeeded, .failed:
      return false
    }
  }

  var buttonTitle: String {
    switch self {
    case .idle: return "Tastatur & Maus auf diesen Mac holen"
    case .checking: return "Prüfe Geräte …"
    case .askingPeerToRelease(let name): return "Löse Geräte von \(name) …"
    case .releasing(let done, let total): return "Löse Geräte … \(done)/\(total)"
    case .connecting(let done, let total): return "Verbinde Geräte … \(done)/\(total)"
    case .askingPeerToConnect(let name): return "Verbinde mit \(name) …"
    case .succeeded: return "Geräte sind auf diesem Mac"
    case .failed: return "Erneut versuchen"
    }
  }

  var statusMessage: String? {
    switch self {
    case .succeeded(let message), .failed(let message): return message
    default: return nil
    }
  }
}
