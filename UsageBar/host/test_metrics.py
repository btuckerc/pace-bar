import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import metrics
from metrics import Collector


class Clock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        return self.value


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.sysfs, self.proc, self.state = root / "sys", root / "proc", root / "state"
        self.device = self.sysfs / "class/drm/card7/device"
        self.power = self.device / "hwmon/hwmon3/power1_average"
        self.power.parent.mkdir(parents=True)
        self.proc.mkdir()
        (self.proc / "uptime").write_text("12.0 0.0\n")
        (self.proc / "meminfo").write_text("MemTotal: 1000 kB\nMemAvailable: 500 kB\n")
        (self.proc / "stat").write_text("cpu 1 2 3 4\n")
        for name, value in {
            "vendor": "0x1002", "gpu_busy_percent": "42",
            "mem_info_vram_used": "34208743424", "mem_info_vram_total": "68719476736",
        }.items():
            (self.device / name).write_text(value)
        self.power.write_text("270000000")
        self.clock = Clock()
        self.loader = patch("metrics.ctypes.CDLL", side_effect=OSError("No NVIDIA driver"))
        self.load = self.loader.start()
        self.addCleanup(self.loader.stop)

    def collector(self):
        return Collector(self.sysfs, self.proc, self.state, self.clock)

    def test_amd_units_and_trapezoidal_energy(self):
        c = self.collector()
        self.assertIn("GPU 42.0, 32624.0, 65536.0, 270.0", c.snapshot().decode())
        self.clock.value = 5
        self.power.write_text("540000000")
        self.assertIn("ENERGY_ESTIMATE 2025000 ", c.snapshot().decode())

    def test_discovery_recovers_late_gpu_and_changed_card_number(self):
        original = self.device.parent
        offline = original.with_name("offline")
        original.rename(offline)
        c = self.collector()
        self.assertNotIn("GPU ", c.snapshot().decode())
        # Connector paths must not be mistaken for GPUs, even with a device/vendor entry.
        connector = original.with_name("card0-DP-1") / "device"
        connector.mkdir(parents=True)
        (connector / "vendor").write_text("0x1002")
        intel = original.with_name("card0") / "device"
        intel.mkdir(parents=True)
        (intel / "vendor").write_text("0x8086")
        offline.rename(original.with_name("card2"))
        self.clock.value = 5
        self.assertIn("GPU 42.0, 32624.0, 65536.0, 270.0", c.snapshot().decode())

    def test_unsupported_fields_preserve_vram_and_memory_and_resume_power(self):
        (self.device / "gpu_busy_percent").unlink()
        self.power.write_text("-1")
        c = self.collector()
        snapshot = c.snapshot().decode()
        self.assertIn("GPU N/A, 32624.0, 65536.0, N/A", snapshot)
        self.assertIn("Mem: ", snapshot)
        self.assertNotIn("ENERGY_ESTIMATE", snapshot)
        self.power.with_name("power1_input").write_text("100000000")
        self.clock.value = 5
        self.assertIn("GPU N/A, 32624.0, 65536.0, 100.0", c.snapshot().decode())

    def test_gaps_and_restart_do_not_invent_unobserved_energy(self):
        c = self.collector()
        c.snapshot()
        self.clock.value = 5
        c.snapshot()
        self.clock.value = 30  # Missing >15 seconds: no interpolation.
        c.snapshot()
        self.assertEqual(c.energy_mj, 1350000)
        self.power.unlink()
        self.clock.value = 35
        self.assertIn("ENERGY_ESTIMATE 1350000 ", c.snapshot().decode())
        self.power.write_text("270000000")
        self.clock.value = 40
        c.snapshot()
        self.assertEqual(c.energy_mj, 1350000)
        c.persist(force=True)
        self.clock.value = 1000
        restarted = self.collector()
        self.assertIn("ENERGY_ESTIMATE 1350000 ", restarted.snapshot().decode())
        self.clock.value = 1005
        self.assertIn("ENERGY_ESTIMATE 2700000 ", restarted.snapshot().decode())

    def test_checkpoints_are_bounded_and_corrupt_state_recovers(self):
        c = self.collector()
        for second in range(0, 61, 5):
            self.clock.value = second
            c.snapshot()
        state = self.state / "estimated-energy-mj"
        saved = json.loads(state.read_text())
        self.assertEqual(saved["total"], 16200000)
        identity = saved["id"]
        self.clock.value = 65
        c.snapshot()
        self.assertEqual(json.loads(state.read_text())["total"], 16200000)
        c.persist(force=True)
        self.assertEqual(json.loads(state.read_text())["total"], 17550000)
        self.assertEqual(json.loads(state.read_text())["id"], identity)
        state.write_text("interrupted-invalid-state")
        recovered = self.collector()
        self.assertIn("ENERGY_ESTIMATE 0 ", recovered.snapshot().decode())
        self.assertNotEqual(recovered.energy_counter_id, identity)

    def test_scalar_migration_preserves_history_and_epoch_across_restarts(self):
        self.state.mkdir()
        path = self.state / "estimated-energy-mj"
        path.write_text("7200000000\n")
        original = self.collector()
        self.assertIn("ENERGY_ESTIMATE 7200000000 ", original.snapshot().decode())
        self.assertEqual(json.loads(path.read_text())["total"], 7200000000)
        restarted = self.collector()
        self.assertEqual(restarted.energy_counter_id, original.energy_counter_id)
        self.assertIn("ENERGY_ESTIMATE 7200000000 ", restarted.snapshot().decode())

    def test_epoch_only_state_does_not_invent_energy_while_sensors_are_missing(self):
        self.power.unlink()
        first = self.collector()
        restarted = self.collector()
        self.assertEqual(first.energy_counter_id, restarted.energy_counter_id)
        self.assertNotIn("ENERGY_ESTIMATE", restarted.snapshot().decode())

    def test_invalid_state_shapes_start_new_epochs(self):
        self.state.mkdir()
        path = self.state / "estimated-energy-mj"
        for invalid in ['{}', '[]', 'true', '{"total":-1,"id":"old"}', '{"total":1,"id":"bad id"}']:
            path.write_text(invalid)
            with self.subTest(state=invalid):
                c = self.collector()
                self.assertIn("ENERGY_ESTIMATE 0 ", c.snapshot().decode())
                self.assertNotEqual(c.energy_counter_id, "old")

    def test_failed_checkpoint_retries_without_losing_counter_identity(self):
        c = self.collector()
        c.snapshot()
        self.clock.value = 5
        c.snapshot()
        path = self.state / "estimated-energy-mj"
        with patch("metrics.os.replace", side_effect=OSError("Disk unavailable")):
            c.persist(force=True)
        self.assertIsNone(json.loads(path.read_text())["total"])
        c.persist(force=True)
        saved = json.loads(path.read_text())
        self.assertEqual(saved["total"], 1350000)
        self.assertEqual(saved["id"], c.energy_counter_id)

    def test_unpersisted_epoch_is_not_exposed_until_storage_recovers(self):
        with patch("metrics.os.replace", side_effect=OSError("Disk unavailable")):
            c = self.collector()
            self.assertNotIn("ENERGY_ESTIMATE", c.snapshot().decode())
        c.persist(force=True)
        self.clock.value = 5
        self.assertIn("ENERGY_ID " + c.energy_counter_id, c.snapshot().decode())
        self.assertEqual(self.collector().energy_counter_id, c.energy_counter_id)

    def test_nvidia_boot_failure_retries_and_missing_energy_stays_missing(self):
        c = self.collector()
        lib = Mock()
        lib.nvmlInit_v2.return_value = 0
        lib.nvmlDeviceGetHandleByIndex_v2.return_value = 0
        lib.nvmlDeviceGetUtilizationRates.return_value = 1
        lib.nvmlDeviceGetMemoryInfo.return_value = 1

        def power(_handle, pointer):
            pointer._obj.value = 123000
            return 0

        def energy(_handle, pointer):
            pointer._obj.value = 0xFFFFFFFFFFFFFFFF
            return 0

        lib.nvmlDeviceGetPowerUsage.side_effect = power
        lib.nvmlDeviceGetTotalEnergyConsumption.side_effect = energy
        self.load.side_effect = None
        self.load.return_value = lib
        snapshot = c.snapshot().decode()
        self.assertIn("GPU N/A, N/A, N/A, 123.0", snapshot)
        self.assertNotIn("ENERGY ", snapshot)
        self.assertNotIn("ENERGY_ESTIMATE", snapshot)

    def test_service_samples_without_http_clients_and_checkpoints_on_stop(self):
        c = self.collector()
        handlers = {}
        clock = self.clock

        class Server:
            def __init__(self, *_args):
                self.timeout = 0

            def handle_request(self):
                clock.value += self.timeout
                if clock.value >= 15:
                    handlers[metrics.signal.SIGTERM](None, None)

            def server_close(self):
                pass

        with patch("metrics.Collector", return_value=c), \
                patch("metrics.http.server.HTTPServer", Server), \
                patch("metrics.signal.signal", side_effect=lambda sig, fn: handlers.update({sig: fn})), \
                patch("sys.argv", ["metrics.py"]):
            metrics.main()
        self.assertEqual(json.loads((self.state / "estimated-energy-mj").read_text())["total"], 2700000)


if __name__ == "__main__":
    unittest.main()
