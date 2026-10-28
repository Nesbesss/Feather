#!/usr/bin/env python3
"""Verify pinned upstream inputs; adapt plain domains to the existing converter."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.request


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true", help="Restore exact pinned inputs over HTTPS")
    parser.add_argument("--hosts-output", type=Path)
    parser.add_argument("--generated", type=Path)
    args = parser.parse_args()
    source_dir = Path(__file__).resolve().parent
    manifest = json.loads((source_dir / "manifest.json").read_text())

    for item in manifest["files"]:
        target = source_dir / item["path"]
        if args.fetch:
            with urllib.request.urlopen(item["url"], timeout=60) as response:
                data = response.read()
            if digest(data) != item["sha256"]:
                raise SystemExit(f"Downloaded input hash mismatch: {item['path']}")
            target.write_bytes(data)
        if digest(target.read_bytes()) != item["sha256"]:
            raise SystemExit(f"Pinned input hash mismatch: {item['path']}")

    if args.hosts_output:
        hosts = []
        domains = []
        for line in (source_dir / "hagezi-light-domains.txt").read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                hosts.append(line)
                continue
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", line) or "." not in line:
                raise SystemExit(f"Unexpected domain-list syntax: {line!r}")
            domains.append(line)
            hosts.append(f"0.0.0.0 {line}")
        if len(domains) != manifest["upstreamEntries"] or len(set(domains)) != len(domains):
            raise SystemExit("Pinned input entry count or uniqueness mismatch")
        args.hosts_output.write_text("\n".join(hosts) + "\n")

    if args.generated:
        data = args.generated.read_bytes()
        expected = manifest["output"]
        if digest(data) != expected["sha256"] or len(json.loads(data)) != expected["rules"]:
            raise SystemExit("Generated blocklist differs from pinned output")
    print("Pinned blocklist inputs verified.")


if __name__ == "__main__":
    main()
