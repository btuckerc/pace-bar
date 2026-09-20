#!/usr/bin/env python3
"""Read-only, loopback host snapshot API. No third-party Python packages."""
import argparse
import ctypes
import http.server
import time
from pathlib import Path


class Utilization(ctypes.Structure):
    _fields_ = [("gpu", ctypes.c_uint), ("memory", ctypes.c_uint)]


class Memory(ctypes.Structure):
    _fields_ = [("total", ctypes.c_ulonglong), ("free", ctypes.c_ulonglong), ("used", ctypes.c_ulonglong)]


class Collector:
    def __init__(self):
        self.nvml = None
        try:
            lib = ctypes.CDLL("libnvidia-ml.so.1")
            if lib.nvmlInit_v2() == 0:
                self.nvml = lib
        except (OSError, AttributeError):
            pass
        self.cached = b""
        self.sampled = 0.0

    def snapshot(self):
        now = time.monotonic()
        if self.cached and now - self.sampled < 2:
            return self.cached
        lines = []
        if self.nvml:
            n, h = self.nvml, ctypes.c_void_p()
            if n.nvmlDeviceGetHandleByIndex_v2(0, ctypes.byref(h)) == 0:
                u, m, w, e = Utilization(), Memory(), ctypes.c_uint(), ctypes.c_ulonglong()
                gpu = n.nvmlDeviceGetUtilizationRates(h, ctypes.byref(u)) == 0
                mem = n.nvmlDeviceGetMemoryInfo(h, ctypes.byref(m)) == 0
                power = n.nvmlDeviceGetPowerUsage(h, ctypes.byref(w)) == 0
                vals = [str(u.gpu) if gpu else "N/A", str(m.used / 1048576) if mem else "N/A",
                        str(m.total / 1048576) if mem else "N/A", str(w.value / 1000) if power else "N/A"]
                lines.append("GPU " + ", ".join(vals))
                if n.nvmlDeviceGetTotalEnergyConsumption(h, ctypes.byref(e)) == 0:
                    lines.append("ENERGY " + str(e.value) + " " + Path("/proc/uptime").read_text().split()[0])
        memory = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, value = line.split(":", 1)
            memory[key] = int(value.split()[0])
        total = memory["MemTotal"] / 1024
        used = (memory["MemTotal"] - memory["MemAvailable"]) / 1024
        lines.append(f"Mem: {total} {used}")
        lines.append(Path("/proc/stat").read_text().splitlines()[0])
        self.cached = ("\n".join(lines) + "\n").encode()
        self.sampled = now
        return self.cached


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8082)
    args = parser.parse_args()
    collector = Collector()

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

    http.server.HTTPServer(("127.0.0.1", args.port), Handler).serve_forever(poll_interval=60)


if __name__ == "__main__":
    main()
