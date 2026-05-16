<div align="center">

# ✨ ddc-mirror

### 🔆 Your external displays, finally in sync with macOS brightness.

<img src="docs/assets/banner.png" alt="ddc-mirror — brightness, in sync." width="100%" />

[![macOS](https://img.shields.io/badge/macOS-12%2B-000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/license-MIT-ffd166)](LICENSE)
[![Free Forever](https://img.shields.io/badge/💛-free%20forever-ff9f6b)](#)
[![Zero Config](https://img.shields.io/badge/⚙️-zero%20config-6ee7a7)](#)

[**🌐 ddc-mirror.emin.ch**](https://ddc-mirror.emin.ch) &nbsp;·&nbsp; [**📦 GitHub**](https://github.com/emin93/ddc-mirror)

</div>

---

## 🪄 What is it?

A tiny macOS LaunchAgent that watches your **built-in display's brightness** and mirrors it to **every external monitor** you have plugged in &mdash; over DDC/CI.

When macOS dims your MacBook (manually, or automatically via the ambient light sensor), `ddc-mirror` writes the same brightness percentage to all your external displays. So your whole desk dims and brightens together, the way it always should have.

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
| **01** | Watches the built-in display's brightness via Apple's native `DisplayServices` stack &mdash; the same signal macOS uses for its brightness HUD. |
| **02** | On every change, writes the matching brightness over DDC/CI to all connected external monitors (`m1ddc` on Apple Silicon, `ddcctl` as a fallback). |
| **03** | Runs as a `brew services` LaunchAgent. Survives reboots. Rediscovers displays automatically when they connect or disconnect. |

## 🛠️ Development

```sh
swift build
swift run ddc-mirror
```

Want to see what it would write, without touching any displays?

```sh
swift run ddc-mirror --backend print --once --verbose
```

## 📜 License

[MIT](LICENSE) &middot; made with 💛 by [emin](https://emin.ch)
