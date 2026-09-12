# Bounded reconnect recovery

A failed connection previously installed a two-second `retryAfter` timestamp
but no wakeup. If the next/only advertisement was delivered inside that window,
the guard discarded it. With duplicate discovery filtering enabled, no further
callback was guaranteed to advance the controller out of that state.

Failures now install a bounded deadline before retiring the attempt. During the
cooldown the engine retains at most one validated advertisement per peripheral:
the CoreBluetooth peripheral, observed pairing mode and a ten-second expiry.
It does not retain arbitrary advertisement data. One generation-protected work
item handles the earliest future deadline; repeated advertisements for the same
deadline do not reset the timer or extend the cooldown. Duplicate filtering
remains enabled (`allow duplicates = false`); it is not turned off to work
around this bug.

When due, a recent cached advertisement is admitted through the same connection
helper as a fresh discovery. Without a usable advertisement, the engine restarts
scanning once. Only one connection/handshake is admitted at a time; established
players keep receiving input and keep-alives. A cancelled attempt's peripheral
cannot be reused until its terminal callback. Waiting for that callback does not
poll; the terminal event also refreshes discovery once if the observation has
expired. Initial connect and handshake deadlines remain ten and forty-five
seconds respectively.

Discovery intent and capacity are rechecked before every deferred connection.
Quiet-when-ready discovery discards cached advertisements and cancels the wake;
full capacity pauses the wake and retains only unexpired observations. Stop,
sleep and Bluetooth reset cancel work and clear retry state. Expired work cannot
revive it after resume. Firmware, bonding keys, input mapping and radio service
filters are unchanged. A cached pairing indication is a recent observation,
not proof of the controller's current physical state; physical reconnect and
pairing acceptance still require hardware testing.

Both the cooldown and advertisement maps are capped at 64 entries. Exceptional
churn beyond this cap uses a bounded global cooldown rather than erasing existing
peripheral cooldowns or growing memory. There is no repeating retry timer, and
expired entries blocked on terminal cancellation do not create a zero-delay loop.

`bash tests/engine/run.sh` includes the pre-fix reproducer: a real extracted
connection-failure callback, one valid advertisement during cooldown and no
subsequent discovery callback. The shortened test deadline fires a real dispatch
work item and must create exactly one replacement attempt. Additional deterministic
tests cover rediscovery without an advertisement, 1,000 repeated notifications,
malformed/foreign advertisements, pairing-mode preservation, cancellation barriers,
late callbacks, stale observations, superseded deadlines, capacity, quiet mode,
bounded churn and public stop/suspend/resume. These tests run production engine
method bodies against the existing CoreBluetooth boundary doubles; they are not
physical radio or latency measurements.

Primary API references: Apple's
[duplicate-discovery option](https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerscanoptionallowduplicateskey)
and [connection API](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/connect(_:options:)).
