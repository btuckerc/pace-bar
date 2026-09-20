# Usage Bar

A small native macOS menu-bar app for Codex subscriptions, OpenRouter account credit/spend, and a remote llama-server. Personal implementation within Tucker's [CodexBar fork](https://github.com/btuckerc/usage-bar/tree/personal-usage-bar); upstream code and MIT attribution are retained. The standalone target compiles only this directory, with no third-party dependencies.

```sh
cd UsageBar
make test check package
open 'dist/Usage Bar.app'
```

Requires macOS 14+, Swift 6.2 / Xcode. Local packaging uses ad-hoc signing; this is not a notarized public release. Install by copying the app to `~/Applications`. Updates are manual. Launch at login is optional in Settings.

## Interface

The popover fits its contents without scrolling or a fixed height. One row per Codex identity, with independent remaining-quota meters, percentages, and compact reset intervals. The server determines available windows; a missing five-hour window is not invented. Exact resets, freshness, and error details are available on hover. Failed or stale account readings are dimmed and marked; errors never become zero usage. OpenRouter shows account-wide balance and lifetime spend with equal visual weight. Nous shows model, token counters, generation rate, GPU/CPU meters, power, memory, GPU energy, and estimated GPU cost. Queue counts appear only when nonzero.

The menu glyph is a four-part aperture drawn natively at 18 points, using template coloring for system appearance. It is static. There are no animated charts, browser views, inference probes, or frame-rate timers.

Design references: Apple's [interface icon guidance](https://developer.apple.com/design/human-interface-guidelines/icons) supports simplified shapes, consistent stroke weight, and optical alignment. Its [chart guidance](https://developer.apple.com/design/human-interface-guidelines/charts) informed retaining explicit numeric values and context alongside meters. The implementation uses small native geometry instead of a chart framework. Account handling was informed by [CodexBar's account-scoping design](https://github.com/steipete/CodexBar/blob/main/docs/codex.md).

## Accounts and data fidelity

- Reads the configured Codex auth file (default `~/.codex/auth.json`) and existing `~/.codex-t3/*/auth.json` / `~/.codex-gui/*/auth.json` homes. Deduplicates `tokens.account_id`, selecting the most recently modified credential file for duplicate identities. Each request has that account's bearer token and `ChatGPT-Account-Id`; returned account IDs are checked when supplied. Display names come from home aliases: primary, secondary, last, btc, in that order. Emails and account IDs are never rendered, including in tooltips. Credentials are never copied, refreshed, logged, or written. Expired sign-ins must be renewed in their owning Codex application.
- Read-only `GET https://chatgpt.com/backend-api/wham/usage` supplies subscription windows/resets. This is an undocumented service endpoint and can change. No API spend estimate or local token count is substituted for subscription quota.
- OpenRouter reads an existing OpenCode API credential file (`~/.local/share/opencode/auth.json`) or a file containing `{"apiKey":"..."}`. `/api/v1/credits` supplies account-wide balance and lifetime credit spend. Key-specific period figures can be zero while other keys are active, so they are not presented as account spending. External BYOK provider bills are not included.
- Nous defaults to `http://nous:8080` over the existing private network. `/v1/models` selects only an already-loaded model, then `/metrics?model=...` reads its counters. No model is loaded or switched. Counters reset with model process lifetime. Input excludes cache; output is separate. The t/s field is the server's rate gauge, not an end-to-end latency or TTFT measurement. TTFT is not exposed by this host's metrics, so no fabricated value is shown.
- The optional [host API](host/README.md) supplies utilization and cumulative GPU energy through the existing private network. Set `nousMetricsURL` to use it. With no metrics URL, optional `ssh nous` collects NVIDIA utilization/VRAM/power, `free -m`, and `/proc/stat`. CPU is the delta between samples; GPU power is not whole-host power. This needs existing noninteractive SSH access, with strict host verification and no agent forwarding. The SSH mode installs no host service. HTTP mode uses the small optional user service documented above.

## Cost and behavior

Cloud polls every five minutes (four Codex requests plus one OpenRouter request). Nous polls every minute (two inference HTTP requests plus one host HTTP request, or one short SSH command when the metrics URL is unset). Low Power Mode or serious/critical thermal state reduces these to fifteen and five minutes. One tolerant minute timer schedules work; the popover view is released when closed. Pause stops scheduling, sleep cancels refresh tasks, and resume refreshes. HTTP responses and SSH output are bounded; connections have timeouts. A running SSH sample may finish its bounded timeout after pause.

A local release sample on September 19, 2026 measured a 728 KB app bundle and 13.3 MB physical footprint (13.8 MB peak), with 0.0% CPU in an idle `ps` sample after startup. This is a brief local measurement, not a battery-life benchmark.

`electricityUSDPerKWh` is an optional numeric setting. GPU Wh and average watts use hardware counter deltas since monitoring began, not integration of sparse instantaneous readings. Energy starts after two samples and resets with app/configuration reload or detected hardware counter reset. The rate has no location metadata and is not committed.

Nonsecret settings live in `~/.config/usage-bar/config.json`, created only when saved. No history database, telemetry, cookie scraping, credential-refresh service, or updater runs.

## Validation

`make test` uses synthetic data and temporary files only. Account tests cover four distinct identities, duplicate sign-ins, most-recent credential selection, and malformed credentials. Parser tests cover quota windows, optional endpoint failures, separate billing scopes, model selection, and host counters.

`swift run UsageBarProbe` explicitly performs live read-only validation and prints only capability counts, not tokens, emails, account IDs, or raw bodies. `swift run UsageBar --render-preview /tmp/usage-bar.png` renders a synthetic panel without network requests. The standalone package has its own CI workflow; root CodexBar tests remain upstream's separate suite.

## Codex runway forecast

The header replaces the static legend with `All capped ≈ …`, `Reset first · …`, or `Forecast —`. “All” means every currently reported quota window on every account, including reserve, exhausted simultaneously. It does not claim that reserve is interchangeable with general-model capacity, or that every model remains usable until all allowances are exhausted. Hover shows each lane's forecast and calculation basis.

Each lane uses percentage points per second from up to six hours of existing refresh samples once at least 30 minutes and one percentage point of change are observed. Otherwise it uses usage divided by elapsed time in the current quota window, provided at least 15 minutes and 3% of the window have elapsed. An already-capped lane is handled directly. Recent estimates include idle time; they are not an active-work-hours estimate. Counters dropping or reset timestamps changing clear that lane's sample history.

For each lane, projected time remaining is remaining percentage divided by its consumption rate. Exhaustion intervals end at that lane's actual reset. A combined date appears only when all intervals overlap before the earliest reported reset; otherwise the header shows that reset. Predictions do not extend across unobserved future resets. Stale, failed, or insufficiently mature snapshots suppress the combined forecast. This is conditional on the current account/model mix continuing: moving work between accounts can invalidate it. Unlike pooling percentages, it does not presume equal account capacities.

The history is in memory only, capped at 73 points per lane and 128 lanes, and discarded at app restart/settings reload. There are no new requests, timers, filesystem scans, model calls, or inference costs. T3's [pace implementation](https://github.com/pingdotgg/t3code/blob/main/packages/shared/src/usageLimits.ts) compares usage share with elapsed window share with a five-point tolerance; this forecast instead estimates individual exhaustion times and checks reset overlap. CodexBar's [pace model](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/UsagePace.swift) also informed the elapsed-window fallback and early-window guard.
