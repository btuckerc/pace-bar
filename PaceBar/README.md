# Pace Bar

The standalone macOS app. Start with the [project README](../README.md).

- [Setup](docs/setup.md)
- [Metrics, privacy, forecast, and persistent Nous lifetime totals](docs/reference.md)
- [Optional host API](host/README.md)
- [Contributing](../CONTRIBUTING.md)

When an inference poll fails, the popover shows **Server down** while host metrics still
arrive, or **Unreachable** when they don't; the warning icon's tooltip carries the diagnosis. Settings → Hosts and Check Setup
use a read-only SSH listener inspection to distinguish a stopped server from an API or
connectivity failure. A server that answers HTTP 503 on purpose shows **Paused · back by**
its `resume_at` (or `Retry-After`) time, with its `error.message` as the tooltip; Pace Bar
rechecks every five minutes until then and skips the SSH diagnosis. Pace Bar never
starts or stops inference services.

For network-free previews, add `--preview-host-offline` or `--preview-host-paused` to
`swift run PaceBar --render-preview /tmp/pace-bar.png`.
