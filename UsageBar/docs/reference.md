# How Usage Bar works

Implementation details and limits of the displayed metrics. Commands on this page run from `UsageBar/`.

## Interface

The popover fits its contents without scrolling or a fixed height. One row per Codex identity, with independent remaining-quota meters, percentages, and compact reset intervals. The server determines available windows; a missing five-hour window is not invented. Exact resets, freshness, and error details are available on hover. Failed or stale account readings are dimmed and marked; errors never become zero usage. OpenRouter shows account-wide balance and lifetime spend with equal visual weight. Total spend is blurred until clicked, can be hidden again with another click, and hides when the popover closes. The hidden view uses a fixed placeholder and does not expose the amount to accessibility. Nous shows model, token counters, generation rate, GPU/CPU meters, power, memory, GPU energy, and estimated GPU cost. Queue counts appear only when nonzero.

The 18-point menu glyph has four upright quota meters, ordered primary, secondary, last, btc. Each shows the most constrained ordinary Codex allowance, in twelve small height steps; model-specific allowances are excluded. An empty meter keeps a thin baseline. Broken tracks mean unavailable data, including stale, paused, and sleeping states. The tooltip and accessibility label retain the current percentages even when a change is too small to move a pixel. The image updates only when those visible steps change, reusing existing refresh work. No animation, extra timer, network request, or chart framework is involved.

We compared [three icon directions](images/icon-study.png) at menu-bar size: upright meters, interrupted horizontal rails, and separated arcs. The meters retained distinct account values; the other shapes suggested sliders or a loading indicator.

