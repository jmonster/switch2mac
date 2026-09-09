# Fork integration: explicit opt-in and extension access

This fork keeps the browser listener **disabled by default**. After loading the
unpacked extension, copy its 32-letter ID from chrome://extensions. In the
menu-bar app open **Browser Bridge Settings**, enter that ID, enable the bridge,
and quit/relaunch the app. Multiple IDs may be separated with spaces. An empty
or invalid allowlist does not open a listener. To disable it, clear the toggle
and relaunch. Moving the unpacked extension can change its ID.

The listener binds only to 127.0.0.1 and accepts exactly one matching
chrome-extension://<id> Origin header. This excludes arbitrary websites;
it is **not authentication against other programs on the same Mac**, which
can forge an Origin. The extension still runs only on its manifest's named
sites. There is no wildcard-site permission or remote-network listener.

The hub limits eight clients (including pending handshakes), 64 KiB received
messages, 200 messages/client/second, and 128 messages / 256 KiB awaiting send
completion per client. Slow or invalid clients are disconnected rather than
allowed to grow an unlimited send backlog. The per-report dispatch queue is
not a hard real-time or total-process-memory guarantee.

Connection replay retains identity after renames and supplies the last state.
Retired sockets cannot clear a replacement. Rumble refreshes every 200 ms only
for the requested effect duration, and disconnect/preemption cancels and
settles it. Durations and start delays must be finite and at most 60 seconds.
A departing native client stops only the rumble it owns. GameCube HD rumble is
not forwarded; verified preset rumble remains unavailable, rather than sending
a motor format the model explicitly declares unsupported.

Automated checks: node --test tests/browser/*.test.cjs and, on macOS,
bash tests/browser/run.sh. They include an actual Network.framework listener
and raw loopback WebSocket clients. Node uses simulated browser objects; no
Chromium/cloud-game or physical-controller acceptance is implied.

This adapts Andrei-Kondrykau/switch2mac browser-bridge commit
24b0cd3d225c77c9efcfca42cb4fd4325e2fccf3. Upstream browser/README.md describes
the original integration; this document's opt-in requirements take precedence.
