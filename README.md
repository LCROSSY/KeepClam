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
- 🔋 **Auto-stop** — optional timer (1 / 2 / 4 h / ∞, or custom 1 min–24 h), battery floor (10 / 20 / 30 %, or custom 5–95 %, default 20 %), Low Power Mode yield, and a stop after 3 consecutive unreadable battery reads. All checks run in the guard, so a stuck menu cannot suspend them; with the lid closed, an auto-stop also requests immediate sleep (restoring the flag alone does not put a closed Mac to sleep).
- 🖥️ **Screen off when closed** — without an external display, macOS turns the internal panel off on lid close (`Display is turned off` in `pmset -g log`); KeepClam does not touch the display.
- 👁️ **The menu bar never lies** — state is read back from the kernel every refresh; externally-enabled states are detected and labeled.
- 📜 **Session logs** — run-length-encoded samples of lid state, network reachability, and thermal state, so you can answer "what happened last night while the lid was closed?"
- 🌐 **Bilingual UI** — Simplified Chinese / English, switched in-app without relaunch.

## Install

**Requirements:** macOS 13+ (universal binary; Apple Silicon tested, Intel untested).

### Free installer (recommended)

No Xcode or Homebrew is needed. Run in Terminal:

```sh
curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/LCROSSY/KeepClam/main/scripts/install.sh | bash
```

This runs the script directly and leaves no file behind. It downloads a complete release, including preview releases, and verifies the ZIP and app integrity. If the GitHub API is rate-limited, it falls back to the release feed. It then shows the version, source and installation path; press Enter (or `y`) to install, or anything else to cancel. Files downloaded this way carry no quarantine attribute, so there is no separate trust choice. Add `--yes` to confirm without a prompt when no terminal is available.

The default location is `/Applications`, falling back to `~/Applications` if it is not writable. The installer opens the menu-bar app when finished. Run the installer again to update, after stopping the lid-closed session and quitting the old app. If KeepClam was installed with Homebrew, the installer stops and asks you to run `brew upgrade --cask keepclam` instead.

The output language follows your system language; add `--language zh` or `--language en` to override it. To select a version, use a personal applications directory, or defer launching, pass options after `bash -s --`:

```sh
curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/LCROSSY/KeepClam/main/scripts/install.sh | bash -s -- --version 0.2.1 --app-dir "$HOME/Applications" --no-open
```

Current releases are ad-hoc signed and have not been notarized by Apple. Choosing to install and trust the app expresses your own trust; checksum verification detects damaged downloads and does not provide Apple notarization. Before unattended lid-closed use, configure passwordless authorization from the app menu separately.

### Install downloaded files (offline)

New releases include `install.sh`. For earlier releases, download [scripts/install.sh](scripts/install.sh) from this repository. Place the script, `KeepClam-<version>.zip` and `SHA256SUMS` in the same directory and run there:

```sh
shasum -a 256 -c --ignore-missing SHA256SUMS && bash install.sh --local .
```

ZIP files downloaded in a browser carry a quarantine attribute, so offline installation asks you to choose how to trust it: enter **1** to install and trust KeepClam (removing only this app's quarantine attribute, so it can usually open directly), enter **2** to install without removing quarantine, or press Enter to cancel. Without a terminal, pass `--trust` or `--keep-quarantine`. Use `--version` if the directory contains multiple releases. Run `bash install.sh --help` for all options.

### Homebrew

```sh
brew install --cask LCROSSY/tap/keepclam
```

To update later, run `brew update` followed by `brew upgrade --cask keepclam`.

### First launch

If macOS blocks a Homebrew or manually extracted installation, first verify that you trust its source. After attempting to open it, go to **System Settings → Privacy & Security → Open Anyway**, then confirm the prompt. See [Apple's instructions](https://support.apple.com/en-us/102445).

Alternatively, remove only the installed KeepClam app's quarantine attribute in Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/KeepClam.app"
```

For a personal installation, use `"$HOME/Applications/KeepClam.app"` instead. This does not notarize the app.

### Manual installation

Download `KeepClam-<version>.zip` and `SHA256SUMS` from [Releases](https://github.com/LCROSSY/KeepClam/releases). Place them in the same directory, run `shasum -a 256 -c --ignore-missing SHA256SUMS` (newer releases also list `install.sh` there), then unzip and move **KeepClam.app** to `/Applications`.

### Build from source

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

Before replacing an existing copy, stop the session and quit the running app.

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

**Does the timer survive an app crash?** Yes. The timer, battery floor and Low Power Mode checks all run in the guard; if the app dies, the guard's parent-death check also restores sleep within one cycle.

## Development

```sh
zsh scripts/build-native.command        # build the app
clang -fobjc-arc -framework Cocoa -framework IOKit -framework UserNotifications -framework ServiceManagement \
      Sources/LogTests.m -o build/LogTests && ./build/LogTests   # run tests
python3 scripts/test-install.py          # check installation and updates in temporary directories
```

Single-file Objective-C/AppKit, no Xcode project, no dependencies. CI builds and checks both app behavior and the installer on every push; releases include the installer and SHA-256 checksums for the ZIP and script.

## License

[MIT](LICENSE)
