import Cocoa
import Combine
import CoreBluetooth
import SwiftUI
import UserNotifications

/// Application delegate handling lifecycle and UI setup
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
  @preconcurrency UNUserNotificationCenterDelegate
{
  // MARK: - Dependencies

  private let networkStore = NetworkDeviceStore.shared
  private let bluetoothStore = BluetoothPeripheralStore.shared
  private lazy var handoffCoordinator = HandoffComposition.makeCoordinator(
    bluetoothStore: bluetoothStore, networkStore: networkStore)
  private lazy var takeViewModel = TakeDevicesViewModel(coordinator: handoffCoordinator)
  private var handoffObserver: AnyCancellable?
  /// Fires the automatic full-set take when a display the user marked as a
  /// switch trigger (Settings → Other) connects to this Mac.
  private let displayMonitor = DisplayMonitor.shared

  // MARK: - UI Components

  private var statusItem: NSStatusItem!
  /// The AppKit view hosted by the dropdown menu's single item. Kept so it can
  /// be re-measured each time the menu opens.
  private var dropdownContentView: DropdownContentView?
  private var bluetoothStateObserver: AnyCancellable?
  private var pairingObserver: AnyCancellable?
  private var peripheralsObserver: AnyCancellable?
  private var windowCloseObserver: NSObjectProtocol?
  private var lastBluetoothState: CBManagerState = .unknown
  private var sleepObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?
  /// True between `willSleepNotification` and `didWakeNotification`. Dark
  /// wakes never post `didWake`, so this stays set across overnight
  /// maintenance wakes.
  private var isSystemSleeping = false
  /// Radio state captured at `willSleep`, gating the wake recheck.
  private var bluetoothWasOnBeforeSleep = false
  private var wakeBluetoothRecheck: DispatchWorkItem?
  private static let bluetoothOffNotificationID = "bluetooth-off"
  /// How long after a real wake to wait before deciding Bluetooth is
  /// genuinely off — the radio takes a moment to power back up.
  private static let bluetoothWakeGrace: TimeInterval = 3
  /// Cached Settings window controller. We host `SettingsView` in a manual
  /// `NSWindow` rather than going through SwiftUI's `Settings` scene because
  /// the scene's `showSettingsWindow:` action silently fails to produce a
  /// visible window in this app (LSUIElement + `.accessory`).
  private var settingsWindowController: NSWindowController?
  /// Set true by `quitFromStatusBar(_:)` immediately before invoking
  /// `terminate(_:)`. `applicationShouldTerminate(_:)` checks this to
  /// distinguish "user picked Quit from our menu-bar menu" (real exit)
  /// from "user pressed Cmd+Q with Settings focused or chose Quit from
  /// the Dock" (just close the window, keep running).
  private var quitFromStatusBarMenu = false
  /// Token for the `.magicSwitchReceivedPing` observer registered in
  /// `setupPingFlashObserver`.
  private var pingObserver: NSObjectProtocol?
  /// Resets the status-bar icon back to its real state after a Ping flash.
  private var pingFlashTimer: DispatchSourceTimer?
  /// Observers for inbound full-set peripheral-handoff posts from
  /// `IncomingConnection`.
  private var transferReceiveObserver: NSObjectProtocol?
  private var transferReleaseObserver: NSObjectProtocol?
  /// Same, for single-peripheral switches — posted both by the local
  /// per-peripheral senders and by the incoming `.connectOne` /
  /// `.unregisterOne` handlers.
  private var transferIncomingOneObserver: NSObjectProtocol?
  private var transferOutgoingOneObserver: NSObjectProtocol?
  /// Direction the status-bar icon should currently advertise. `idle` falls
  /// through to the normal/needs-attention logic in `refreshStatusBarIcon`.
  private enum TransferState {
    case idle
    case sending  // peripherals are leaving this Mac
    case receiving  // peripherals are arriving at this Mac
  }
  private var transferState: TransferState = .idle
  /// When the current transfer state was latched by `beginTransferHold`.
  /// Non-nil only for held transfers — the ones that end by observing the
  /// store's per-peripheral transitions rather than by an explicit
  /// `endTransfer()` from the operation's own completion.
  private var transferLatchedAt: Date?
  /// Re-checks a held transfer for settlement (see `maybeEndHeldTransfer`).
  private var transferAutoEndTimer: DispatchSourceTimer?
  /// Ends a held transfer via `maybeEndHeldTransfer` when the store's
  /// per-peripheral states change.
  private var transferSettleObserver: AnyCancellable?
  /// How long a held transfer keeps its icon with nothing transitioning
  /// yet: covers the gap between the latching notification and the first
  /// `connecting`/`releasing` flip (a network round trip at most), and
  /// doubles as the floor so a no-op transfer still flashes feedback.
  /// Matches the previous fixed-window revert, so the degenerate case
  /// where nothing ever transitions behaves exactly as before.
  private static let transferSettleGrace: TimeInterval = 5
  /// Backstop for a held transfer whose rows never settle — a `.releasing`
  /// row has no watchdog of its own, unlike `.connecting`'s 60s pair
  /// watchdog. Sized to outlast that pair watchdog with slack.
  private static let transferHardCap: TimeInterval = 90

  // MARK: - Lifecycle Methods

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupNotifications()
    setupBluetooth()
    setupSleepWakeTracking()
    setupStatusBar()
    setupActivationPolicyTracking()
    setupPingFlashObserver()
    setupTransferObservers()
    setupHandoffNotifications()
    setupDisplayTrigger()
    setupHotkey()
    // Best-effort, silent, throttled to once per 24h. Drives the "Update
    // Available" affordances in the right-click menu and Settings → Other.
    UpdateChecker.shared.checkIfNeeded()
  }

  /// Fires when the user clicks the Dock icon. If a window is already
  /// visible AppKit will bring it forward (return true). If not, the Dock
  /// icon only exists because Settings was open recently — reopen it,
  /// since that's the only useful action there is for this menu-bar app.
  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      openSettingsWindow(sender)
      return false
    }
    return true
  }

  /// Decide whether a `terminate(_:)` request should actually exit.
  ///
  /// - Status-bar menu → Quit: real exit (the flag is set in `quitFromStatusBar`).
  /// - System-initiated (logout / shutdown / restart): real exit.
  /// - Anything else (Cmd+Q while Settings focused, right-click Dock → Quit,
  ///   etc.): cancel the terminate, just close Settings and drop the Dock
  ///   icon. This is the "Magic Switch lives in the menu bar; the Dock entry
  ///   is only there while Settings is open" mental model the user wants.
  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    if quitFromStatusBarMenu { return .terminateNow }
    if Self.isSystemInitiatedQuit() { return .terminateNow }
    // Close any visible normal-level windows (the Settings window is the
    // only one this app ever has). The willClose observer in
    // `setupActivationPolicyTracking` will demote the activation policy
    // back to `.accessory` shortly after; setting it here too just makes
    // the Dock-icon disappearance feel immediate.
    for window in NSApp.windows where window.isVisible && window.level == .normal {
      window.close()
    }
    NSApp.setActivationPolicy(.accessory)
    return .terminateCancel
  }

  /// True when the current AppleEvent reason is logout / shutdown / restart.
  /// Without this check we'd block the system from quitting us during
  /// shutdown, which can hang the logout flow.
  private static func isSystemInitiatedQuit() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?
        .enumCodeValue
    else { return false }
    return reason == kAELogOut
      || reason == kAEReallyLogOut
      || reason == kAEShowRestartDialog
      || reason == kAEShowShutdownDialog
      || reason == kAERestart
      || reason == kAEShutDown
  }

  /// Status-bar menu's Quit handler. Sets the "real quit" flag so
  /// `applicationShouldTerminate` lets us exit.
  @objc func quitFromStatusBar(_ sender: Any?) {
    quitFromStatusBarMenu = true
    NSApp.terminate(sender)
  }

  deinit {
    if let token = windowCloseObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = pingObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = transferReceiveObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = transferReleaseObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = transferIncomingOneObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = transferOutgoingOneObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = sleepObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
    if let token = wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
  }

  // MARK: - Setup Methods

  private func setupNotifications() {
    // macOS only routes notification clicks — including one that relaunches
    // the app — to a delegate installed before launch finishes.
    UNUserNotificationCenter.current().delegate = self
    NotificationManager.requestAuthorizationIfNeeded()
  }

  private func setupBluetooth() {
    bluetoothStateObserver = BluetoothManager.shared.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        self?.handleBluetoothStateChange(state)
        self?.refreshStatusBarIcon()
      }
    pairingObserver = PairingStore.shared.$isPaired
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshStatusBarIcon()
      }
    peripheralsObserver = bluetoothStore.$peripherals
      .combineLatest(bluetoothStore.$connectionStates) {
        BluetoothPeripheralStore.presence(of: $0, connectionStates: $1)
      }
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshStatusBarIcon()
      }
    BluetoothManager.shared.setup()
  }

  private func handleBluetoothStateChange(_ state: CBManagerState) {
    defer { lastBluetoothState = state }
    // Only notify on transitions into a problematic state, not on every
    // delegate fire (which includes the initial .unknown → .poweredOn).
    guard state != lastBluetoothState else { return }
    switch state {
    case .poweredOff:
      // Every maintenance dark wake cycles the radio through a genuine new
      // transition into `.poweredOff`, so the dedupe above can't help here.
      if !isSystemSleeping {
        Self.showBluetoothOffNotification()
      }
    case .unauthorized:
      NotificationManager.showNotification(
        title: "Bluetooth Permission Needed",
        body: "Grant Bluetooth access in System Settings to use Magic Switch."
      )
    case .unsupported:
      NotificationManager.showNotification(
        title: "Bluetooth Unsupported",
        body: "This Mac does not support the Bluetooth features Magic Switch needs."
      )
    case .poweredOn:
      // The radio is back; retire a delivered "Bluetooth Off" alert.
      NotificationManager.removeNotification(identifier: Self.bluetoothOffNotificationID)
      // The store's init-time snapshot bails while the radio reads off (e.g.
      // a login-item launch), and already-connected peripherals fire no new
      // connect event — re-resolve connection states now that it's up.
      bluetoothStore.fetchConnectedPeripherals()
    case .resetting, .unknown:
      break
    @unknown default:
      break
    }
  }

  /// Track system sleep so `.poweredOff` transitions during sleep stay silent.
  private func setupSleepWakeTracking() {
    let center = NSWorkspace.shared.notificationCenter
    sleepObserver = center.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isSystemSleeping = true
        self.bluetoothWasOnBeforeSleep = BluetoothManager.shared.state == .poweredOn
        self.wakeBluetoothRecheck?.cancel()
        self.wakeBluetoothRecheck = nil
      }
    }
    wakeObserver = center.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isSystemSleeping = false
        // Only when sleep began with the radio on: the recheck exists for a
        // radio that fails to come back, not to re-nag on every wake a user
        // who keeps Bluetooth off.
        if self.bluetoothWasOnBeforeSleep {
          self.scheduleWakeBluetoothRecheck()
        }
      }
    }
  }

  /// If Bluetooth fails to come back after a real wake, the state was already
  /// `.poweredOff` during sleep, so no new transition fires and
  /// `handleBluetoothStateChange` stays quiet. Re-check once instead.
  private func scheduleWakeBluetoothRecheck() {
    wakeBluetoothRecheck?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.isSystemSleeping else { return }
      self.wakeBluetoothRecheck = nil
      if BluetoothManager.shared.state == .poweredOff {
        Self.showBluetoothOffNotification()
      }
    }
    wakeBluetoothRecheck = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.bluetoothWakeGrace, execute: work)
  }

  private static func showBluetoothOffNotification() {
    NotificationManager.showNotification(
      title: "Bluetooth Off",
      body: "Magic Switch can't switch peripherals while Bluetooth is off.",
      identifier: bluetoothOffNotificationID
    )
  }

  private func setupStatusBar() {
    NSApp.setActivationPolicy(.accessory)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    // A tracked status-item NSMenu (not a popover): it keeps the menu bar
    // revealed over full-screen Spaces and never activates the app. Its single
    // item hosts an AppKit `DropdownContentView` whose controls consume the
    // mouse-up, so clicks don't dismiss it — the dropdown stays open while a
    // peripheral pairs. (SwiftUI controls don't track inside a menu.)
    statusItem.menu = makeDropdownMenu()
    refreshStatusBarIcon()
  }

  /// Build the status-item dropdown: an `NSMenu` whose single item hosts the
  /// AppKit `DropdownContentView`. The view drives switch actions directly;
  /// Settings / Quit route back through the delegate.
  private func makeDropdownMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    let item = NSMenuItem()
    let content = DropdownContentView(
      takeViewModel: takeViewModel,
      onSwitchMac: { [weak self] device in
        self?.handoffCoordinator.perform(.toggle, peer: device.handoffPeer)
      },
      onOpenSettings: { [weak self] in self?.openSettingsWindow(nil) },
      onQuit: { [weak self] in self?.quitFromStatusBar(nil) })
    content.updateFrameToFit()
    item.view = content
    menu.addItem(item)
    dropdownContentView = content
    return menu
  }

  /// Refresh reachability + re-measure the hosted view just before the dropdown
  /// opens. Probe results land asynchronously and re-render the open menu.
  func menuWillOpen(_ menu: NSMenu) {
    networkStore.refreshReachability()
    // Re-read paired devices so a peripheral renamed in System Settings (and
    // its icon) refreshes in the dropdown without needing to open Settings.
    BluetoothPeripheralStore.shared.fetchConnectedPeripherals()
    // The snapshot above only triggers a rebuild when something changed;
    // battery levels are read at build time, so ask for one regardless.
    dropdownContentView?.refreshRows()
    dropdownContentView?.updateFrameToFit()
  }

  /// `NSImage(named:)` returns the shared cache instance — never mutate it,
  /// copy first.
  private static let statusBarGlyph = NSImage(named: "StatusBarIcon")

  /// The idle glyph, template-tinted like every other state the icon shows.
  private static let statusBarIdleIcon: NSImage? = {
    guard let icon = statusBarGlyph?.copy() as? NSImage else { return nil }
    icon.size = NSSize(width: 24, height: 24)
    icon.isTemplate = true
    return icon
  }()

  /// The idle glyph knocked out of a filled rounded square — the Control
  /// Center "engaged" look — shown while peripherals are connected to this
  /// Mac. Composited from the same asset so the two states can't drift.
  private static let statusBarConnectedIcon: NSImage? = {
    guard let glyph = statusBarGlyph?.copy() as? NSImage else { return nil }
    let icon = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
      NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 4), xRadius: 5, yRadius: 5).fill()
      glyph.draw(
        in: rect.insetBy(dx: 3, dy: 3), from: .zero, operation: .destinationOut, fraction: 1)
      return true
    }
    icon.isTemplate = true
    return icon
  }()

  /// Updates the menu-bar icon based on transfer state (highest priority),
  /// then Pairing + Bluetooth state. Transfer state shows arrow icons so
  /// the user can tell at a glance that peripherals are moving, and in
  /// which direction. When the app cannot function (unpaired, Bluetooth
  /// off, etc.) we show a triangle exclamation mark instead. When idle,
  /// the icon gains a filled background while peripherals are connected
  /// to this Mac.
  private func refreshStatusBarIcon() {
    guard let button = statusItem?.button else { return }

    let needsAttention =
      !PairingStore.shared.isPaired
      || (BluetoothManager.shared.state != .poweredOn
        && BluetoothManager.shared.state != .unknown)

    // A transfer arrow or attention icon forfeits an in-flight ping flash —
    // that state change is more important to surface. Routine connection
    // churn must not: the idle branch below leaves the bell alone.
    if transferState != .idle || needsAttention {
      pingFlashTimer?.cancel()
      pingFlashTimer = nil
    }

    switch transferState {
    case .sending:
      let img = NSImage(
        systemSymbolName: "arrow.up.right.circle.fill",
        accessibilityDescription: "Sending peripherals to the other Mac")
      img?.isTemplate = true
      button.image = img
      button.toolTip = "Sending peripherals to the other Mac…"
      button.setAccessibilityLabel(button.toolTip ?? "")
      return
    case .receiving:
      let img = NSImage(
        systemSymbolName: "arrow.down.left.circle.fill",
        accessibilityDescription: "Receiving peripherals from the other Mac")
      img?.isTemplate = true
      button.image = img
      button.toolTip = "Receiving peripherals from the other Mac…"
      button.setAccessibilityLabel(button.toolTip ?? "")
      return
    case .idle:
      break
    }

    let tooltip = statusBarTooltip()
    if needsAttention {
      let image = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill",
        accessibilityDescription: "Magic Switch needs attention")
      image?.isTemplate = true
      button.image = image
    } else if pingFlashTimer == nil {
      let connected = bluetoothStore.peripheralPresence == .connectedHere
      if let image = connected ? Self.statusBarConnectedIcon : Self.statusBarIdleIcon {
        button.image = image
      }
    }
    button.toolTip = tooltip
    button.setAccessibilityLabel(tooltip)
  }

  /// Set the transfer-direction icon for the duration of a transfer.
  /// Sender uses this directly and clears it via `endTransfer()` when the
  /// secure-channel exchange completes (success or failure-with-rollback).
  private func beginTransfer(_ state: TransferState) {
    transferAutoEndTimer?.cancel()
    transferAutoEndTimer = nil
    transferLatchedAt = nil
    transferState = state
    refreshStatusBarIcon()
  }

  /// Same as `beginTransfer`, but ends by observation instead of an
  /// explicit completion: the icon holds while any registered peripheral
  /// is still `connecting`/`releasing` and reverts once the last one
  /// settles. Used by every path that lacks a single "all peripherals
  /// settled" callback — the store's per-peripheral states *are* that
  /// signal (pairing callbacks, the 60s pair watchdog, and the handoff
  /// completion arms all resolve them), which the old fixed 5s window
  /// ignored, reverting the icon while a transfer had seconds-to-a-minute
  /// left to run.
  private func beginTransferHold(_ state: TransferState) {
    transferState = state
    transferLatchedAt = Date()
    refreshStatusBarIcon()
    transferAutoEndTimer?.cancel()
    // The `$connectionStates` sink is the main settle signal; this repeating
    // check is for what the sink can't see — a transfer where no row ever
    // starts transitioning (nothing changes, so the sink never fires) and
    // the hard cap on rows that never settle.
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(
      deadline: .now() + Self.transferSettleGrace, repeating: Self.transferSettleGrace)
    timer.setEventHandler { [weak self] in self?.maybeEndHeldTransfer() }
    timer.resume()
    transferAutoEndTimer = timer
  }

  /// End a held transfer once its rows have settled. No-op for explicit
  /// (`beginTransfer`) transfers — those end from their own completion.
  private func maybeEndHeldTransfer() {
    guard transferState != .idle, let latchedAt = transferLatchedAt else { return }
    let elapsed = Date().timeIntervalSince(latchedAt)
    guard elapsed >= Self.transferSettleGrace else { return }
    if bluetoothStore.isAnyPeripheralTransitioning && elapsed < Self.transferHardCap {
      return
    }
    endTransfer()
  }

  private func endTransfer() {
    transferAutoEndTimer?.cancel()
    transferAutoEndTimer = nil
    transferLatchedAt = nil
    transferState = .idle
    refreshStatusBarIcon()
  }

  /// Observes `IncomingConnection`'s transfer-direction posts so the
  /// receiving Mac's status bar reflects what's happening to it.
  private func setupTransferObservers() {
    transferReceiveObserver = NotificationCenter.default.addObserver(
      forName: .magicSwitchReceivedConnectAll, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.beginTransferHold(.receiving) }
    }
    transferReleaseObserver = NotificationCenter.default.addObserver(
      forName: .magicSwitchReceivedUnregisterAll, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.beginTransferHold(.sending) }
    }
    transferIncomingOneObserver = NotificationCenter.default.addObserver(
      forName: .magicSwitchPeripheralIncoming, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.beginTransferHold(.receiving) }
    }
    transferOutgoingOneObserver = NotificationCenter.default.addObserver(
      forName: .magicSwitchPeripheralOutgoing, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.beginTransferHold(.sending) }
    }
    // Settle signal for held transfers: any per-peripheral state flip
    // re-evaluates whether the last transitioning row just resolved.
    transferSettleObserver = bluetoothStore.$connectionStates
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.maybeEndHeldTransfer()
      }
  }

  private func statusBarTooltip() -> String {
    if !PairingStore.shared.isPaired {
      return "Magic Switch: not paired. Open Settings → Pairing."
    }
    switch BluetoothManager.shared.state {
    case .poweredOff:
      return "Magic Switch: Bluetooth is off."
    case .unauthorized:
      return "Magic Switch: Bluetooth permission denied."
    case .unsupported:
      return "Magic Switch: Bluetooth not supported on this Mac."
    case .resetting:
      return "Magic Switch: Bluetooth is resetting."
    case .poweredOn, .unknown:
      switch bluetoothStore.peripheralPresence {
      case .connectedHere:
        return "Magic Switch — peripherals connected to this Mac"
      case .away:
        return "Magic Switch — no peripherals connected to this Mac"
      case .none:
        return "Magic Switch"
      }
    @unknown default:
      return "Magic Switch"
    }
  }

  // MARK: - URL Commands

  /// External-control entry point: `magicswitch://switch` URLs, parsed by
  /// `SwitchURLCommand`. macOS delivers them here whether the app was already
  /// running or was just launched by the open.
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      handleCommandURL(url)
    }
  }

  private func handleCommandURL(_ url: URL) {
    let command: SwitchURLCommand
    switch SwitchURLCommand.parse(url) {
    case .success(let parsed):
      command = parsed
    case .failure(let error):
      // The caller is a script or hotkey with no UI of its own, so a
      // notification is the only feedback channel — same for resolution
      // failures below.
      NotificationManager.showNotification(
        title: "Invalid Switch Command", body: error.message, identifier: "url-command-invalid")
      return
    }
    guard !command.selectors.isEmpty else {
      performFullSetCommand(command.direction)
      return
    }
    switch command.resolvePeripherals(in: bluetoothStore) {
    case .success(let peripherals):
      peripherals.forEach { bluetoothStore.switchPeripheral($0, direction: command.direction) }
    case .failure(let error):
      NotificationManager.showNotification(
        title: "Invalid Switch Command", body: error.message, identifier: "url-command-invalid")
    }
  }

  /// A command with no `peripheral=` filter. `take` uses the same engine as
  /// the display trigger because it has to work while the peer is asleep (an
  /// unreachable peer isn't holding the peripherals anymore); `send` and
  /// `toggle` need the peer awake anyway, so they go through the menu's
  /// health-checked path.
  private func performFullSetCommand(_ direction: SwitchDirection) {
    handoffCoordinator.perform(direction.handoffDirection)
  }

  // MARK: - Action Handlers

  private func setupDisplayTrigger() {
    displayMonitor.onTriggerDisplaysConnected = { [weak self] names in
      self?.handoffCoordinator.takeOnThisMac {
        NotificationManager.showNotification(
          title: "Display Connected",
          body:
            "\(names.joined(separator: ", ")) connected — switching your peripherals to this Mac.",
          identifier: "display-trigger-switch")
      }
    }
    displayMonitor.start()
  }

  private func setupHotkey() {
    HotkeyManager.shared.onHotkey = { [weak self] direction in
      self?.handoffCoordinator.perform(direction.handoffDirection)
    }
    HotkeyManager.shared.start()
  }

  private func setupHandoffNotifications() {
    handoffObserver = handoffCoordinator.$state
      .removeDuplicates()
      .sink { state in
        guard case .failed = state, let message = HandoffPresentation.message(for: state) else {
          return
        }
        NotificationManager.showNotification(
          title: "Switch Failed", body: message, identifier: "handoff-failed")
      }
  }
  // MARK: - Settings Management

  /// Opens the newest release in the default browser. Wired to the "Update
  /// Available" row in the dropdown (see `DropdownContentView`).
  @objc func openLatestReleasePage(_ sender: Any?) {
    guard let url = UpdateChecker.shared.releasePageURL else { return }
    NSWorkspace.shared.open(url)
  }

  /// Observes `.magicSwitchReceivedPing` (posted by `IncomingConnection`
  /// when this Mac handles a `.notification` command) and flashes the
  /// status-bar icon. This is the fallback signal for the case where
  /// `UNUserNotificationCenter` silently drops the alert — which it does
  /// reliably on ad-hoc-signed sandboxed builds where notification
  /// authorization can't be granted.
  private func setupPingFlashObserver() {
    pingObserver = NotificationCenter.default.addObserver(
      forName: .magicSwitchReceivedPing,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.flashStatusBarIcon() }
    }
  }

  /// Briefly swap the status-bar icon to a "bell" symbol, then restore
  /// the real state via `refreshStatusBarIcon()`. A transfer or
  /// needs-attention refresh during the flash window cuts it short —
  /// that's fine, the state change is more important to surface — but
  /// idle refreshes (connection-state churn) leave it up for the full 3s.
  private func flashStatusBarIcon() {
    guard let button = statusItem?.button else { return }
    // A transfer arrow outranks the bell: mid-transfer the user is watching
    // the icon for exactly that state, and the 3s flash would blank it out.
    guard transferState == .idle else { return }
    let flash = NSImage(
      systemSymbolName: "bell.badge.fill",
      accessibilityDescription: "Received a ping from the other Mac"
    )
    flash?.isTemplate = true
    button.image = flash
    pingFlashTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(deadline: .now() + 3.0)
    timer.setEventHandler { [weak self] in
      self?.pingFlashTimer = nil
      self?.refreshStatusBarIcon()
    }
    timer.resume()
    pingFlashTimer = timer
  }

  /// Opens the Settings window. We deliberately don't route through the
  /// SwiftUI `Settings { ... }` scene + `sendAction(showSettingsWindow:)`
  /// here — that path produces a Dock icon and an active app but no
  /// visible window on this codebase (LSUIElement + `.accessory` default),
  /// likely because the scene isn't fully wired up when invoked from a
  /// status-menu action handler. We host `SettingsView` in a plain
  /// `NSWindow` instead. Tooltips (`.help(...)`) need the window to be
  /// properly key under `.regular` to fire — hence the policy bump +
  /// `makeKeyAndOrderFront(_:)`.
  @objc func openSettingsWindow(_ sender: Any?) {
    PairingStore.shared.refreshState()
    NSApp.setActivationPolicy(.regular)
    if settingsWindowController == nil {
      settingsWindowController = makeSettingsWindowController()
    }
    settingsWindowController?.showWindow(nil)
    settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    // Activate AFTER ordering the window front so macOS switches to the Space
    // the window lives on (activating before a window exists can strand the
    // user on a full-screen Space). Deliberately the deprecated
    // `ignoringOtherApps:` form — the cooperative `activate()` won't take over
    // another app's full-screen Space.
    NSApp.activate(ignoringOtherApps: true)
  }

  private func makeSettingsWindowController() -> NSWindowController {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 600, height: 400)),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.center()
    window.title = "Settings"
    // Keep the window object around after the user closes it so re-opening
    // is just `makeKeyAndOrderFront`, not a full reconstruct.
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SettingsView())
    return NSWindowController(window: window)
  }

  /// Clicking the update banner opens the release page — the same action as
  /// the Update Available rows it points at. Every other Magic Switch
  /// notification is informational and just dismisses.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      response.notification.request.identifier == UpdateChecker.updateNotificationIdentifier
    {
      // Delegate callbacks arrive on an internal queue; hop to main before
      // touching NSWorkspace.
      DispatchQueue.main.async { [weak self] in self?.openLatestReleasePage(nil) }
    }
    completionHandler()
  }

  /// Drops the app back to `.accessory` (no Dock icon) once the last normal
  /// window closes. SwiftUI's `Settings` scene typically reuses one window,
  /// but the loop is defensive against any other normal-level window we
  /// might open in the future.
  private func setupActivationPolicyTracking() {
    windowCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      // Only react when a normal-level window closes. The right-click
      // NSMenu fires willClose as soon as the user picks Settings —
      // reacting to that races against the Settings window actually
      // appearing (we'd flip back to .accessory before SwiftUI has put
      // the window on screen, killing the open). Status-item windows
      // and popovers live at non-`.normal` levels and would hit the
      // same race.
      guard let window = notification.object as? NSWindow,
        window.level == .normal
      else { return }
      // `willClose` fires while the closing window is still flagged visible;
      // defer one runloop tick so the count reflects the post-close state.
      DispatchQueue.main.async {
        guard self != nil else { return }
        let openWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        if openWindows.isEmpty {
          NSApp.setActivationPolicy(.accessory)
        }
      }
    }
  }
}
