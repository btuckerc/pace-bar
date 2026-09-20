# How Usage Bar works

Implementation details and limits of the displayed metrics. Commands on this page run from `UsageBar/`.

## Interface

The popover fits its contents without scrolling or a fixed height. One row per Codex identity shows independent remaining-quota meters, percentages, and compact reset intervals. The server determines available windows; a missing five-hour window is not invented. Exact resets, freshness, and errors are available on hover. Failed or stale readings are dimmed and marked; errors never become zero usage. Below the accounts, **API equivalent · 30d** estimates recorded local token usage at API rates, explicitly labeled **Not billed spend**. OpenRouter shows account-wide balance and **Spent · lifetime**. Nous shows model, persistent observed lifetime token totals, generation rate, GPU/CPU meters, power, memory, GPU energy, and estimated GPU electricity cost. All cost amounts are blurred until clicked, can be hidden again, and hide when the popover closes. A fixed placeholder keeps concealed digits and their length out of both the view and accessibility tree.

The 18-point menu glyph is an Orbit of four separated rounded arc segments around an empty center, ordered primary at top, secondary at right, last at bottom, and btc at left, clockwise from 12 o'clock. Each segment shows the most constrained ordinary Codex allowance in twelve small fill steps; model-specific allowances are excluded. A zero balance keeps its dim intact track, while unavailable data uses a broken track. The tooltip and accessibility label retain the current percentages even when a change is too small to move a pixel. The image updates only when those visible steps change, reusing existing refresh work. No animation, extra timer, network request, or chart framework is involved.

We compared [three icon directions](images/icon-study.png) at menu-bar size: upright meters, interrupted horizontal rails, and separated arcs. The selected Orbit uses the separated arcs because it keeps four account values distinct while remaining a compact, quiet menu-bar mark.

