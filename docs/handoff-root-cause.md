# Handoff root-cause analysis

## Decision: would we build the old app this way today?

No. The old handoff was distributed across the app delegate, two stores,
network callbacks, per-device reconnect loops, and UI state. That made a single
user action impossible to reason about as a transaction. The replacement uses
a small typed state machine, protocol-bound Bluetooth and peer services, one
composition root, and an exclusive lease on the physical peripheral set.

The large legacy stores remain as platform adapters because they contain the
IOBluetooth edge-case handling already proven by the app. They no longer own
full-set sequencing or presentation. Rewriting that hardware layer without a
device lab would increase, not reduce, release risk.

## User-visible failure

Switching a Magic Keyboard or Magic Mouse could leave it on neither Mac, require
“Forget This Device”, or start overlapping retries. Different Apple IDs are not
the cause; they only make Apple's account-bound Universal Control unsuitable.

## Root causes and treatments

| Severity | Root cause | Root treatment |
| --- | --- | --- |
| P1 | Ordinary release deleted the local Bluetooth bond through a private `remove` selector. | Normal handoff now uses `closeConnection()` and preserves the bond. Destructive stale-bond repair is an explicit, default-off compatibility option. |
| P1 | AppDelegate, stores, callbacks, and UI all advanced parts of one transfer. | `HandoffCoordinator` is the sole local full-set transaction owner. It depends only on typed protocols and exposes a typed state. |
| P1 | The peer acknowledged release before asynchronous Bluetooth releases completed. | `UNREGISTER_ALL` and `UNREGISTER_ONE` acknowledge only after their release callbacks settle. |
| P1 | A remote command could arrive during local preflight, before any row became “transitioning”. | Local and authenticated inbound full-set commands now acquire the same exclusive lease from `BluetoothPeripheralStore`; per-device mutations are rejected while it is held. |
| P1 | A lost release acknowledgement could stop “take” after the peer had already released, leaving devices on neither Mac. | “Take on this Mac” is authoritative: remote release is best-effort and local acquisition always follows. |
| P2 | Send performed two consecutive peer health checks. | One authenticated `PING` is the single preflight and source of truth. |
| P2 | Hidden sleep behavior could change ownership without a click. | Sleep release is off by default. |
| P2 | Failures were strings spread through callbacks and rollback could finish before reconnect results. | Typed failures and success states drive presentation; rollback awaits every reconnect result before completing. |
| P2 | Repeated clicks and external transitions had no consistent feedback. | A local operation gate makes clicks idempotent; the resource lease rejects competing work; busy state is visible. |
| P2 | The critical path had no deterministic tests or privacy declaration. | The core is a Swift package with fake services and transaction tests; `PrivacyInfo.xcprivacy` declares app-only UserDefaults access. |

## Current ownership model

```text
menu / hotkey / URL / display trigger
                │
                ▼
       HandoffCoordinator       typed state → TakeDevicesViewModel → menu
          │             │
          ▼             ▼
 Bluetooth service   Peer service
          │             │
          └──────┬──────┘
                 ▼
 exclusive full-set lease ── also required by authenticated inbound commands
                 │
                 ▼
     IOBluetooth + sealed peer channel
```

The composition root is `AppDelegate`; there is no coordinator singleton. The
coordinator never imports IOBluetooth, Network framework types, app settings, or
SwiftUI. Runtime adapters translate those details at the boundary.

## Audit/fix loop

1. **Baseline:** found destructive bond removal, early ACK, duplicate owners,
   hidden defaults, no transaction tests. Fixed and built.
2. **Architecture audit:** the first coordinator still depended directly on
   concrete singleton stores and was only helper-tested. Replaced it with typed
   protocols, async orchestration, injected adapters, a view model, and behavior
   tests.
3. **Failure-semantics audit:** found duplicate peer preflight and the lost-ACK
   stranding case. Removed the duplicate and made take authoritative.
4. **Concurrency audit:** found the preflight race between local and inbound
   operations. Added the resource-level lease and inbound rejection rules.
5. **Verification audit:** package tests, full app build, static analyzer,
   formatting, signing checks, and launch smoke test are release gates.

After cycle 5 there are no known open P0, P1, or P2 findings in the handoff,
security, lifecycle, packaging, or launch paths.

## Deliberate P3 / physical constraints

- Several legacy UI/platform files are larger than ideal and still use
  singleton access. They are adapters outside the new transaction core; a
  mechanical split would not change runtime ownership and is deferred.
- Complete Swift 6 concurrency checking reports those legacy singleton
  declarations. The supported Swift 5 build is warning-clean for the changed
  path; migrating every platform callback is a separate modernization, not a
  handoff correctness fix.
- Magic peripherals are not general multipoint devices. Some firmware replaces
  its link key when another host adopts it. Safe bond-preserving handoff is the
  default; explicit repair exists for that firmware behavior. No software can
  guarantee a successful radio handoff while a device is powered off, out of
  range, or refusing connections.
- Automated tests cannot replace a two-Mac, real-keyboard/mouse acceptance run.
  The release artifact is therefore built to make that final physical check
  repeatable without changing source or signing.

## Deletion ledger

- Normal-path private `IOBluetoothDevice.remove`: removed.
- Immediate success ACK for release commands: removed.
- Default-on sleep release: removed.
- Automatic stale-bond repair as the default: removed.
- Duplicate full-set sequencing in AppDelegate: removed.
- Duplicate peer health probe: removed.
- Coordinator singleton and direct store dependencies: removed.
- Untyped success/failure strings in the transaction core: removed.
