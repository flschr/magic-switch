// swift-tools-version: 5.7
import PackageDescription

let package = Package(
  name: "MagicSwitchHandoffCore",
  platforms: [.macOS(.v12)],
  products: [.library(name: "HandoffCore", targets: ["HandoffCore"])],
  targets: [
    .target(
      name: "HandoffCore",
      path: "Magic Switch/Manager",
      exclude: [
        "AdvertisingDiagnostics.swift", "BluetoothHandoffService.swift", "BluetoothManager.swift",
        "DialbackAddresses.swift", "DisplayMonitor.swift", "HandoffComposition.swift",
        "HandoffPresentation.swift", "HotkeyManager.swift", "IncomingConnection.swift",
        "NotificationManager.swift", "OutgoingConnection.swift",
        "PeerHandoffService.swift", "PeripheralBattery.swift", "RateLimiter.swift", "SecureChannel.swift",
        "ServiceBrowser.swift", "ServicePublisher.swift", "SleepMonitor.swift", "UpdateChecker.swift"
      ],
      sources: [
        "ApplicationIntegrity.swift", "PairingCode.swift", "PairingKeychain.swift", "PairingStore.swift",
        "HandoffState.swift", "HandoffOperationGate.swift", "HandoffServices.swift",
        "HandoffCoordinator.swift", "HandoffCoordinator+Take.swift", "HandoffCoordinator+Send.swift"
      ]),
    .testTarget(
      name: "HandoffCoreTests",
      dependencies: ["HandoffCore"],
      path: "Magic SwitchTests")
  ])
