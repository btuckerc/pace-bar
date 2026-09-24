# Setup

Open Usage Bar from Applications, click its menu bar icon, then the gear. Settings save to `~/.config/usage-bar/config.json`; this file contains paths and preferences, not credentials. Launch at login is optional. **Menu bar icon** switches between Bars (Codex 1–4 and Claude) and Orbit (the four Codex arcs of the app icon).

## Codex

Sign in through Codex first. Usage Bar reads `~/.codex/auth.json` by default, plus existing auth files in `~/.codex-t3/*/` and `~/.codex-gui/*/`. You can change the primary auth-file path in Settings.

Codex accounts appear as rings named **Codex 1, Codex 2, Codex 3, Codex 4**. These names come from the auth-home aliases (the configured home, then `second`, `last`, `btc`); repeated sign-ins to the same account appear only once. General account naming and reordering are not configurable yet.

A Claude ring appears after you sign in to Claude in OMP (`/login` → Anthropic). Usage Bar reads that sign-in from `~/.omp/agent/agent.db` without changing it.

Expired credentials must be renewed in the app that created them. Usage Bar never refreshes or rewrites them. Subscription quotas come from an undocumented service endpoint, so provider changes can affect availability.

Estimates need at least two completed active days of observed history. Existing T3 users can optionally [import attributable history](reference.md#backfill-existing-t3-history). A missing estimate does not change the live quota reading.

## OpenRouter

The default credential path is OpenCode's `~/.local/share/opencode/auth.json`. Alternatively, point Settings at a private file containing an `apiKey` field (or OpenCode's nested `openrouter` API entry). Keep that file outside this repository and readable only by your user.

Balance and total spent come from the account credits endpoint. They cover OpenRouter credits, not bills from external BYOK providers.

## Local inference

Set **Nous URL** to your llama-server origin, such as `http://inference-host:8080`. The section is currently named “nous,” after the original host; the address is configurable. Enable llama-server's metrics endpoint (`--metrics`). The app reads `/v1/models` and `/metrics`; it does not generate tokens or load models. Output, input, and cache totals are collected for observed model counters, scoped to the Nous URL, and retained across app restarts in `~/.local/share/usage-bar/nous-history.json`. Totals start with the currently available process counters, preserve known resets, and cannot recover prior ended-process usage, models loaded and unloaded between polls, or resets that were not observed.

For CPU, GPU, memory, and power readings, choose either:

- **Metrics URL:** install the [optional host API](../host/README.md) and reach it over your private network, such as Tailscale.
- **SSH:** leave Metrics URL blank and supply an SSH host alias with existing noninteractive access. Host-key verification remains enabled.

Host telemetry targets Linux. The host API supports NVIDIA/NVML and AMD/amdgpu; SSH mode remains NVIDIA-only. Unsupported or power-suspended GPU fields remain unavailable and recover when sensors return. Disable host utilization in Settings if you only want inference counters. Keep inference and metrics endpoints private.

The electricity rate is optional, in USD/kWh. The app automatically retains recorded GPU energy and counter baselines in its existing per-host history across app restarts and observed counter resets. NVIDIA starts with the available driver-lifetime counter. AMD energy is labeled as a sampled estimate, also persisted on the host across restarts. Missing intervals and unobserved history cannot be reconstructed. Neither measures whole-computer electricity. The [host API guide](../host/README.md) documents boot recovery and checkpoint limits.

## Updates and removal

To update, pull the latest source and run `make -C UsageBar install`. It quits the running app, builds and installs the new one, and relaunches it; do this after every change so the running app is never an old build.

To remove it, quit the app and delete it from Applications. Settings and history live in `~/.config/usage-bar/` and `~/.local/share/usage-bar/`; remove those directories if you no longer want them. Existing provider sign-ins are separate and remain untouched. If installed, [remove the optional host service](../host/README.md) separately.
