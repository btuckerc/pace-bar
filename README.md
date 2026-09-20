# Usage Bar

Codex, local inference, and OpenRouter in one quiet macOS menu bar.

<picture>
  <img src="UsageBar/docs/images/usage-bar.png" width="390" alt="Usage Bar showing four named Codex accounts with quota meters and estimated depletion dates, local inference and GPU metrics, and OpenRouter credit balance. All values are sample data.">
</picture>

**[Download for Apple Silicon](https://github.com/btuckerc/usage-bar/releases/latest)** · **[Download source](https://github.com/btuckerc/usage-bar/archive/refs/heads/main.zip)** · **[Setup](UsageBar/docs/setup.md)** · **[How it works](UsageBar/docs/reference.md)** · **[Contributing](CONTRIBUTING.md)**

- **Codex:** separate account quotas, reset credits, a shared usage runway, and a blurred 30-day API-equivalent cost with automatic T3 history import.
- **Local inference:** llama-server token counts and speed, plus optional GPU, memory, and energy readings.
- **OpenRouter:** account balance and click-to-reveal lifetime credit spend, kept distinct from estimated API cost.

Built with SwiftUI and AppKit. No third-party runtime dependencies, web views, or analytics. Cloud usage refreshes every five minutes; host metrics every minute. Sampling slows down in Low Power Mode.

## Install the app

Download the Apple Silicon ZIP from [GitHub Releases](https://github.com/btuckerc/usage-bar/releases/latest), unzip it, and move **Usage Bar.app** to **Applications**. Requires macOS 14 or later.

The app is ad-hoc signed, not Developer ID–signed or notarized. macOS may block the first launch; after verifying the download source, use **System Settings → Privacy & Security → Open Anyway** if offered. There is no automatic updater; quit the app and replace it with a newer download to update.

## Install from source

Requires **macOS 14 or later** and **Xcode 26.2 or later** with Swift 6.2. Select Xcode as your active developer directory before building.

```sh
git clone https://github.com/btuckerc/usage-bar.git
cd usage-bar
make -C UsageBar package
mkdir -p "$HOME/Applications"
ditto "UsageBar/dist/Usage Bar.app" "$HOME/Applications/Usage Bar.app"
open "$HOME/Applications/Usage Bar.app"
```

Open the menu bar icon, then the gear to set credential paths and your inference host. See [setup](UsageBar/docs/setup.md) for supported account layouts and optional host monitoring.

Source builds are also ad-hoc signed. Intel Macs must build from source; the downloadable release is Apple Silicon only.

## A few details

Usage Bar reads existing sign-ins without modifying them. Account names are nicknames, and credentials stay in their original files. Local history powers the estimates; no usage data is sent to the project. On first use, T3's retained usage metadata is imported automatically. Subsequent scans read appended usage and preserve history even when source logs disappear.

The runway assumes you use accounts in order, at your average pace over active days in the last 30 days. It includes known resets. It is an estimate, not an account switcher. GPU energy is GPU-only, and local inference counters reset when the model process restarts. [Details and limitations →](UsageBar/docs/reference.md)

## Credit

A focused fork of [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger and contributors. The standalone app lives in [`UsageBar/`](UsageBar/); the original source remains alongside it. The preview above is rendered by Usage Bar with synthetic data.

[MIT license](LICENSE).
