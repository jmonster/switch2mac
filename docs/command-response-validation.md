# Command response validation and recovery

Normal handshake/LED/memory commands and raw protocol experiments no longer
share an ambiguous “some bytes arrived” result. The session retains a typed
success or failure, including the complete eight-byte header and payload of a
status/error response. Ordinary callers receive a payload only on success;
existing NFC/audio probes deliberately retain their raw status-payload adapter.
New probes can use `experimentalCommandResult` to distinguish all outcomes.

A reply must be at least eight bytes, belong to a command actually submitted,
and echo the command, transport and subcommand. Unknown response classes,
truncation and unrelated headers do not consume the pending request or its
deadline. Memory successes additionally must echo the requested address and
length and contain the requested bytes. A correlated rejection need not contain
memory data: it completes as failure immediately, allowing best-effort user
calibration to fall back to factory data rather than waiting for a timeout.
LED acknowledgments can legitimately have no payload. Feature and bond steps
require a correlated success-class response at *each* step; an init response
cannot acknowledge feature enable, nor can one pairing subcommand acknowledge
another. The final bond-success message is emitted only on success.

The class policy follows the protocol notes: `0x01` is success and `0x02` is an
observed status/error class (NFC may use it for “not ready”). The other header
fields, including the byte called ACK in public research, are preserved without
inventing a universal bit/status interpretation or requiring one firmware's
opaque constant. Feature-result/pairing payloads with undocumented semantics
are not reinterpreted as generic status bytes. This is stricter reply correlation,
not a claim that every command payload or cryptographic pairing response has
been completely reverse-engineered.

## Timeout is a connection boundary

There is no wire transaction sequence that distinguishes a late reply from the
next identical command. After a submitted command times out the session is
retired, pending work is completed once, and the engine is notified. It does not
send another command on that ambiguous stream. This deliberately replaces the
old timeout-and-continue behavior, including for calibration. Explicit memory
rejections/invalid calibration can still use the existing fallback. A successful
reply cancels its token-guarded deadline; an obsolete timeout cannot retire a
replacement transaction. Queue capacity, write backpressure, frame atomicity,
motor handling and the keep-alive cadence are unchanged.

Tests exercise the production session bodies with fake CoreBluetooth boundaries,
not replacement response logic. Fixtures now echo realistic transport/subcommand
headers. Coverage includes every pairing rejection stage, feature init/enable,
short memory errors, slices, malformed/foreign replies, reentrancy, queued
cancellation, late-after-timeout replies, typed errors and raw NFC status access.
macOS CI separately compiles the actual app and runs the packaged runtime checks.
No physical firmware/radio acceptance is inferred from these regressions.

Protocol references:
- [Project command protocol](../research/PROTOCOL.md#3-command-protocol)
- [Observed command headers and responses](https://github.com/ndeadly/switch2_controller_research/blob/master/commands.md)
