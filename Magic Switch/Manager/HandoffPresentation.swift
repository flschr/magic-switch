import Combine
import Foundation

enum HandoffPresentation {
  static func buttonTitle(for state: HandoffState) -> String {
    switch state {
    case .idle: return "Tastatur & Maus auf diesen Mac holen"
    case .checking: return "Prüfe Geräte …"
    case .askingPeerToRelease(let name): return "Löse Geräte von \(name) …"
    case .releasing(let done, let total): return "Löse Geräte … \(done)/\(total)"
    case .connecting(let done, let total): return "Verbinde Geräte … \(done)/\(total)"
    case .askingPeerToConnect(let name): return "Verbinde mit \(name) …"
    case .succeeded: return "Geräte sind übertragen"
    case .failed: return "Erneut versuchen"
    }
  }

  static func message(for state: HandoffState) -> String? {
    switch state {
    case .succeeded(.alreadyHere):
      return "Tastatur und Maus sind bereits auf diesem Mac."
    case .succeeded(.onThisMac):
      return "Tastatur und Maus sind jetzt auf diesem Mac."
    case .succeeded(.onPeer(let name)):
      return "Tastatur und Maus sind jetzt auf \(name)."
    case .failed(let failure):
      return failureMessage(failure)
    default:
      return nil
    }
  }

  private static func failureMessage(_ failure: HandoffFailure) -> String {
    switch failure {
    case .busy: return "Ein anderer Gerätewechsel läuft bereits."
    case .noPeripherals: return "Keine Geräte eingerichtet."
    case .noPeer: return "Kein anderer Mac eingerichtet."
    case .peerUnavailable(let name): return "\(name) ist nicht erreichbar. Die Geräte bleiben hier."
    case .mixedState:
      return "Die Geräte sind auf beide Macs verteilt. Hole sie zuerst auf einen Mac."
    case .localReleaseFailed: return "Nicht alle Geräte konnten getrennt werden."
    case .localReleaseTimedOut: return "Bluetooth hat die Geräte nicht rechtzeitig freigegeben."
    case .peerConnectFailed(let reason, let restored, let total):
      return
        "Der andere Mac übernahm die Geräte nicht (\(reason)). \(restored) von \(total) wurden hier wiederhergestellt."
    case .localConnectFailed(let connected, let total):
      return
        "\(connected) von \(total) Geräten verbunden. Schalte fehlende Geräte kurz aus und wieder ein."
    }
  }
}

@MainActor
final class TakeDevicesViewModel: ObservableObject {
  @Published private(set) var state: HandoffState
  private let coordinator: HandoffCoordinator
  private var stateObserver: AnyCancellable?

  init(coordinator: HandoffCoordinator) {
    self.coordinator = coordinator
    state = coordinator.state
    stateObserver = coordinator.$state.sink { [weak self] state in self?.state = state }
  }

  var title: String { HandoffPresentation.buttonTitle(for: state) }
  var message: String? { HandoffPresentation.message(for: state) }
  var isRunning: Bool { state.isRunning }

  func take() {
    coordinator.takeOnThisMac()
  }
}