Design references: Apple's [interface icon guidance](https://developer.apple.com/design/human-interface-guidelines/icons) supports simplified shapes, consistent stroke weight, and optical alignment. Its [chart guidance](https://developer.apple.com/design/human-interface-guidelines/charts) informed retaining explicit numeric values and context alongside meters. The implementation uses small native geometry instead of a chart framework. Account handling was informed by [CodexBar's account-scoping design](https://github.com/steipete/CodexBar/blob/main/docs/codex.md).

## Accounts and data fidelity

- Reads the configured Codex auth file (default `~/.codex/auth.json`) and existing `~/.codex-t3/*/auth.json` / `~/.codex-gui/*/auth.json` homes. Deduplicates `tokens.account_id`, selecting the most recently modified credential file for duplicate identities. Each request has that account's bearer token and `ChatGPT-Account-Id`; returned account IDs are checked when supplied. Display names come from home aliases: primary, secondary, last, btc, in that order. Emails and account IDs are never rendered, including in tooltips. Credentials are never copied, refreshed, logged, or written. Expired sign-ins must be renewed in their owning Codex application.
- Read-only `GET https://chatgpt.com/backend-api/wham/usage` supplies subscription windows/resets. This is an undocumented service endpoint and can change. No API spend estimate or local token count is substituted for subscription quota.
- OpenRouter reads an existing OpenCode API credential file (`~/.local/share/opencode/auth.json`) or a file containing `{"apiKey":"..."}`. `/api/v1/credits` supplies account-wide balance and lifetime credit spend. Key-specific period figures can be zero while other keys are active, so they are not presented as account spending. External BYOK provider bills are not included.
- Nous defaults to `http://nous:8080` over the existing private network. `/v1/models` selects only an already-loaded model, then `/metrics?model=...` reads its counters. No model is loaded or switched. Usage Bar collects observed lifetime totals by model and preserves them across app restarts in `~/.local/share/usage-bar/nous-history.json`; totals are scoped to the configured Nous origin. Input excludes cache; output is separate. The t/s field is the server's rate gauge, not an end-to-end latency or TTFT measurement. TTFT is not exposed by this host's metrics, so no fabricated value is shown. Totals begin with the currently available process counters, preserve known counter resets, and cannot recover prior ended-process usage, a model loaded and unloaded entirely between polls, or an unseen reset followed by larger counters.
- The optional [host API](../host/README.md) supplies utilization and cumulative GPU energy through the existing private network. Set `nousMetricsURL` to use it. With no metrics URL, optional `ssh nous` collects NVIDIA utilization/VRAM/power, `free -m`, and `/proc/stat`. CPU is the delta between samples; GPU power is not whole-host power. This needs existing noninteractive SSH access, with strict host verification and no agent forwarding. The SSH mode installs no host service. HTTP mode uses the small optional user service documented above.

## Cost and behavior

Cloud polls every five minutes (up to four Codex requests plus one OpenRouter request). Nous polls every minute (two inference HTTP requests plus one host HTTP request, or one short SSH command when the metrics URL is unset). Low Power Mode or serious/critical thermal state reduces these to fifteen and five minutes. One tolerant minute timer schedules work; the popover view is released when closed. Pause stops scheduling, sleep cancels refresh tasks, and resume refreshes. HTTP responses and SSH output are bounded; connections have timeouts. A running SSH sample may finish its bounded timeout after pause.

A local release sample on September 19, 2026, before token-cost history was added, measured a 728 KB app bundle and 13.3 MB physical footprint (13.8 MB peak), with 0.0% CPU in an idle `ps` sample. This is an earlier brief measurement, not a current resource or battery-life benchmark.

`electricityUSDPerKWh` is an optional numeric setting. GPU Wh and average watts use hardware counter deltas since monitoring began, not integration of sparse instantaneous readings. Energy starts after two samples and resets with app/configuration reload or detected hardware counter reset. The rate has no location metadata and is not committed.

Nonsecret settings live in `~/.config/usage-bar/config.json`, created only when saved. Quota history and Nous lifetime totals are small local JSON files. There is no telemetry, cookie scraping, credential-refresh service, or updater.

### API-equivalent cost and automatic T3 history import

The Codex figure follows [T3's usage calculation](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/usage/usagePricing.ts): uncached input × input price + cached input × cache-read price + cache creation × cache-write price + output × output price. Reasoning tokens are already included in output. It is a hypothetical API-price estimate, **not** your subscription bill, savings, quota consumption, or a forecast. The value has no approximation prefix; **\* Not billed spend** appears beneath it on the left. Missing models remain unpriced; incomplete history/pricing and excluded-record counts are explained in the tooltip. Unavailable costs display **—**, never a fabricated zero.

The [30-day window](https://github.com/pingdotgg/t3code/blob/main/packages/shared/src/usageFormat.ts) matches T3: today plus the preceding 29 calendar days in the Mac's time zone, including daylight-saving transitions. It is not a calendar billing month or a rolling 720 hours. To compare amounts, select the same 30-day range and local environment in T3. T3 can merge other connected machines; Usage Bar does not invent their usage or access their authenticated services.

Onboarding automatically reads `~/.t3/userdata/usage-scan-cache.json` and imports **all retained usage rows**, including rows older than the displayed window. The independent, compact, owner-only archive is `~/.local/share/usage-bar/codex-cost-history.json`. No prompts, responses, auth files, or credentials are copied. Missing original transcripts do not erase imported history, and a restart does not require T3 or another manual migration. Changed T3 snapshots merge automatically without double-counting copies.

The [T3 v3 cache](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/usage/usageScanCache.ts) supplies per-file offsets, reducer state, and guard hashes. After bootstrap, unchanged files reuse cached rows and growing files read only appended bytes after verifying the 64-byte FNV-1a guard. A changed guard causes a fresh parse; unfinished tail records remain separate until their line is completed. Copied/forked sessions use T3's suppression and cross-file occurrence-deduplication rules. All imported provider metadata is preserved, but the Codex row sums only Codex—not Claude, Grok, local GPU electricity, or OpenRouter credit spend.

Sources include the configured Codex auth file's home, `~/.codex`, `~/.codex-t3/*`, `~/.codex-gui/*`, and T3's configured shared Codex homes. Only usage metadata from `sessions` and `archived_sessions` is retained. Auth overlays sharing a sessions directory are scanned once. Work runs off the UI actor at the existing cloud refresh cadence. Cold scans checkpoint after a bounded amount of work and show partial coverage until caught up; successful imported history is saved before live scanning begins.

When present, `~/.t3/userdata/usage-model-rates.json` and `settings.json` supply the same saved LiteLLM catalog and exact custom price overrides used by T3. Without T3's catalog, a public LiteLLM request runs at most daily with a dated local cache in `~/Library/Caches/usage-bar/litellm-pricing.json`; only the public catalog is downloaded, and no usage is uploaded. Rates use T3's base tier rather than guessing priority, flex, batch, or long-context billing. The tooltip identifies the pricing date; changes in list prices or overrides can change historical estimates.

OpenRouter's `/credits` endpoint is lifetime credit spend, not trailing-30-day account activity. It stays explicitly labeled as actual lifetime spend. Local inference has no universal hosted equivalent: its optional GPU electricity estimate remains separate and covers only the monitoring session.

## Validation

`make test` uses synthetic data and temporary files only. Coverage includes account separation, quotas, history migration/restart, deleted source retention, copied and forked logs, guarded incremental scanning and unfinished tails, T3 pricing/overrides, unknown prices, and calendar-day/DST boundaries.

`swift run UsageBarProbe` explicitly performs live read-only validation and prints only capability counts, not tokens, emails, account IDs, or raw bodies. `swift run UsageBar --render-preview /tmp/usage-bar.png` renders a synthetic panel without network requests. Root CodexBar tests remain upstream's separate suite.

`swift run UsageBarProbe --import-cost-history /tmp/usage-bar-cost-report.json` exercises the same automatic migration and catches up local scans without account probes or Keychain access. It creates an owner-only reconciliation report containing aggregate model tokens and estimated cost, not transcripts or identities; it refuses to overwrite an existing report. Normal onboarding does not require this diagnostic command. Remove the report after comparison.

## Codex runway forecast

The main bars form one ordered runway: **primary → secondary → last → btc**. A compact `≈ Now → Mon 3:15 PM` or `≈ Mon → Tue 8:00 AM` shows first projected use and depletion. `↻` means the estimate includes a scheduled refill. Percentages and bar fills always show the actual current balances; a zero balance can have a future range if its known reset happens before its turn. Exact dates and the assumptions are available on hover. Normal status dots are omitted; stale/error indicators remain.

The top-right `0 resets` is the sum of available **banked reset credits**, from `rate_limit_reset_credits.available_count` in the existing usage requests. It does not count scheduled renewals, add network polling, or redeem credits. Missing/stale account counts produce `— resets`, never a fabricated zero. The count is authoritative even when a details list is incomplete ([official account/reset documentation](https://learn.chatgpt.com/docs/app-server)).

The pace comes from the past 30 **completed local calendar days**. For each date, sum the tier-weighted consumption across accounts; then average over dates with activity. A date used on two accounts counts once. Today is excluded, as are idle dates. At least two active dates are required. Historical account/lane records remain separate on disk, allowing this calculation without rescanning logs.

Balances and historical consumption are converted to a common nominal capacity: Pro 20x = 1, Pro 5x = 0.25, Plus = 0.05. Thus 100% of a Pro 5x allowance contributes one quarter of a Pro 20x allowance. Labels follow [CodexBar's provider mapping](../../Sources/CodexBarCore/Providers/Codex/CodexPlanFormatting.swift); relative tier sizes follow [official pricing](https://learn.chatgpt.com/docs/pricing). These are approximate nominal plan weights, not an exact billing conversion or a measurement of model-specific promotional limits. Unknown plans or simultaneous layered main quotas suppress the shared estimate rather than assume equal capacities.

The simulation spends the common historical daily rate on the first account with capacity. Reported resets restore that account's tier-weighted capacity; an earlier account's refill can interrupt a later account, extending the later account's date. If everything is empty, the schedule waits for a known reset. Earlier spending from a queued account reduces its refreshed balance and changes the next calculation. The app does not switch accounts or infer session routing: `Now` is the starting point of this conditional schedule.

Only the currently reported reset per account is simulated. The horizon stops before a second, unreported refill could occur, capped at 30 days. `Through Thu` means the account lasts through that horizon; `Later` means it has no turn within it. Future banked-reset grants and redemption are not predicted. Days ahead are assumed active. The runway itself uses a small bounded event loop and at most 31 daily values per account; unlike the separate cost-history feature, it adds no requests, timers, or log scans.

The service's `gpt-reserve` additional bucket is a smaller-model fallback (`normal_model_slug` identifies Luna in the observed response; the upsell says the advanced models remain capped). The former generic “Reserve” row misleadingly suggested another general allowance. This bucket is omitted from both the main UI and shared runway. No inference request is sent to test access to it.

History records positive quota deltas from existing refreshes. The first reading is a baseline, not newly consumed quota. Scheduled and banked resets preserve past daily totals and establish a new baseline. Corrections within a cycle use a high-water mark to prevent double counting. Deltas spanning midnight are omitted rather than assigned to an invented day. No unobserved consumption or refills are fabricated; usage during app downtime and around resets may be missed, making the estimate optimistic. This is observed active-day consumption, not an exact provider billing ledger.

Compact quota history is retained across launches and settings changes in `~/.local/share/usage-bar/quota-history.json` (owner-only permissions, hashed account/lane keys, no credentials, emails, or transcripts). At most 128 lanes and 31 daily totals per lane are retained; a small atomic save runs off the UI actor once per existing Codex refresh. Shared Codex logs do not identify accounts directly, but T3's retained session cursors and imported-transcript mappings can attribute historical quota snapshots. The maintenance import below concerns **account-attributed quota/runway history**, not token-cost history. Cost history now imports automatically through the separate cache described above. Shared runway estimates still need attributable quota history across at least two active dates.

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
