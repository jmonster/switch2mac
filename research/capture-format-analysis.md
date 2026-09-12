# Anatomy of a Switch 2 "Headset Audio" Input Notification

*A format-identification study of a 30-second BLE capture from a Pro
Controller 2 (firmware 2.0+), 2026-08-09. Part of the
[controller research notes](README.md).*

**Capture setup:** the host subscribed to the audio input characteristic
`7492866C-EC3E-4619-8258-32755FFCC0F9` after sending audio config
`0x17/0x02` = `80 BB 00 00 02 F0 00` (48 000 Hz, mode 2, 240-sample
frames). No headset microphone was attached. 858 notifications of 112
bytes each were recorded, with no per-packet timestamps (a deficiency
fixed in the app's capture v2).

## Bottom line

The high-entropy 40-byte region that *looks* like compressed audio is
**not audio at all** — it is a bit-packed, repeating-record telemetry
structure (motion/orientation state), preceded by a 12-bit tick counter.
The actual audio region of the report idled at silence for the whole
capture. Every standard codec candidate is formally ruled out for the
telemetry blob (evidence below). This independently corroborates the
layout in ndeadly's `switch2_controller_research`, which places motion
data at offset 65 and headset audio at offset 15.

## 1. Verified packet layout (858 records × 112 B)

| Offset | Content | Evidence |
|---|---|---|
| 0 | u8 sequence, +1 mod 256, **zero drops** | 857/857 steps = +1 |
| 1 | const `0x20` (report type) | 858/858 |
| 2–4 | button state (none pressed) | 858/858 zero |
| 5–7 | left stick, packed 12-bit pair ≈ (1973, 2133) at rest, ±2 ADC noise | byte-level value ranges |
| 8–10 | right stick, packed 12-bit pair ≈ (2265, 2033) at rest | same |
| 11–12 | `0x38 0x00` const | 858/858 |
| 13 | audio/jack state; bit 3 = "audio frame present", alternating per packet | 429/429 lock to seq parity |
| 14 | audio region length (`0x32` = 50) | const |
| 15–64 | audio frame: `f8 ff fe` + 47 zero bytes when idle | exactly the bit-3 packets |
| 65 | telemetry length: `0x28` (=40) × 856, `0x04` × 2 | last-nonzero = 65+len |
| 66–105 | telemetry payload (§2) | |
| 106–111 | const zero | 858/858 |

So offsets 0–17 are a **miniature input report** (sequence, type,
buttons, both sticks, jack state) and the notification is
"input-report header + audio region + telemetry blob".

## 2. The 40-byte telemetry payload (bytes 66–105)

Bit-level analysis over all 856 full frames (per-bit P(1) and
adjacent-bit agreement, LSB-first):

- **Bytes 66–67: a 12-bit tick counter + 4 flag bits.** Increments
  +24/packet (823×), +25 every ~43 packets (a leap tick, flagged by bit
  12), +48 when byte 68 = `0x03` (9×), +72 with `0x04` (1×), +0 in the
  two 4-byte frames (`0x00`). Bit 15 set on normal frames, cleared on
  catch-up/empty frames.
- **Byte 68**: coverage code {`0x01` normal, `0x03` one skipped period,
  `0x04` two skipped, `0x00` empty}. **Byte 69**: `0x0f` normal, `0x0c`
  in the empty frames.
- **Bits 32–319: three-plus repetitions of an ~88-bit record**, each
  holding a small scale-like field S (≈37), a slowly-drifting unsigned
  field A (≈3400 — gravity-magnitude-like), **three sign-extended 16-bit
  signed channels** (|x| ~100 at rest), and a noisy positive field E.
  The 4th record is truncated.
- **The records are successive oversampled readings of the same
  quantities**: per-channel correlation between records is 0.96–0.99,
  and a lag test (corr(x₂[t+1], x₃[t]) = 0.950 > corr(x₂[t], x₃[t+1]) =
  0.856) proves record 3 is temporally newer than record 2.
- The three channels are **smooth across frames** (autocorrelation +0.88
  at lag 1) and are *not* a waveform within the frame — three parallel
  slow signals, not consecutive audio samples.
- **A physical event at packet ~776–800**: one channel spikes to −6600,
  then S and A shift *persistently* to the end of the capture — exactly
  what re-orienting the controller looks like, and nothing like a
  stationary noise-coding state.
- The two 4-byte frames echo the previous counter value with bit 15
  cleared — "no new record" markers, both right after catch-up frames.

**Tick rate.** Mean 24.023 ticks/notification. Cleanest reading:
tick = 1.25 ms (a native BLE unit), notification interval = 24 × 1.25 =
**30.0 ms**, making the capture ≈26 s of the 30 s window; the +25 leap
is ~940 ppm skew between the controller's tick clock and the connection
-event clock.

## 3. Entropy: structured, definitively not encrypted

Overall blob entropy is 7.32 bits/byte, but the decisive measurement is
**per-offset**: it oscillates between ~7.9 bits at some offsets and
1.7–3.4 bits at others (byte 68 takes 4 values; byte 69 takes 2).
Encrypted or whitened data is uniform at *every* offset; range-coded
bitstreams (Opus, LC3) are uniform at every offset past the first byte
or two. Fixed fields at fixed offsets = plaintext structure.

## 4. Codec candidates — all tested, all ruled out

| Candidate | Verdict | Killing evidence |
|---|---|---|
| Opus | ruled out | would-be TOC byte takes all 256 values; libopus rejects 601/856 packets as `OPUS_INVALID_PACKET`; fixed internal fields impossible in a range-coded stream |
| LC3 | ruled out | frame size is constant per configured stream — a 4-byte frame is impossible (spec min ~20 B); no LC3 duration matches the cadence; arithmetic-coded, contradicting §3 |
| IMA/OKI ADPCM | ruled out | hand-rolled decoder, both nibble orders, both stream and block-header forms: all decodes are near-full-scale clipped garbage; genuine idle-mic silence must decode to near-zero RMS |
| Raw PCM 8/16-bit | ruled out | zero-crossing rate ≈ 0.50 and lag-1 autocorrelation ≈ 0 at every width/endianness = white noise, i.e. reinterpreted structured data |
| Nintendo DSP-ADPCM | ruled out | 40 B = 5 × 8-byte frames fits arithmetically, but header nibble constraints are violated in 50–62 % of frames at every position; real streams violate ~never |

## 5. Implications

- The **telemetry blob** is a motion/orientation lane riding inside the
  headset-audio report. It should be ignored by audio work.
- The **audio region** (offset 15, 50 bytes) idles as `f8 ff fe` + 47
  zero bytes. Real codec analysis needs a capture with a microphone
  headset attached and a known stimulus. 50-byte frames against the
  configured 240-sample/5 ms PCM rate imply ≈10:1 compression; the
  codec remains publicly unidentified (the controller's flash holds a
  MediaTek `MT3616A0` DSP firmware blob, suggesting a vendor codec).
- **Playback format cannot be inferred from this capture** — the input
  lane wasn't carrying audio, so symmetry arguments are void.

## 6. Next captures

1. Headset with mic attached, loud tone into the mic — does the audio
   region light up, and with what statistics?
2. Rotate/shake the controller during capture — confirm the three
   signed channels track angular motion.
3. Toggle plug/unplug mid-capture and watch byte 13 and the S/A fields
   for mode transitions.
4. Per-packet timestamps (capture v2 already records them) to nail the
   notification interval directly.
