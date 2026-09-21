#!/usr/bin/env python3
"""Build a signed, isolated Usage Bar Developer ID application bundle."""
from __future__ import annotations
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
BUILD_RE = re.compile(r"^[1-9][0-9]*$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not args.identity.strip():
        parser.error("--identity must not be empty")
    if not VERSION_RE.fullmatch(args.version):
        parser.error("--version must be numeric X.Y.Z")
    if not BUILD_RE.fullmatch(args.build_number):
        parser.error("--build-number must be a positive integer")
    if not args.output.is_absolute() or args.output.suffix != ".app":
        parser.error("--output must be an absolute path ending in .app")
    if os.path.lexists(args.output):
        parser.error(f"--output already exists: {args.output}")
    return args


def main() -> int:
    args = parse_args()
    if sys.platform != "darwin":
        raise SystemExit("Release builds require macOS.")
    package = Path(__file__).with_name("package.sh")
    command = [
        str(package),
        "--release",
        "--identity",
        args.identity,
        "--version",
        args.version,
        "--build-number",
        args.build_number,
        "--output",
        str(args.output),
    ]
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
