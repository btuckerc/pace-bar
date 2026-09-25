#!/usr/bin/env python3
"""One-time, read-only extraction of account-attributed quota history from T3/Codex.

Only quota metadata enters the owner-only output. No tokens or conversation text.
The app never runs this scanner in the background.
"""
import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import sqlite3
from collections import defaultdict


def timestamp(value):
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.timestamp() if parsed.tzinfo is not None else None
    except (ValueError, TypeError, AttributeError):
        return None


def account_bindings(userdata, home):
    settings = json.loads((userdata / "settings.json").read_text())
    result = {}
    for instance, entry in settings.get("providerInstances", {}).items():
        if entry.get("driver") != "codex":
            continue
        config = entry.get("config", {})
        folder = config.get("shadowHomePath") or config.get("homePath") or str(home / ".codex")
        if folder.startswith("~/"):
            folder = str(home / folder[2:])
        try:
            identity = json.loads((Path(folder) / "auth.json").read_text())["tokens"]["account_id"]
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if isinstance(identity, str) and identity:
            result[instance] = identity
    return result


def session_bindings(userdata):
    """Include both active cursors and retained imported transcript ownership."""
    owners = defaultdict(set)
    with sqlite3.connect((userdata / "state.sqlite").as_uri() + "?mode=ro", uri=True) as connection:
        query = "SELECT provider_instance_id,resume_cursor_json,runtime_payload_json FROM provider_session_runtime"
        for instance, cursor, payload in connection.execute(query):
            if cursor:
                session = json.loads(cursor).get("threadId")
                if session and instance:
                    owners[session].add(instance)
            if payload:
                for item in json.loads(payload).get("importedTranscripts", []):
                    if item.get("provider") == "codex" and item.get("providerSessionId") and item.get("providerInstanceId"):
                        owners[item["providerSessionId"]].add(item["providerInstanceId"])
    return owners


def resolve_owner(session, bindings, metadata, visited=None):
    visited = set() if visited is None else visited
    if session in visited:
        return set()
    visited.add(session)
    if session in bindings:
        return bindings[session]
    parent = metadata.get(session, {}).get("parent")
    return resolve_owner(parent, bindings, metadata, visited) if parent else set()


def scan(files, cutoff, now):
    metadata, samples = {}, []
    for path in sorted(set(p.resolve() for p in files)):
        session = path.stem[-36:]
        created = None
        with path.open("rb") as stream:
            for line in stream:
                if b'"rate_limits"' not in line and b'"session_meta"' not in line:
                    continue
                # Quota events are small. Avoid decoding transcript/tool-output megabytes.
                if len(line) > 65536:
                    continue
                try:
                    record = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                payload = record.get("payload", {})
                if record.get("type") == "session_meta":
                    created = timestamp(payload.get("timestamp") or record.get("timestamp"))
                    metadata[session] = {"created": created, "parent": payload.get("forked_from_id") or payload.get("parent_thread_id")}
                    continue
                if record.get("type") != "event_msg" or payload.get("type") != "token_count":
                    continue
                date = timestamp(record.get("timestamp"))
                limits = payload.get("rate_limits")
                if date is None or not cutoff <= date <= now or (created is not None and date < created):
                    continue
                if not isinstance(limits, dict) or limits.get("limit_id") not in (None, "codex"):
                    continue  # Never reinterpret another model's allowance as the main quota.
                for field in ("primary", "secondary"):
                    window = limits.get(field)
                    if not isinstance(window, dict):
                        continue
                    try:
                        used = float(window["used_percent"])
                        period = float(window["window_minutes"]) * 60
                        reset = float(window["resets_at"])
                    except (KeyError, ValueError, TypeError):
                        continue
                    if not all(math.isfinite(v) for v in (used, period, reset)) or not 0 <= used <= 100 or period <= 0 or reset <= date:
                        continue
                    samples.append((session, date, used, period, reset, limits.get("plan_type")))
    return metadata, samples


def attribute(samples, bindings, metadata, accounts):
    attributed, cycle_owners = [], defaultdict(set)
    for session, date, used, period, reset, plan in samples:
        instances = resolve_owner(session, bindings, metadata)
        # Even aliases mapping to the same account must be explicitly unambiguous.
        if len(instances) != 1:
            continue
        account = accounts.get(next(iter(instances)))
        if account is None:
            continue
        cycle_owners[(period, reset)].add(account)
        attributed.append((account, date, used, period, reset, plan))
    # Fail closed if a quota cycle has contradictory account attribution, including timestamp jitter.
    ambiguous = set()
    by_period = defaultdict(list)
    for period, reset in cycle_owners:
        by_period[period].append(reset)
    for period, resets in by_period.items():
        ordered = sorted(resets)
        for i, reset in enumerate(ordered):
            group = {(period, reset)}
            j = i + 1
            while j < len(ordered) and ordered[j] - reset <= 60:
                group.add((period, ordered[j]))
                j += 1
            if len(set.union(*(cycle_owners[key] for key in group))) > 1:
                ambiguous.update(group)
    unique = {row for row in attributed if (row[3], row[4]) not in ambiguous}
    return [dict(account=a, date=t, used=u, period=p, reset=r, plan=plan)
            for a, t, u, p, r, plan in sorted(unique, key=lambda row: (row[1], row[0], row[3], row[4], row[2]))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    home = Path.home()
    userdata = home / ".t3/userdata"
    accounts = account_bindings(userdata, home)
    bindings = session_bindings(userdata)
    homes = [home / ".codex"]
    for name in (".codex-t3", ".codex-gui"):
        parent = home / name
        if parent.is_dir():
            homes += [p for p in parent.iterdir() if p.is_dir()]
    files = [p for root in homes for directory in ("sessions", "archived_sessions")
             for p in (root / directory).rglob("*.jsonl")]
    now = dt.datetime.now().astimezone()
    cutoff = (now.replace(hour=0, minute=0, second=0, microsecond=0) - dt.timedelta(days=30)).timestamp()
    metadata, samples = scan(files, cutoff, now.timestamp())
    records = attribute(samples, bindings, metadata, accounts)
    # Exclusive creation avoids following an existing symlink or overwriting another file.
    with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
        json.dump(records, stream, separators=(",", ":"))
    print(f"Extracted {len(records)} quota snapshots across {len({r['account'] for r in records})} accounts.")
    print("Excluded unknown/conflicting ownership, copied fork history, unrelated lanes, and out-of-range dates.")


if __name__ == "__main__":
    main()
