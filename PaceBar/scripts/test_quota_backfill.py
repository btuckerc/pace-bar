import json
from pathlib import Path
import tempfile
import unittest

from quota_backfill import attribute, resolve_owner, scan, session_bindings
import sqlite3


class BackfillTests(unittest.TestCase):
    def test_parent_mapping_and_conflicts(self):
        bindings = {"root": {"primary"}, "conflict": {"primary", "secondary"}}
        metadata = {"child": {"parent": "root"}, "loop": {"parent": "loop"}}
        self.assertEqual(resolve_owner("child", bindings, metadata), {"primary"})
        self.assertEqual(resolve_owner("loop", bindings, metadata), set())
        samples = [("child", 10, 4, 600, 500, "pro"), ("conflict", 11, 5, 600, 500, "pro")]
        result = attribute(samples, bindings, metadata, {"primary": "a", "secondary": "b"})
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["account"], "a")

    def test_ambiguous_cycles_and_jitter_are_excluded(self):
        samples = [("s1", 10, 4, 600, 500, "pro"), ("s2", 11, 5, 600, 501, "pro")]
        self.assertEqual(attribute(samples, {"s1": {"one"}, "s2": {"two"}}, {}, {"one": "a", "two": "b"}), [])

    def test_duplicate_snapshots_are_removed(self):
        sample = ("s", 10, 4, 600, 500, "pro")
        result = attribute([sample, sample], {"s": {"one"}}, {}, {"one": "a"})
        self.assertEqual(len(result), 1)

    def test_scan_ignores_copies_future_records_and_unrelated_lanes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rollout-00000000-0000-0000-0000-000000000001.jsonl"
            records = [{"type": "session_meta", "payload": {"timestamp": "2026-09-01T12:00:00Z"}}]
            def sample(date, lane="codex"):
                return {"timestamp": date, "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
                    "limit_id": lane, "plan_type": "pro", "primary": {
                        "used_percent": 20, "window_minutes": 10080, "resets_at": 1790000000}}}}
            records += [sample("2026-09-01T11:00:00Z"), sample("2026-09-01T13:00:00Z"),
                        sample("2026-09-02T13:00:00Z"), sample("2026-09-01T14:00:00Z", "other")]
            path.write_text("\n".join(json.dumps(r) for r in records) + "\n{broken")
            _, samples = scan([path, path], 1788200000, 1788310000)
            self.assertEqual(len(samples), 1)

    def test_database_imports_retained_ownership_and_detects_conflicts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with sqlite3.connect(root / "state.sqlite") as connection:
                connection.execute("CREATE TABLE provider_session_runtime(provider_instance_id,resume_cursor_json,runtime_payload_json)")
                connection.execute("INSERT INTO provider_session_runtime VALUES(?,?,?)", (
                    "primary", json.dumps({"threadId": "session"}), json.dumps({"importedTranscripts": [
                        {"provider": "codex", "providerSessionId": "old", "providerInstanceId": "secondary"}]})))
                connection.execute("INSERT INTO provider_session_runtime VALUES(?,?,?)", (
                    "secondary", json.dumps({"threadId": "session"}), None))
            result = session_bindings(root)
            self.assertEqual(result["session"], {"primary", "secondary"})
            self.assertEqual(result["old"], {"secondary"})


if __name__ == "__main__":
    unittest.main()
