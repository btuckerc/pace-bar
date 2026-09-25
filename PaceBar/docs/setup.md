# Setup

Open Pace Bar from Applications, click its menu bar icon, then the gear. Settings has three panes in its toolbar: **Accounts**, **Hosts**, and **General**. They save to `~/.config/pace-bar/config.json`; this file contains paths and preferences, not credentials. Launch at login is optional. **Menu bar icon** (General) switches between Bars (one bar per tracked account, Codex then Claude) and Orbit (one ring per provider, split into an arc per account).

## Accounts

The Accounts tab lists the Codex and Claude subscriptions Pace Bar tracks, in order. Each row shows the account's name and its email and plan as the provider reports it; hover for where the sign-in lives. The **⋯** menu renames, pauses or resumes tracking, and removes the account.

**Remove** only stops tracking in Pace Bar. The sign-in and its history stay where they are. Names are never recycled: after removing Codex 3 and Codex 4, Codex 1 and Codex 2 keep their names and the next account you add is Codex 5. Removed and paused accounts are left out of the Codex pool forecast.

### Add an account

**Add Codex account…** or **Add Claude account…** opens one sheet:

- **On this Mac** lists sign-ins Pace Bar found but does not track, including accounts you removed (shown with their previous name). **Add** tracks it; a removed account comes back with its old name and history. Pace Bar never adds anything on its own.
- **Sign In with ChatGPT…** creates a private Codex folder for the new account (`~/.codex-pace-<id>`) and runs `codex login` there with file-based credential storage, so macOS Keychain is never used. Your browser opens; when you finish, the sheet shows the account's email and plan and **Add** tracks it. **Command** shows exactly what runs. Cancel stops the sign-in without adding anything. Signing in to an account Pace Bar already tracks updates that account instead of adding a duplicate.
- **Choose auth.json…** tracks an `auth.json` another tool already maintains. Pace Bar reads it and never rewrites it.
- **Sign In with Claude…** runs `omp login anthropic` with OMP (install [oh-my-pi](https://github.com/can1357/oh-my-pi) first). If OMP asks for a code, paste it into the sheet. Pace Bar then rereads OMP's sign-ins from `~/.omp/agent/agent.db` (read-only) and lists the new account with **Add**. Removing a Claude account never signs it out of OMP.

Pace Bar needs the `codex` or `omp` command installed (it looks in `~/.local/share/mise/shims`, `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`) and says so if it is missing. For a Codex account whose folder Pace Bar created, **⋯ › Remove and Sign Out…** also signs that folder out; other Codex sign-ins are never touched.

Existing Usage Bar setups carry over: the four Codex accounts and Claude 1 keep their names and history.

Expired credentials must be renewed in the app that created them. Pace Bar never refreshes or rewrites them. Subscription quotas come from an undocumented service endpoint, so provider changes can affect availability.

Estimates need at least two completed active days of observed history. Existing T3 users can optionally [import attributable history](reference.md#backfill-existing-t3-history). A missing estimate does not change the live quota reading.

## OpenRouter

OpenRouter also lives on the Accounts tab. It uses one API key file, by default OpenCode's `~/.local/share/opencode/auth.json`; **Choose…** points it at another private file containing an `apiKey` field (or OpenCode's nested `openrouter` API entry). Keep that file outside this repository and readable only by your user.

Balance and total spent come from the account credits endpoint. They cover OpenRouter credits, not bills from external BYOK providers.

## Local inference

The **Hosts** pane lists your llama-server hosts; each gets its own popover section. **Add Host…** asks for a name and the server origin, such as `http://inference-host:8080`, then opens **Check Setup**. Existing Usage Bar setups start with one host named “nous.” Enable llama-server's metrics endpoint (`--metrics`). The app reads `/v1/models` and `/metrics`; it does not generate tokens or load models. Output, input, and cache totals are collected for observed model counters, scoped to each host's server origin, and retained across app restarts in `~/.local/share/pace-bar/nous-history.json`. Totals start with the currently available process counters, preserve known resets, and cannot recover prior ended-process usage, models loaded and unloaded between polls, or resets that were not observed.

**Check Setup…** connects with your existing SSH alias (no passwords or host-key prompts), checks each requirement, and lists what passes. If the host API collector is missing or out of date, it shows the steps it would run, with the exact commands under **Commands**; nothing changes until you click **Run Setup**. It installs only Pace Bar's collector and its user service, verifies the result, and rolls back its own changes if a step fails. It never touches the inference server.

For CPU, GPU, memory, and power readings, choose either:

- **Metrics URL:** install the [optional host API](../host/README.md) and reach it over your private network, such as Tailscale.
- **SSH:** leave Metrics URL blank and supply an SSH host alias with existing noninteractive access. Host-key verification remains enabled.

Host telemetry targets Linux. The host API supports NVIDIA/NVML and AMD/amdgpu; SSH mode remains NVIDIA-only. Unsupported or power-suspended GPU fields remain unavailable and recover when sensors return. Disable host utilization in Settings if you only want inference counters. Keep inference and metrics endpoints private.

The electricity rate is optional, in USD/kWh. The app automatically retains recorded GPU energy and counter baselines in its existing per-host history across app restarts and observed counter resets. NVIDIA starts with the available driver-lifetime counter. AMD energy is labeled as a sampled estimate, also persisted on the host across restarts. Missing intervals and unobserved history cannot be reconstructed. Neither measures whole-computer electricity. The [host API guide](../host/README.md) documents boot recovery and checkpoint limits.

## Updates and removal

To update, pull the latest source and run `make -C PaceBar install`. It quits the running app, builds and installs the new one, and relaunches it; do this after every change so the running app is never an old build.

To remove it, quit the app and delete it from Applications. Settings and history live in `~/.config/pace-bar/` and `~/.local/share/pace-bar/`; remove those directories if you no longer want them. Existing provider sign-ins are separate and remain untouched. If installed, [remove the optional host service](../host/README.md) separately.

### Coming from Usage Bar

Pace Bar is Usage Bar renamed. On first launch it quits Usage Bar if it is running and copies `~/.config/usage-bar/`, `~/.local/share/usage-bar/`, and `~/Library/Caches/usage-bar/` to their `pace-bar` equivalents, so settings, history, and API-cost archives carry over. A folder that already exists under the new name is kept as is. The old folders are left untouched as a backup; delete them yourself once Pace Bar looks right. If the copy fails, Pace Bar says why and quits without changing anything.

Then delete **Usage Bar.app** from Applications. Launch at login is tied to the app, so turn it off in Usage Bar's Settings before deleting it (or remove Usage Bar under System Settings › General › Login Items), then turn it on again in Pace Bar. If you run the host service, [rename it](../host/README.md#renaming-from-usage-bar) too.
