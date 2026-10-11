import Foundation

extension SwitchDirection {
  var handoffDirection: HandoffDirection {
    switch self {
    case .take: return .take
    case .send: return .send
    case .toggle: return .toggle
    }
  }
}

extension NetworkDevice {
  var handoffPeer: HandoffPeer {
    HandoffPeer(id: id, name: name)
  }
}
