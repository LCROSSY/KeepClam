# KeepClam 🦪

[![CI](https://github.com/LCROSSY/KeepClam/actions/workflows/ci.yml/badge.svg)](https://github.com/LCROSSY/KeepClam/actions/workflows/ci.yml)

**Keep calm. Keep the lid closed. Keep running.**

A tiny macOS menu-bar app that keeps your MacBook running with the lid closed — for overnight builds, downloads, syncs, and coding agents (Codex, Claude Code, …) that you want to keep alive after closing the lid. Works on battery, no external display required.

**KeepClam provides active overheat protection**: a watchdog process checks the system thermal state every 5 seconds and, when protection is triggered, attempts to restore normal sleep and requests immediate sleep.

[中文文档](README.zh-CN.md)

## Why

`caffeinate` and assertion-based tools (Caffeine, KeepingYouAwake, Amphetamine) prevent *idle* sleep only — they cannot keep a MacBook awake once the lid is closed. The only user-space mechanism that does is the kernel's `SleepDisabled` flag (`sudo pmset -a disablesleep 1`). KeepClam wraps that flag with the safety net it deserves:

- 🌡️ **Thermal guard** — an independent watchdog samples the official macOS thermal pressure every 5 s. On `serious`/`critical` (or 3 consecutive failed reads) it logs the trigger, restores sleep, and requests immediate sleep.
- 🛟 **Crash-safe** — the guard outlives the app. If the app quits or crashes mid-session, the guard notices and restores normal sleep. No leaked `SleepDisabled 1`.
- 🔋 **Auto-stop** — optional timer (30 min / 1 / 2 / 4 h / ∞), battery floor (5–50 %, default 20 %), and Low Power Mode yield.
- 👁️ **The menu bar never lies** — state is read back from the kernel every refresh; externally-enabled states are detected and labeled.
- 📜 **Session logs** — run-length-encoded samples of lid state, network reachability, and thermal state, so you can answer "what happened last night while the lid was closed?"
- 🌐 **Bilingual UI** — Simplified Chinese / English, switched in-app without relaunch.

## Install

**Requirements:** macOS 13+ (universal binary; Apple Silicon tested, Intel untested). Xcode Command Line Tools for building from source.

### Build from source (available now)

Install Xcode Command Line Tools first (skip if Xcode is already installed):

```sh
xcode-select --install
```

Once installed, run:

```sh
git clone https://github.com/LCROSSY/KeepClam.git
cd KeepClam
zsh scripts/build-native.command
open build/KeepClam.app
```

The app is built at `build/KeepClam.app`. You can also move it to `/Applications`.

### Download the preview release

Download `KeepClam-0.2.0.zip` and `SHA256SUMS` from [v0.2.0](https://github.com/LCROSSY/KeepClam/releases/tag/v0.2.0). Unzip and move **KeepClam.app** to `/Applications`. With both downloaded files in the same directory, run `shasum -a 256 -c SHA256SUMS` to verify the ZIP.

### Homebrew

```sh
brew install --cask LCROSSY/tap/keepclam
```

To update later, run `brew update` followed by `brew upgrade --cask keepclam`.

### First launch

The current build is ad-hoc signed and has not been notarized by Apple. If macOS blocks it, first verify that you trust its source. After attempting to open it, go to **System Settings → Privacy & Security → Open Anyway**, then confirm the prompt. See [Apple's instructions](https://support.apple.com/en-us/102445).

## Passwordless authorization (sudoers whitelist)

Toggling the `SleepDisabled` flag needs root. Instead of prompting for an admin password on every toggle, KeepClam uses a one-time, narrowly-scoped sudoers rule. Click **免密授权 / Authorize once** in the menu, or run:

```sh
zsh scripts/install-sudoers.sh
```

The rule allows exactly two commands and nothing else — no wildcards:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

- Audit what's installed: `sudo cat /etc/sudoers.d/keepclam`
- Remove it: `zsh scripts/uninstall-sudoers.sh` (toggles go back to per-action admin prompts)

Without the rule installed, KeepClam still works — it falls back to an admin password prompt per toggle.

Install the rule before closing the lid for unattended use: the background guard and automatic-stop paths use `sudo -n` and cannot display a password prompt while you are away.

## Launch at login

Enable **Settings → Launch at Login** after installing the app in `/Applications`. This starts only the menu-bar app; it does not enable lid-closed running or resume a previous session. The option is off until you enable it. If approval is required, the menu opens the system Login Items settings. Disable the option before uninstalling.

When upgrading from v0.1.0, stop the session and quit the old app first. v0.2.0 prevents duplicate instances, but the older version does not participate in that lock.

## Usage

1. Launch KeepClam — a status indicator appears in the menu bar (`○ KeepClam` off, `● KeepClam` on).
2. Click **开启合盖运行** (keep running with lid closed). On first use, install the sudoers whitelist as above.
3. Optional: pick an auto-stop timer, a battery floor, and your language under **Settings**.
4. Close the lid. Your tasks keep running.
5. The thermal guard runs during the session and outlives the app if it quits; logs live in `~/Library/Logs/KeepClam/`.

Key events (thermal trigger, timer/battery/Low-Power-Mode auto-stop) are delivered as system notifications so you see them after reopening the lid.

## Emergency restore

If anything ever goes wrong, one command restores factory sleep behavior:

```sh
sudo pmset -a disablesleep 0     # then verify:
pmset -g | grep SleepDisabled    # expect no "SleepDisabled 1"
```

## Safety

- Use at your own risk. `disablesleep` is a global power setting macOS does not expose in System Settings; re-test after major macOS upgrades.
- The thermal guard is software best-effort — it reads Apple's official thermal-pressure levels, not Celsius. Do not put a running closed MacBook in a bag; keep it ventilated.

## FAQ

**Why not Celsius temperatures?** Apple Silicon exposes no stable, unified CPU temperature API to unprivileged apps. KeepClam uses `NSProcessInfo.thermalState` (nominal/fair/serious/critical) — the same signal macOS itself throttles on.

**What if the guard itself dies?** The app notices within one refresh cycle, logs `guard_missing`, notifies you, and immediately attempts to restore sleep itself through the same passwordless whitelist — with a follow-up notification if that fails. The guard is a plain user process: the same user could kill it, which is an accepted trade-off for a personal tool (all comparable tools make it).

**Does the timer survive an app crash?** If the app dies, the guard's parent-death check restores sleep within one cycle — a stricter auto-stop than any timer.

## Development

```sh
zsh scripts/build-native.command        # build the app
clang -fobjc-arc -framework Cocoa -framework IOKit -framework UserNotifications -framework ServiceManagement \
      Sources/LogTests.m -o build/LogTests && ./build/LogTests   # run tests
```

Single-file Objective-C/AppKit, no Xcode project, no dependencies. CI builds and tests on every push; releases are tagged with SHA-256 checksums.

## License

[MIT](LICENSE)
