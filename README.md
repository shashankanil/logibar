# LogiBar

A small macOS menu bar app for Logitech mice and keyboards — no Logitech software needed.
It talks Logitech's HID++ 2.0 protocol directly over IOKit, so it works with Unifying, Bolt and
Lightspeed receivers as well as devices connected over Bluetooth or a USB cable.

## What it can control

Only controls the connected device actually supports are shown.

| Setting | HID++ feature |
| --- | --- |
| Battery level / charging | 0x1000, 0x1001, 0x1004 |
| DPI | 0x2201 |
| Polling rate | 0x8060, 0x8061 |
| Onboard profiles on/off (G series) | 0x8100 |
| Wheel ratchet / free spin, SmartShift sensitivity | 0x2110, 0x2111 |
| Scroll direction, high-resolution scrolling | 0x2121 |
| Fn key inversion (keyboards) | 0x40A0, 0x40A2, 0x40A3 |
| Easy-Switch channel | 0x1814 |

Settings you change are saved per device and re-applied when it reconnects or wakes, since many
devices forget host-set values after a power cycle.

Not covered: button remapping, gestures, lighting, and non-HID++ devices (webcams, most headsets).

## Build

```sh
./scripts/build-app.sh            # builds build/LogiBar.app
./scripts/build-app.sh --install  # also copies it to ~/Applications and launches it
```

Requires macOS 14+ and Xcode / Swift 5.10+.

## Debugging

```sh
LOGIBAR_DEBUG=1 .build/release/LogiBar --dump
```

prints every detected device and its current settings without changing anything. Wireless devices
that are asleep don't answer, so move the mouse or press a key first.

## License

MIT. Not affiliated with or endorsed by Logitech.
