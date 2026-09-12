# The Hunt for Switch 2 Controller Audio over BLE

*Status report of an ongoing investigation. Part of the
[controller research notes](README.md). Last updated
2026-08-10.*

The Pro Controller 2 has a 3.5 mm headset jack. On a console, GameChat
audio plays through it and a headset mic streams back. Nobody outside
Nintendo has yet made that work over Bluetooth LE from a PC or Mac —
the wire framing is documented (here and in ndeadly's research), but
the codec inside the frames is not. This document records what we know,
what we ruled out, and what remains.

## The lanes

| Lane | Characteristic | Status |
|---|---|---|
| Rumble / HD haptics | `CC483F51-…-630C31F72B05` | fully working (documented format) |
| Audio out (host → jack) | `CC483F51-…-630C31F72B06` | accepts writes; format unknown |
| Audio in (mic → host) | `7492866C-…-32755FFCC0F9` | framing decoded; codec unknown |

Audio and haptics are **separate lanes** — there is no DualSense-style
combined stream. Streaming is preceded by command `0x17/0x02` with
payload `80 BB 00 00 02 F0 00`: 48 000 Hz (u32 LE), mode/channels
`0x02`, 240 samples per frame (u16 LE) — nominal 5 ms frames. The
controller ACKs with an empty payload.

## The "haptic feedback bug" that wasn't (entirely)

Early experiments wrote 16-bit PCM sine waves to the audio output
characteristic and heard the **haptic actuator** buzz — which read as a
bug. Two real defects turned out to be stacked on top of each other:

1. The test generated a 440 Hz sine *for 48 kHz playback* but delivered
   only 25 samples per 5 ms — an effective 5 kHz sample rate. Played
   9.6× too slowly, the "440 Hz tone" came out near **46 Hz**:
   sub-bass, felt rather than heard, indistinguishable from rumble on a
   voice-coil actuator.
2. The write path had **no backpressure**: CoreBluetooth silently
   discards writes-without-response when its outbound buffer is full,
   so an unknown fraction of frames never left the Mac.

Both are fixed in the app (true 240-sample frames, MTU-aware chunking,
`canSendWriteWithoutResponse` + ready-callback pacing, delivery stats).
Whether correctly-paced PCM produces clean audio — and out of which
transducer — is the live experiment.

## What the mic lane actually sends

See [capture-format-analysis.md](capture-format-analysis.md) for the
full study. Summary: each 112-byte notification is a miniature input
report; its **audio region** (offset 15, 50 bytes) idles as
`f8 ff fe` + zeros without a mic, and the high-entropy blob at offset
65 that looks like compressed audio is actually **packed motion
telemetry** (12-bit tick counter at 1.25 ms units, oversampled 3-channel
records). Opus, LC3, SBC-class, IMA/OKI ADPCM, Nintendo DSP-ADPCM, and
raw PCM are all formally ruled out for it.

Two hardware quirks, both verified: subscribing to the audio input
characteristic **starves regular input reports** (buttons freeze for
the whole capture window), and 50-byte frames against the configured
240-sample/5 ms rate imply **≈10:1 compression** — pointing at a vendor
codec (the controller's flash contains a MediaTek `MT3616A0` DSP
firmware blob).

## The USB shortcut

Over USB-C the controller enumerates as a plain **USB Audio Class 1.0**
device: 48 kHz 16-bit stereo out to the jack, mono mic in, standard
mute/volume — driverless on macOS/Windows/Linux. For *using* the jack,
USB already works; BLE is the wireless frontier. USB also provides
known-plaintext reference recordings for cracking the BLE codec.

## Rumble, properly

Two details beyond the common community docs, cross-verified against
console USB captures: the 9-bit frequency fields of the 5-byte waveform
samples carry **direct Hz** (idle frame `E1 00 10 1E 00` = 225 Hz low
band), and the sequence nibble in the `0x50|seq` header **must
increment** — the controller silently de-duplicates stale-sequence
packets. The console re-sends every ~5 ms; ~20–50 ms sustains a steady
tone. This makes the actuators fully programmable as frequency+amplitude
voices (the app's "haptic melody" experiment plays tunes through them).

## Open questions

1. What codec fills the 50-byte mic frames when a headset mic is
   present? (Needs a capture with mic + known stimulus.)
2. Does the output lane accept raw PCM at the configured rate, or the
   same unknown codec? (The app's real-time tone test answers this by
   ear: clean 440 Hz = PCM.)
3. What routes output between jack and actuator — jack presence, the
   config mode byte, or an undocumented command? (`0x18/0x01` returns
   `00 00 40 f0 00 00 60 00` and is unexplored.)
4. What are the semantics of audio-state byte values beyond
   0x00/0x05/0x07 (nothing/headphones/headset)?
