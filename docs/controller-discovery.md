# Optional quiet-when-ready discovery

Automatic discovery remains the default. The opt-in **Controller Discovery**
window can pause broad scanning once every remembered physical controller is
ready. Input, keep-alives, existing sessions, output delivery and pairing remain
unchanged. No idle polling timer is added.

Enabling the option opens a full 60-second setup window, rather than stopping
when the first half of a Joy-Con pair connects. Up to eight successfully ready
physical peripheral UUIDs are remembered locally, only while this option is on.
Whenever any remembered controller disappears, the normal scanner resumes via
the existing lifecycle callbacks. Once all are ready again, discovery quiets.

An unfamiliar controller cannot join while scanning is paused. Choose **Find
New Controllers for 60 Seconds**, then hold its Sync button. This opens one
bounded, replaceable window without retiring current players. If a remembered
controller is missing afterward, scanning continues for it. **Use Only Currently
Connected Controllers** closes the window and removes older units from this
set; it does not unpair a controller or erase mappings. Restore automatic mode
and clear the cache with the explicit reset button.

Stop, sleep and Bluetooth teardown cancel the window; stale expiry callbacks
cannot close a replacement window. Advertisements queued before `stopScan` do
not initiate new connections while discovery is intentionally paused. The
existing service/characteristic discovery and connection/handshake deadlines
remain unchanged. CoreBluetooth privacy approval is still required.

This implements the safe, opt-in ready-set portion of audit A18. It is not a
claim that remembered-device retrieval eliminates radio activity: CoreBluetooth
can have other radio work, and waiting for missing units still scans normally.
Physical button-wake latency, range, multi-controller pairing and Mac/controller
energy need comparative measurements before changing the default. The tests
exercise the production scan-control method and policy with fake radio boundaries,
not a physical Bluetooth adapter. No controller identifiers are exported by the
support summary.
