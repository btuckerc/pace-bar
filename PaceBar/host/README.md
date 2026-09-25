# Optional host snapshot API

A Python standard-library HTTP server, binding only `127.0.0.1:8082`. `GET /snapshot` returns a small bounded text snapshot consumed by Pace Bar: GPU utilization/memory/power, cumulative GPU energy in millijoules plus host uptime, host memory, and CPU counters. Other routes return 404. It has no inference, file-browsing, shell-execution, or configuration endpoints.

NVIDIA uses NVML, retrying initialization if the driver was unavailable at startup. AMD uses read-only amdgpu sysfs counters, discovering numeric DRM cards afresh rather than assuming a stable card number. NVIDIA index 0 takes precedence; otherwise the first discovered AMD card is used. Unsupported fields remain unavailable without erasing CPU/memory or other GPU fields. Suspended AMD devices can withhold utilization/power readings; collection resumes automatically when those sensors become available, without waking the GPU or changing its power policy.

The single server loop samples every five seconds, even without HTTP clients, and caches request snapshots for two seconds. No subprocesses, inference requests, or third-party packages are used. Client sockets have a three-second timeout.

Install the script as `~/.local/lib/pace-bar/metrics.py` and the unit as `~/.config/systemd/user/pace-bar-metrics.service` on the host. Then:

```sh
loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now pace-bar-metrics
# Use the existing Tailscale operator account. This adds only port 8082.
tailscale serve --bg --tcp=8082 tcp://127.0.0.1:8082
```

Linger keeps this user's service manager running after logout and starts enabled user units at boot. The unprivileged service retains read-only filesystem protection except its private `StateDirectory=pace-bar` (normally `~/.local/state/pace-bar`). Tailscale Serve provides the private network exposure boundary; it is not a public listener or Funnel. Tailnet access policy determines which peers can read these hardware statistics. The endpoint does not implement another authentication layer. Preserve existing inference port mappings.

Set the app's **Metrics URL** to `http://<tailnet-host>:8082`. Leave it blank to select the existing SSH collector. An HTTP failure is shown as unavailable; the app does not silently start additional SSH requests.

NVIDIA `ENERGY` is a driver-lifetime cumulative hardware counter in millijoules. `ENERGY_ID` identifies the boot/device epoch. The app retains recorded energy and baselines in its existing host-scoped history, so observed driver/host resets do not erase prior totals. Avg W uses differences between successive valid readings within the same epoch.

AMD `ENERGY_ESTIMATE` is an explicitly labeled sampled-power estimate, not a hardware energy counter. Adjacent valid readings, five to fifteen seconds apart, are integrated trapezoidally. Missing readings and longer gaps are not backfilled. The accumulated total and stable epoch identity are saved atomically at most once a minute to `estimated-energy-mj` in the service state directory, and checkpointed on graceful shutdown. Existing scalar checkpoints migrate automatically to compact JSON without losing their total. It survives app, service, and host restarts without counting downtime. Abrupt shutdown can lose the last uncheckpointed minute; missing/corrupt state starts a new counter identity, allowing the app to retain its earlier observed total. Replayed checkpoints do not count twice. Historical use before collection cannot be reconstructed. Retained energy remains available when the GPU suspends, although live watts may be unavailable.

Both modes cover GPU-only energy, including observed idle activity and all GPU workloads, not individual models or billing months. They exclude CPU, motherboard, other devices, and PSU losses. Cost is Wh / 1000 × the locally configured USD/kWh rate. Avg W from estimated totals can understate average power if sampling intervals were missed. Preserve the app's `nous-history.json` as well as the host checkpoint; neither can reconstruct energy never recorded before a counter reset.

To update without interrupting inference, replace only this script and unit, then run `systemctl --user daemon-reload` and `systemctl --user restart pace-bar-metrics`. Do not restart the inference service or change Serve mappings. Verify `systemctl --user is-enabled pace-bar-metrics`, `loginctl show-user "$USER" -p Linger`, and `curl http://127.0.0.1:8082/snapshot`.

Earlier NVIDIA-only measurements: five fresh SSH samples had a median near 240 ms; five private-network HTTP samples had a median near 14 ms. Uncached collection measured about 8 ms and service cgroup memory about 30 MiB. These predate background energy sampling and are not a current resource or battery benchmark.

To uninstall, stop/disable this unit and remove only its Serve mapping:

```sh
systemctl --user disable --now pace-bar-metrics
tailscale serve --tcp=8082 off
```

Do not disable user lingering if other user services rely on it.

### Renaming from Usage Bar

Install the new script and unit as above, then move the state directory whole so the AMD energy total and its counter identity carry over. Serve mappings and port 8082 stay the same.

```sh
systemctl --user disable --now usage-bar-metrics
mv ~/.local/state/usage-bar ~/.local/state/pace-bar
rm ~/.config/systemd/user/usage-bar-metrics.service
systemctl --user daemon-reload
systemctl --user enable --now pace-bar-metrics
curl http://127.0.0.1:8082/snapshot
```

The snapshot should show the same `ENERGY_ID` as before and a total no lower than the last one. Remove `~/.local/lib/usage-bar/` afterwards.

