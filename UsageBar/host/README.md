# Optional host snapshot API

A Python standard-library HTTP server, binding only `127.0.0.1:8082`. `GET /snapshot` returns a small bounded text snapshot consumed by Usage Bar: GPU utilization/memory/power, cumulative GPU energy in millijoules plus host uptime, host memory, and CPU counters. Other routes return 404. It has no inference, file-browsing, shell-execution, or configuration endpoints.

NVML is initialized once; every sample reads the GPU driver and `/proc` directly. No subprocesses or shell commands run per request. Samples are cached for two seconds to coalesce clients; there is no background sampling loop. Idle server housekeeping wakes at most once per minute. A client has a three-second socket timeout. No third-party Python packages are needed. Hardware values describe GPU index 0; unsupported GPU fields are omitted or unavailable while CPU/memory remain usable.

Install the script as `~/.local/lib/usage-bar/metrics.py` and the unit as `~/.config/systemd/user/usage-bar-metrics.service` on the host. Then:

```sh
loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now usage-bar-metrics
# Use the existing Tailscale operator account. This adds only port 8082.
tailscale serve --bg --tcp=8082 tcp://127.0.0.1:8082
```

Linger keeps this user's service manager running after logout and starts enabled user units at boot. The service runs without root privileges and uses read-only filesystem protection. Tailscale Serve provides the private network exposure boundary; it is not a public listener or Funnel. Tailnet access policy determines which peers can read these hardware statistics. The endpoint does not implement another authentication layer. Preserve existing inference port mappings.

Set the app's **Metrics URL** to `http://<tailnet-host>:8082`. Leave it blank to select the existing SSH collector. An HTTP failure is shown as unavailable; the app does not silently start additional SSH requests.

GPU energy is a driver-lifetime cumulative counter. The app calculates Wh and average watts from counter differences and host uptime, starting at its first successful sample. Counter or uptime rollback starts a new baseline. No history database is required. It includes GPU idle energy and all GPU workloads during the observed interval, even across client sleeps; it is not model-specific and excludes CPU, motherboard, other devices, and PSU losses. Cost uses an optional locally configured USD/kWh rate. Estimated cost is an allocation using that rate, not an exact incremental utility bill.

Local measurements: five fresh SSH samples had a median near 240 ms; five private-network HTTP samples had a median near 14 ms. Uncached API collection measured about 8 ms on the host. The service's cgroup memory was about 30 MiB, so HTTP improves latency and process churn in exchange for resident host memory. These are short local measurements, not a general battery benchmark.

To uninstall, stop/disable this unit and remove only its Serve mapping:

```sh
systemctl --user disable --now usage-bar-metrics
tailscale serve --tcp=8082 off
```

Do not disable user lingering if other user services rely on it.