Design references: Apple's [interface icon guidance](https://developer.apple.com/design/human-interface-guidelines/icons) supports simplified shapes, consistent stroke weight, and optical alignment. Its [chart guidance](https://developer.apple.com/design/human-interface-guidelines/charts) informed retaining explicit numeric values and context alongside meters. The implementation uses small native geometry instead of a chart framework. Account handling was informed by [CodexBar's account-scoping design](https://github.com/steipete/CodexBar/blob/main/docs/codex.md).

## Accounts and data fidelity

- Reads the configured Codex auth file (default `~/.codex/auth.json`) and existing `~/.codex-t3/*/auth.json` / `~/.codex-gui/*/auth.json` homes. Deduplicates `tokens.account_id`, selecting the most recently modified credential file for duplicate identities. Each request has that account's bearer token and `ChatGPT-Account-Id`; returned account IDs are checked when supplied. Display names come from home aliases: primary, secondary, last, btc, in that order. Emails and account IDs are never rendered, including in tooltips. Credentials are never copied, refreshed, logged, or written. Expired sign-ins must be renewed in their owning Codex application.
- Read-only `GET https://chatgpt.com/backend-api/wham/usage` supplies subscription windows/resets. This is an undocumented service endpoint and can change. No API spend estimate or local token count is substituted for subscription quota.
- OpenRouter reads an existing OpenCode API credential file (`~/.local/share/opencode/auth.json`) or a file containing `{"apiKey":"..."}`. `/api/v1/credits` supplies account-wide balance and lifetime credit spend. Key-specific period figures can be zero while other keys are active, so they are not presented as account spending. External BYOK provider bills are not included.
- Nous defaults to `http://nous:8080` over the existing private network. `/v1/models` selects only an already-loaded model, then `/metrics?model=...` reads its counters. No model is loaded or switched. Counters reset with model process lifetime. Input excludes cache; output is separate. The t/s field is the server's rate gauge, not an end-to-end latency or TTFT measurement. TTFT is not exposed by this host's metrics, so no fabricated value is shown.
- The optional [host API](../host/README.md) supplies utilization and cumulative GPU energy through the existing private network. Set `nousMetricsURL` to use it. With no metrics URL, optional `ssh nous` collects NVIDIA utilization/VRAM/power, `free -m`, and `/proc/stat`. CPU is the delta between samples; GPU power is not whole-host power. This needs existing noninteractive SSH access, with strict host verification and no agent forwarding. The SSH mode installs no host service. HTTP mode uses the small optional user service documented above.

## Cost and behavior

Cloud polls every five minutes (up to four Codex requests plus one OpenRouter request). Nous polls every minute (two inference HTTP requests plus one host HTTP request, or one short SSH command when the metrics URL is unset). Low Power Mode or serious/critical thermal state reduces these to fifteen and five minutes. One tolerant minute timer schedules work; the popover view is released when closed. Pause stops scheduling, sleep cancels refresh tasks, and resume refreshes. HTTP responses and SSH output are bounded; connections have timeouts. A running SSH sample may finish its bounded timeout after pause.

A local release sample on September 19, 2026 measured a 728 KB app bundle and 13.3 MB physical footprint (13.8 MB peak), with 0.0% CPU in an idle `ps` sample after startup. This is a brief local measurement, not a battery-life benchmark.

`electricityUSDPerKWh` is an optional numeric setting. GPU Wh and average watts use hardware counter deltas since monitoring began, not integration of sparse instantaneous readings. Energy starts after two samples and resets with app/configuration reload or detected hardware counter reset. The rate has no location metadata and is not committed.

Nonsecret settings live in `~/.config/usage-bar/config.json`, created only when saved. Quota history is a small local JSON file. There is no telemetry, cookie scraping, credential-refresh service, or updater.

## Validation

`make test` uses synthetic data and temporary files only. Account tests cover four distinct identities, duplicate sign-ins, most-recent credential selection, and malformed credentials. Parser tests cover quota windows, optional endpoint failures, separate billing scopes, model selection, and host counters.

`swift run UsageBarProbe` explicitly performs live read-only validation and prints only capability counts, not tokens, emails, account IDs, or raw bodies. `swift run UsageBar --render-preview /tmp/usage-bar.png` renders a synthetic panel without network requests. Root CodexBar tests remain upstream's separate suite.

## Codex runway forecast

The main bars form one ordered runway: **primary → secondary → last → btc**. A compact `≈ Now → Mon 3:15 PM` or `≈ Mon → Tue 8:00 AM` shows first projected use and depletion. `↻` means the estimate includes a scheduled refill. Percentages and bar fills always show the actual current balances; a zero balance can have a future range if its known reset happens before its turn. Exact dates and the assumptions are available on hover. Normal status dots are omitted; stale/error indicators remain.

The top-right `0 resets` is the sum of available **banked reset credits**, from `rate_limit_reset_credits.available_count` in the existing usage requests. It does not count scheduled renewals, add network polling, or redeem credits. Missing/stale account counts produce `— resets`, never a fabricated zero. The count is authoritative even when a details list is incomplete ([official account/reset documentation](https://learn.chatgpt.com/docs/app-server)).

The pace comes from the past 30 **completed local calendar days**. For each date, sum the tier-weighted consumption across accounts; then average over dates with activity. A date used on two accounts counts once. Today is excluded, as are idle dates. At least two active dates are required. Historical account/lane records remain separate on disk, allowing this calculation without rescanning logs.

Balances and historical consumption are converted to a common nominal capacity: Pro 20x = 1, Pro 5x = 0.25, Plus = 0.05. Thus 100% of a Pro 5x allowance contributes one quarter of a Pro 20x allowance. Labels follow [CodexBar's provider mapping](../../Sources/CodexBarCore/Providers/Codex/CodexPlanFormatting.swift); relative tier sizes follow [official pricing](https://learn.chatgpt.com/docs/pricing). These are approximate nominal plan weights, not an exact billing conversion or a measurement of model-specific promotional limits. Unknown plans or simultaneous layered main quotas suppress the shared estimate rather than assume equal capacities.

The simulation spends the common historical daily rate on the first account with capacity. Reported resets restore that account's tier-weighted capacity; an earlier account's refill can interrupt a later account, extending the later account's date. If everything is empty, the schedule waits for a known reset. Earlier spending from a queued account reduces its refreshed balance and changes the next calculation. The app does not switch accounts or infer session routing: `Now` is the starting point of this conditional schedule.

Only the currently reported reset per account is simulated. The horizon stops before a second, unreported refill could occur, capped at 30 days. `Through Thu` means the account lasts through that horizon; `Later` means it has no turn within it. Future banked-reset grants and redemption are not predicted. Days ahead are assumed active. A small bounded event loop and at most 31 daily values per account are all that is needed; there are no additional requests, timers, or background scans.

The service's `gpt-reserve` additional bucket is a smaller-model fallback (`normal_model_slug` identifies Luna in the observed response; the upsell says the advanced models remain capped). The former generic “Reserve” row misleadingly suggested another general allowance. This bucket is omitted from both the main UI and shared runway. No inference request is sent to test access to it.

History records positive quota deltas from existing refreshes. The first reading is a baseline, not newly consumed quota. Scheduled and banked resets preserve past daily totals and establish a new baseline. Corrections within a cycle use a high-water mark to prevent double counting. Deltas spanning midnight are omitted rather than assigned to an invented day. No unobserved consumption or refills are fabricated; usage during app downtime and around resets may be missed, making the estimate optimistic. This is observed active-day consumption, not an exact provider billing ledger.

Compact history is retained across launches and settings changes in `~/.local/share/usage-bar/quota-history.json` (owner-only permissions, hashed account/lane keys, no credentials, emails, or transcripts). At most 128 lanes and 31 daily totals per lane are retained; a small atomic save runs off the UI actor once per existing Codex refresh. There are no extra requests, timers, filesystem scans, model calls, or inference costs. Shared Codex logs do not identify accounts directly, but T3's retained session cursors and imported-transcript mappings can attribute historical quota snapshots. A one-time maintenance import can use those mappings; normal app operation never scans logs. Shared estimates need attributable history across at least two active dates.

### Backfill existing T3 history

Quit Usage Bar before importing so its in-memory history cannot overwrite the import. From `UsageBar/`:

```sh
history_dir=$(mktemp -d)
python3 scripts/quota_backfill.py --output "$history_dir/quota.json"
swift run UsageBarProbe --import-history "$history_dir/quota.json"
rm "$history_dir/quota.json"
rmdir "$history_dir"
open "$HOME/Applications/Usage Bar.app"
```

The extractor reads T3's database read-only, maps provider instances through their configured auth homes, and reads the last 30 days of Codex quota metadata. Unmapped or conflicting sessions, copied pre-fork history, unrelated model lanes, and contradictory quota-cycle ownership are excluded. Child sessions inherit an unambiguous parent's mapping. Source files and identical snapshots are deduplicated. The temporary file contains quota metadata and account IDs with owner-only permissions; it has no tokens, emails, or conversation text. It is removed after import.

The importer checks each account against a fresh quota response, requires the same plan, and matches quota duration rather than primary/secondary field position. Reset timestamps within 60 seconds are treated as one cycle to tolerate provider timestamp jitter. Daily overlaps use the larger observed total rather than adding duplicate consumption; repeating an import is safe. Current live baselines are preserved. This recovers observed quota consumption, not a complete billing ledger; unresolved history is omitted and account-slot sign-in changes outside retained metadata may limit attribution. Reserve is not inferred from another model's allowance.
