# Handoff root-cause analysis

## User-visible failure

Switching a Magic Keyboard or Magic Mouse could leave it on neither Mac, require
"Forget This Device", or start overlapping retries. Different Apple IDs are not
the direct cause. They only rule out Apple's account-bound Universal Control as
the solution.

## Ownership map before the change

| Responsibility | Competing owners |
| --- | --- |
| Full-set handoff | `AppDelegate`, `BluetoothPeripheralStore` |
| Peer command sequencing | `AppDelegate`, `IncomingConnection`, `NetworkDeviceStore` |
| Operation progress | AppDelegate transfer latch, per-device connection state, reconnect watchlist |
| Pairing repair | Normal release and normal connect paths |
| Sleep handoff | `BluetoothPeripheralStore`, enabled by default |

## Root causes

1. **P1 — destructive release was the default.** `unregisterFromPC` called the
   private `IOBluetoothDevice.remove` selector. Every ordinary switch therefore
   destroyed a valid local bond and made recovery depend on a fresh pair.
2. **P1 — no single transaction owner.** UI, lifecycle, Bluetooth, and network
   layers each advanced parts of the same handoff. Double clicks, delayed ACKs,
   and retries could start a second transition before the first one settled.
3. **P1 — release ACK raced the Bluetooth operation.** The peer acknowledged
   `UNREGISTER_ALL` before its asynchronous releases completed, so the receiving
   Mac could begin connecting while the sender still held the devices.
4. **P2 — hidden lifecycle mutation.** Sleep release defaulted to on and could
   alter ownership without a user gesture.
5. **P2 — recovery and normal operation were conflated.** A failed bonded open
   silently escalated to bond removal. The UI did not explain this destructive
   boundary.
6. **P2 — no transaction tests or privacy manifest.** The critical state machine
   had no deterministic seam, and UserDefaults use was undeclared.

## Root treatment

- `HandoffCoordinator` is the only owner of full-set transactions and rejects a
  second operation while one is active.
- Normal release uses `closeConnection()` and preserves pairing.
- The peer ACKs release only after every release callback completes.
- Automatic pairing repair is an explicit, default-off compatibility option.
- Sleep release is default-off.
- The menu starts with one prominent, idempotent take button and shows progress.
- A privacy manifest declares app-only UserDefaults access (`CA92.1`).

## Physical constraint

Apple's Magic peripherals are not general multipoint devices. A preserved bond
can still be rejected after another host changes the peripheral's link key. The
app must surface that as a repair case; it cannot guarantee bond-preserving
switching on every firmware generation. The compatibility option exists for
that case and is deliberately separated from the safe path.

## Deletion ledger

- Normal-path calls to private `IOBluetoothDevice.remove`: removed.
- Immediate success ACK for `UNREGISTER_ALL` / `UNREGISTER_ONE`: removed.
- Default-on sleep release: removed.
- Automatic stale-bond repair as the default connect behavior: removed.
- Full-set entry points bypassing a coordinator: replaced by coordinator
  routing; 300+ lines of duplicate AppDelegate sequencing were deleted.
