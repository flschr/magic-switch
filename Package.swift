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
        "AdvertisingDiagnostics.swift", "BluetoothManager.swift", "DialbackAddresses.swift",
        "DisplayMonitor.swift", "HandoffCoordinator+Send.swift", "HandoffCoordinator+Take.swift",
        "HandoffCoordinator.swift", "HotkeyManager.swift", "IncomingConnection.swift",
        "NotificationManager.swift", "OutgoingConnection.swift", "PairingStore.swift",
        "PeripheralBattery.swift", "RateLimiter.swift", "SecureChannel.swift",
        "ServiceBrowser.swift", "ServicePublisher.swift", "SleepMonitor.swift", "UpdateChecker.swift"
      ],
      sources: ["HandoffState.swift", "HandoffOperationGate.swift"]),
    .testTarget(
      name: "HandoffCoreTests",
      dependencies: ["HandoffCore"],
      path: "Magic SwitchTests")
  ])
