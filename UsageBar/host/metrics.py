#!/usr/bin/env python3
"""Read-only loopback host metrics; AMD energy is an observed power estimate."""
import argparse
import ctypes
import http.server
import json
import math
import os
import re
import signal
import time
import uuid
from pathlib import Path


class Utilization(ctypes.Structure):
    _fields_ = [("gpu", ctypes.c_uint), ("memory", ctypes.c_uint)]


class Memory(ctypes.Structure):
    _fields_ = [("total", ctypes.c_ulonglong), ("free", ctypes.c_ulonglong), ("used", ctypes.c_ulonglong)]


class Collector:
    def __init__(self, sysfs_root="/sys", proc_root="/proc", state_dir=None, clock=None):
        self.sysfs, self.proc = Path(sysfs_root), Path(proc_root)
        if state_dir is None:
            state_dir = os.environ.get("STATE_DIRECTORY") or (
                Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "usage-bar"
            )
        self.state_dir, self.clock = Path(state_dir), clock or time.monotonic
        self.nvml = None
        self._nvml_attempt()
        self.cached, self.sampled = b"", 0.0
        self.energy_available = False
        self.state_ready = False
        self.energy_mj, self.energy_counter_id = self._load_energy()
        self.energy_sample, self.last_persist = None, self.clock()
        self.saved_energy_mj = int(self.energy_mj) if self.energy_available else None

    def _nvml_attempt(self):
        try:
            lib = ctypes.CDLL("libnvidia-ml.so.1")
            if lib.nvmlInit_v2() == 0:
                self.nvml = lib
        except (OSError, AttributeError):
            self.nvml = None

    def _new_energy_id(self):
        return "amd-" + uuid.uuid4().hex

    def _load_energy(self):
        path = self.state_dir / "estimated-energy-mj"
        try:
            if path.stat().st_size > 4096:
                raise ValueError("Oversized energy state")
            state = json.loads(path.read_text())
            legacy = isinstance(state, int) and not isinstance(state, bool)
            if legacy:
                state = {"total": state, "id": self._new_energy_id()}
            if not isinstance(state, dict):
                raise ValueError("Invalid energy state")
            value, identity = state["total"], state["id"]
            if value is not None and (
                isinstance(value, bool) or not isinstance(value, (int, float))
                or not math.isfinite(value) or value < 0
            ):
                raise ValueError("Invalid energy total")
            if not isinstance(identity, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", identity):
                raise ValueError("Invalid counter identity")
            self.energy_available = value is not None
            self.state_ready = self._write_energy_state(state) if legacy else True
            return float(value or 0), identity
        except (OSError, ValueError, TypeError, KeyError, OverflowError):
            identity = self._new_energy_id()
            self.state_ready = self._write_energy_state({"total": None, "id": identity})
            return 0.0, identity

    def _write_energy_state(self, state):
        try:
            self.state_dir.mkdir(parents=True, exist_ok=True)
            tmp = self.state_dir / ".estimated-energy-mj.tmp"
            with tmp.open("w") as file:
                json.dump(state, file, separators=(",", ":"))
                file.write("\n")
                file.flush()
                os.fsync(file.fileno())
            os.replace(tmp, self.state_dir / "estimated-energy-mj")
            directory = os.open(self.state_dir, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            return True
        except OSError:
            return False

    def persist(self, force=False):
        now = self.clock()
        total = int(self.energy_mj) if self.energy_available else None
        if self.state_ready and total == self.saved_energy_mj:
            return
        if self.state_ready and not force and now - self.last_persist < 60:
            return
        if self._write_energy_state({"total": total, "id": self.energy_counter_id}):
            self.state_ready = True
            self.saved_energy_mj = total
            self.last_persist = now


    def _amd_devices(self):

        found = []
        for card in sorted(self.sysfs.glob("class/drm/card*"), key=lambda p: p.name):
            if not re.fullmatch(r"card[0-9]+", card.name):
                continue
            device = card / "device"
            try:
                if device.joinpath("vendor").read_text().strip().lower() == "0x1002":
                    found.append(device)
            except OSError:
                pass
        return found

    @staticmethod
    def _number(path, divisor=1):
        try:
            value = int(path.read_text().strip())
            return value / divisor if 0 <= value < 0xFFFFFFFFFFFFFFFF else None
        except (OSError, ValueError, OverflowError):
            return None

    def _amd_read(self):
        devices = self._amd_devices()
        if not devices:
            return None
        d = devices[0]
        busy = self._number(d / "gpu_busy_percent")
        used = self._number(d / "mem_info_vram_used", 1048576)
        total = self._number(d / "mem_info_vram_total", 1048576)
        power = None
        for hwmon in sorted((d / "hwmon").glob("hwmon*")):
            for name in ("power1_average", "power1_input"):
                power = self._number(hwmon / name, 1000000)
                if power is not None:
                    break
            if power is not None:
                break
        if busy is None and used is None and total is None and power is None:
            return None
        return [str(busy) if busy is not None else "N/A", str(used) if used is not None else "N/A",
                str(total) if total is not None else "N/A", str(power) if power is not None else "N/A"], power

    def _nvml_read(self):
        if self.nvml is None:
            self._nvml_attempt()
        n = self.nvml
        if not n:
            return None, None, None
        try:
            h = ctypes.c_void_p()
            if n.nvmlDeviceGetHandleByIndex_v2(0, ctypes.byref(h)) != 0:
                raise RuntimeError
            u, m, w = Utilization(), Memory(), ctypes.c_uint()
            gpu = n.nvmlDeviceGetUtilizationRates(h, ctypes.byref(u)) == 0
            mem = n.nvmlDeviceGetMemoryInfo(h, ctypes.byref(m)) == 0
            pwr = n.nvmlDeviceGetPowerUsage(h, ctypes.byref(w)) == 0
            if not (gpu or mem or pwr):
                raise RuntimeError
            vals = [str(u.gpu) if gpu else "N/A", str(m.used / 1048576) if mem else "N/A",
                    str(m.total / 1048576) if mem else "N/A", str(w.value / 1000) if pwr else "N/A"]
            energy = None
            try:
                e = ctypes.c_ulonglong()
                if n.nvmlDeviceGetTotalEnergyConsumption(h, ctypes.byref(e)) == 0 and e.value != 0xFFFFFFFFFFFFFFFF:
                    energy = e.value
            except AttributeError:
                pass
            boot = ""
            try:
                boot = self.proc.joinpath("sys/kernel/random/boot_id").read_text().strip()
            except OSError:
                pass
            device_uuid = ""
            try:
                buffer = ctypes.create_string_buffer(96)
                if n.nvmlDeviceGetUUID(h, buffer, ctypes.c_uint(len(buffer))) == 0:
                    device_uuid = buffer.value.decode("ascii", "ignore").strip()
            except (AttributeError, OSError):
                pass
            identity = "-".join(x for x in (boot, device_uuid) if x and not any(c.isspace() for c in x)) or None
            return vals, energy, identity
        except (AttributeError, OSError, RuntimeError, ValueError):
            try:
                if hasattr(n, "nvmlShutdown"):
                    n.nvmlShutdown()
            except (OSError, AttributeError):
                pass
            self.nvml = None
            return None, None, None

    def _uptime(self):
        try:
            return self.proc.joinpath("uptime").read_text().split()[0]
        except (OSError, IndexError):
            return None

    def snapshot(self):
        now = self.clock()
        if self.cached and now - self.sampled < 2:
            return self.cached
        lines, nv = [], self._nvml_read()
        uptime = self._uptime()
        amd = None
        if nv[0] is not None:
            self.energy_sample = None
            lines.append("GPU " + ", ".join(nv[0]))
            if nv[1] is not None and uptime is not None:
                lines.append("ENERGY " + str(nv[1]) + " " + uptime)
                if nv[2]:
                    lines.append("ENERGY_ID " + nv[2])
        else:
            amd = self._amd_read()
            if amd:
                vals, power = amd
                lines.append("GPU " + ", ".join(vals))
                if power is not None:
                    self.energy_available = True
                    if self.energy_sample is not None:
                        then, old_power = self.energy_sample
                        elapsed = now - then
                        if 5 <= elapsed <= 15:
                            self.energy_mj += (old_power + power) * elapsed * 500
                    if self.energy_sample is None or now - self.energy_sample[0] >= 5:
                        self.energy_sample = (now, power)
                else:
                    self.energy_sample = None
                if self.energy_available and self.state_ready and uptime is not None:
                    lines.append("ENERGY_ESTIMATE " + str(int(self.energy_mj)) + " " + uptime)
                    lines.append("ENERGY_ID " + self.energy_counter_id)
            else:
                self.energy_sample = None
        self.persist()
        try:
            data = {
                k: int(v.split()[0])
                for k, v in (x.split(":", 1) for x in self.proc.joinpath("meminfo").read_text().splitlines())
            }
            lines.append(f"Mem: {data['MemTotal'] / 1024} {(data['MemTotal'] - data['MemAvailable']) / 1024}")
            lines.append(self.proc.joinpath("stat").read_text().splitlines()[0])
        except (OSError, KeyError, IndexError, ValueError):
            pass
        self.cached, self.sampled = ("\n".join(lines) + "\n").encode(), now
        return self.cached


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8082)
    args = parser.parse_args()
    collector = Collector()
    stopping = [False]

    class Handler(http.server.BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(3)

        def do_GET(self):
            if self.path != "/snapshot":
                self.send_error(404)
                return
            try:
                body = collector.snapshot()
            except (OSError, ValueError, KeyError):
                self.send_error(503)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", args.port), Handler)

    def stop(_signum, _frame):
        stopping[0] = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    next_sample = collector.clock()
    try:
        while not stopping[0]:
            now = collector.clock()
            if now >= next_sample:
                collector.cached = b""
                collector.snapshot()
                next_sample = now + 5
            server.timeout = max(0, next_sample - collector.clock())
            server.handle_request()
    finally:
        collector.persist(force=True)
        server.server_close()


if __name__ == "__main__":
    main()
