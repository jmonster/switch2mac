# Wired USB command ownership

Selecting a USB device by VID/PID alone can send initialization or feedback
to the wrong controller when identical devices are connected. Command output
and HID input must resolve to the same physical device.

The s2usb-device-identity.patch resolves the exact HID DevSrvsID path
through IOKit to its USB device ancestor. It reads locationID and USB Address
(or USBDeviceAddress), matches both libusb bus and device address plus VID/PID,
and opens only a unique match. Registry entries and properties are released.
Unknown paths, missing/invalid properties and ambiguous matches do not guess.

**Compatibility tradeoff:** this acquisition path also performs wired
initialization. If identity cannot be established on a particular Mac/USB
backend, that wired SDL device may fail to initialize instead of falling back
to a potentially different controller. BLE/UDP output is unaffected. Capture
the actual HID/IOKit/libusb identities before qualifying supported hardware;
no physical-controller or driver-restoration test has been performed here.

CI compiles the real wired driver with libusb and Apple IOKit headers. A small
harness extracts the actual acquisition/identity function bodies and supplies
fake platform boundaries: the original selects the wrong identical device
(exit 42), the correction passes reverse-order, missing-peer, duplicate-address,
failed-claim, alternate-property, malformed-path and cleanup tests. The existing
real SDL/UDP edge test also runs against the combined rebuilt library.

Build with sdl/build-sdl.sh as documented in INPUT-DELIVERY.md. The tracked
dylib is not updated; the builder applies all four patches and
produces build/sdl/libSDL3.0.dylib. No controller command bytes are changed.
