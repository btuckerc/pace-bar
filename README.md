# Usage Bar

Codex, local inference, and OpenRouter in one quiet macOS menu bar.

<picture>
  <img src="UsageBar/docs/images/usage-bar.png" width="390" alt="Usage Bar showing four named Codex accounts with quota meters and estimated depletion dates, local inference and GPU metrics, and OpenRouter credit balance. All values are sample data.">
</picture>

**[Setup](UsageBar/docs/setup.md)** · **[How it works](UsageBar/docs/reference.md)** · **[Contributing](CONTRIBUTING.md)**

- **Codex:** separate account quotas, reset credits, and a shared usage runway.
- **Local inference:** llama-server token counts and speed, plus optional GPU, memory, and energy readings.
- **OpenRouter:** account balance and click-to-reveal total credit spend.

Built with SwiftUI and AppKit. No third-party runtime dependencies, web views, or analytics. Cloud usage refreshes every five minutes; host metrics every minute. Sampling slows down in Low Power Mode.

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

This is an early, source-built app. Local builds are ad-hoc signed; there is no notarized release or automatic updater yet.

## A few details

Usage Bar reads existing sign-ins without modifying them. Account names are nicknames, and credentials stay in their original files. A small local history file powers the estimates; no usage data is sent to the project.

The runway assumes you use accounts in order, at your average pace over active days in the last 30 days. It includes known resets. It is an estimate, not an account switcher. GPU energy is GPU-only, and local inference counters reset when the model process restarts. [Details and limitations →](UsageBar/docs/reference.md)

## Credit

A focused fork of [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger and contributors. The standalone app lives in [`UsageBar/`](UsageBar/); the original source remains alongside it. The preview above is rendered by Usage Bar with synthetic data.

[MIT license](LICENSE).
