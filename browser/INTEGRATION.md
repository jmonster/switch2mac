# Browser access and lifecycle

The browser listener is **disabled by default**. Load the unpacked extension
and copy its 32-letter ID from `chrome://extensions`. In **Browser Bridge
Settings**, enter the ID, enable the bridge, and click **Apply Changes**.
Multiple IDs may be separated with spaces. An empty or invalid allowlist does
not open a listener. To disable the listener, clear the toggle and apply the
change. Moving an unpacked extension can change its ID.

The listener binds only to `127.0.0.1` and accepts exactly one matching
`chrome-extension://<id>` Origin header. This excludes arbitrary websites;
it is **not authentication against other programs on the same Mac**, which
can forge an Origin. The extension runs only on its manifest's named sites.
There is no wildcard-site permission or remote-network listener.

The hub limits eight clients (including pending handshakes), 64 KiB received
messages, 200 messages/client/second, and 128 messages / 256 KiB awaiting send
completion per client. Slow or invalid clients are disconnected rather than
allowed to grow an unlimited send backlog. The per-report dispatch queue is
not a hard real-time or total-process-memory guarantee.

Connection replay retains identity after renames and supplies the last state.
Retired sockets cannot clear a replacement. Rumble refreshes every 200 ms only
for the requested effect duration; disconnect and preemption cancel and settle
it. Durations and start delays must be finite and at most 60 seconds. A departing
native client stops only the rumble it owns. GameCube HD rumble is not forwarded;
verified preset rumble remains unavailable.

Run `node --test tests/browser/*.test.cjs` and, on macOS,
`bash tests/browser/run.sh`. Tests include a Network.framework listener and raw
loopback WebSocket clients. Node tests use simulated browser objects; hardware
and real-browser/game acceptance require separate testing.
