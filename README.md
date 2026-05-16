<div align="center">

# ✨ ddc-mirror

### 🔆 Your external displays, finally in sync with macOS brightness.

<img src="docs/assets/banner.png" alt="ddc-mirror — brightness, in sync." width="100%" />

[![macOS](https://img.shields.io/badge/macOS-12%2B-000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-only-000?logo=apple&logoColor=white)](#)
[![License: MIT](https://img.shields.io/badge/license-MIT-ffd166)](LICENSE)
[![Free Forever](https://img.shields.io/badge/💛-free%20forever-ff9f6b)](#)
[![Zero Config](https://img.shields.io/badge/⚙️-zero%20config-6ee7a7)](#)

[**🌐 ddc-mirror.emin.ch**](https://ddc-mirror.emin.ch) &nbsp;·&nbsp; [**📦 GitHub**](https://github.com/emin93/ddc-mirror)

</div>

---

## 🪄 What is it?

A tiny macOS LaunchAgent that watches your **built-in display's brightness** and mirrors it to **every external monitor** you have plugged in.

When macOS dims your MacBook (manually, or automatically via the ambient light sensor), `ddc-mirror` syncs the same brightness to all your externals. It picks the best mechanism per display automatically: DDC/CI for monitors on a direct cable, software gamma dimming for monitors behind a dock or hub that strips DDC, and Apple's native API for Studio/Pro Display XDR.

## 🚀 Install &amp; forget

```sh
brew install emin93/tap/ddc-mirror
brew services start ddc-mirror
```

That's it. There is no step two.

## 💡 Why you'll like it

- 🔌 **Plug-and-sync.** Connect a new monitor and it gets picked up on the next tick. Unplug one and it's gone. No restart, no config.
- 🖥️ **Every monitor, every time.** Multiple externals? They all sync. No "primary display" weirdness.
- 🤫 **Invisible.** No menu bar icon. No preferences pane. No hotkeys to remember. The only UI is the one Apple already ships.
- 🧘 **Lightweight.** ~3 MB binary, ~12 MB resident memory. You will not notice it is running.
- 🕵️ **No telemetry.** No analytics, no update pings, no crash reports phoned home. It physically cannot tell anyone you installed it.
- 💸 **Free forever.** MIT licensed. No pro tier, no paywall, no "upgrade for more features." There are no more features &mdash; that's the whole point.

## 🧠 How it works

| | |
| :-: | :-- |
| **01** | Subscribes to Apple's private `DisplayServices` brightness-change push notification &mdash; the same signal that drives the macOS brightness HUD. No polling. |
| **02** | On each change (debounced 80&nbsp;ms), pushes the new value to every external display. For each one it auto-picks the right mechanism at startup: **Apple-native API** for Studio/Pro Display XDR, **DDC/CI** (`IOAVServiceWriteI2C` VCP `0x10`) for monitors on direct cables, and **software gamma dimming** (`CGSetDisplayTransferByFormula`) for monitors behind docks/hubs/KVMs that strip DDC. |
| **03** | Re-enumerates displays on hot-plug (`CGDisplayRegisterReconfigurationCallback`) and on wake (`IORegisterForSystemPower`). Restores factory gamma on exit. Survives reboots via `brew services`. |

## 🛠️ Development

```sh
make
./ddc-mirror
```

The whole thing is one `.m` file and a Makefile. No SwiftPM, no dependencies. Apple Silicon only.

## 📜 License

[MIT](LICENSE) &middot; made with 💛 by [emin](https://emin.ch)
