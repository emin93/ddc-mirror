# ddc-mirror

Minimal macOS LaunchAgent that mirrors the built-in display brightness to external DDC/CI monitors. No UI, no hotkeys, no display management. Requires the built-in display to be active.

`ddc-mirror` watches the active built-in display brightness and sends the matching brightness percentage to external monitors through an existing DDC backend. This lets the normal macOS brightness keys and automatic built-in display brightness become the source of truth.

## Requirements

- macOS 12 or newer
- An active/open built-in display
- An external monitor that supports DDC/CI brightness control
- One backend:
  - `m1ddc` for Apple Silicon Macs using USB-C/DisplayPort Alt Mode
  - `ddcctl` as a fallback backend
  - `betterdisplaycli` as a compatibility fallback for setups where open-source DDC backends cannot communicate with the display

## Install

```sh
brew install emin93/tap/ddc-mirror
brew services start ddc-mirror
```

For development, build directly:

```sh
swift build -c release
.build/release/ddc-mirror
```

## Usage

Run once without touching DDC hardware:

```sh
ddc-mirror --backend print --once --verbose
```

Run continuously with the automatic backend:

```sh
ddc-mirror
```

Target specific backend displays:

```sh
ddc-mirror --display 1 --display 2
```

Adjust the output range if the monitor is too dim or too bright at the extremes:

```sh
ddc-mirror --min 10 --max 80
```

## Configuration

Options can be passed as CLI flags or environment variables:

| Option | Environment | Default |
| --- | --- | --- |
| `--backend auto|m1ddc|ddcctl|betterdisplay|print` | `DDC_MIRROR_BACKEND` | `auto` |
| `--displays 1,2` | `DDC_MIRROR_DISPLAYS` | unset |
| `--interval 0.5` | `DDC_MIRROR_INTERVAL` | `0.5` |
| `--min-delta 0.01` | `DDC_MIRROR_MIN_DELTA` | `0.01` |
| `--min 0` | `DDC_MIRROR_MIN` | `0` |
| `--max 100` | `DDC_MIRROR_MAX` | `100` |
| `--verbose` | `DDC_MIRROR_VERBOSE=1` | off |

The Homebrew service also reads `~/.config/ddc-mirror/config` using the same
`KEY=value` names. Set `DDC_MIRROR_CONFIG` to point at a different file.

## Scope

This intentionally does not add controls to macOS Displays settings, does not intercept keyboard events, and does not provide a menu bar app. It only mirrors the built-in display brightness while the built-in display is active.

In clamshell mode, on Mac mini, or on Mac Studio, there is no built-in display brightness source to mirror.

## Development

```sh
swift test
swift run ddc-mirror --backend print --once --verbose
```

## License

MIT
