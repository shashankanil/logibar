<div align="center">

<img src="assets/logo.png" width="160" alt="LogiBar logo">

# LogiBar

**Control your Logitech mouse and keyboard from the macOS menu bar.**<br>
DPI, polling rate, SmartShift, battery and more — without G HUB, Options+ or any Logitech software.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white)](#install)
[![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-4338CA)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/shashankanil/logibar?color=06B6D4)](https://github.com/shashankanil/logibar/releases/latest)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/screenshot-dark.png">
  <img src="assets/screenshot-light.png" width="380" alt="LogiBar menu showing a G304 with DPI, polling rate and onboard profile controls">
</picture>

</div>

## Why

Logitech's apps are big, need accounts and background daemons, and are split by product line —
G HUB for G series, Options+ for MX and everything else, and some devices work with neither on
recent macOS. LogiBar is one ~2 MB native app that talks to the hardware directly.

- **One app for every device** — G series, MX, ERGO, POP and budget lines, through Lightspeed, Bolt
  and Unifying receivers, Bluetooth or a USB cable.
- **Lives in the menu bar** — no Dock icon, no windows, no account, no telemetry.
- **Remembers your settings** — many devices forget host-set values when they power off; LogiBar
  quietly re-applies them whenever a device reconnects or wakes.
- **Only shows what your device supports** — controls are discovered from the device itself.

## Features

| | Setting | Typical devices |
| --- | --- | --- |
| 🔋 | Battery level and charging state | All wireless devices |
| 🎯 | DPI — slider plus quick presets | G series, MX Master / Anywhere, most mice |
| ⚡ | Polling rate (125 Hz – 8 kHz) | Gaming mice |
| 💾 | Onboard profiles on/off | G series with onboard memory |
| 🛞 | Ratchet / free spin and SmartShift sensitivity | MX Master, MX Anywhere |
| ↕️ | Scroll direction and high-res scrolling | Mice with the HID++ hi-res wheel |
| ⌨️ | Media keys vs. F1–F12 by default | MX Keys, K-series keyboards |
| 🔀 | Easy-Switch channel | Multi-device mice and keyboards |

## Install

### Download

1. Grab **LogiBar.zip** from the [latest release](https://github.com/shashankanil/logibar/releases/latest)
   and unzip it.
2. Move **LogiBar.app** to your Applications folder.
3. The build is ad-hoc signed rather than notarized, so the first time **right-click → Open → Open**
   (or run `xattr -dr com.apple.quarantine /Applications/LogiBar.app`).
4. Tick **Launch at login** in the menu if you want it to start automatically.

### Build from source

```sh
git clone https://github.com/shashankanil/logibar.git
cd logibar
./scripts/build-app.sh --install   # builds, copies to ~/Applications and launches
```

Requires macOS 14+ and Xcode or the Swift 5.10+ toolchain.

## Tips

- **G series DPI keeps changing back?** Turn off *Onboard profiles*. With it on, the mouse's
  built-in presets and DPI button take priority over the host.
- **Device shows "asleep or off"?** Wireless devices don't answer while sleeping. Move the mouse or
  press a key — it reappears within a minute, or hit ↻.
- **Got Logi Options / Options+ or G HUB installed?** Quit them; two apps writing the same settings
  will fight each other.

## How it works

Logitech devices speak **HID++ 2.0**, a vendor protocol carried over ordinary HID reports. Each
device exposes a table of numbered features (battery, DPI, wheel…), which LogiBar discovers at
runtime and drives through IOKit — no kernel extension, driver or special permission needed.

| Area | HID++ features |
| --- | --- |
| Identity | `0x0003` device info, `0x0005` name and type |
| Battery | `0x1000` status, `0x1001` voltage, `0x1004` unified battery |
| Pointer | `0x2201` adjustable DPI, `0x8060` / `0x8061` report rate, `0x8100` onboard profiles |
| Wheel | `0x2110` / `0x2111` SmartShift, `0x2121` hi-res wheel |
| Keyboard | `0x40A0` / `0x40A2` / `0x40A3` Fn inversion |
| Multi-host | `0x1814` change host |

```
Sources/LogiBar/
├── HIDPPTransport.swift   # raw HID++ request/response over one IOHIDDevice
├── HIDPPDevice.swift      # feature discovery, reading state, setters
├── DeviceManager.swift    # hot-plug, receiver slots, rescans, saved settings
├── MenuView.swift         # SwiftUI menu bar panel
└── main.swift             # app entry, --dump and --snapshot dev modes
```

Protocol details are thanks to the reverse-engineering work in [Solaar](https://github.com/pwr-Solaar/Solaar)
and [libratbag](https://github.com/libratbag/libratbag).

## Development

```sh
swift build -c release
LOGIBAR_DEBUG=1 .build/release/LogiBar --dump        # print detected devices and settings (read-only)
.build/release/LogiBar --snapshot out.png [--light]  # render the menu panel to a PNG
swift scripts/render-icon.swift                      # regenerate logo.png / AppIcon.icns from logo.svg
```

## Roadmap

- [ ] Button remapping and gestures
- [ ] Keyboard backlight control
- [ ] Show paired-but-offline devices from receiver pairing info
- [ ] Per-app profiles
- [ ] Signed and notarized releases, Homebrew cask

Tested so far on a **G304** (Lightspeed). If LogiBar works — or doesn't — with your device, please
[open an issue](https://github.com/shashankanil/logibar/issues) with the output of
`LOGIBAR_DEBUG=1 LogiBar --dump`. PRs welcome.

## License

[MIT](LICENSE). Not affiliated with or endorsed by Logitech. Logitech, G HUB, Logi Options+,
Lightspeed, Unifying and Bolt are trademarks of Logitech.
