#!/usr/bin/env python3
"""Capture and verify the source inputs used to construct a Feather release app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
EXCLUDED_NAMES = {".DS_Store", "__pycache__"}
REQUIRED_FILES = (
    "project.yml", "LICENSE", "THIRD_PARTY_NOTICES.md",
    "Tools/Release/build.sh", "Tools/Release/build-source.py",
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_inputs(root=ROOT):
    """Return build inputs independently of Git, including new app resources."""
    root = Path(root)
    paths = set(REQUIRED_FILES)
    for folder in ("Feather", "Support"):
        directory = root / folder
        if not directory.is_dir() or directory.is_symlink():
            raise ValueError(f"Missing or unsafe source directory: {folder}")
        for current, directories, files in os.walk(directory):
            directories[:] = sorted(d for d in directories if d not in EXCLUDED_NAMES)
            for name in directories:
                path = Path(current) / name
                if path.is_symlink():
                    raise ValueError(f"Source input cannot be a symlink: {path.relative_to(root)}")
            for name in sorted(files):
                if name in EXCLUDED_NAMES or (folder == "Support" and name == "Local.xcconfig"):
                    continue
                path = Path(current) / name
                if folder == "Support" and not (
                    path.suffix in {".xcconfig", ".plist", ".entitlements"}
                    or name.endswith(".xcconfig.example")
                ):
                    continue
                paths.add(path.relative_to(root).as_posix())
    for name in paths:
        path = root / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"Missing or unsafe source input: {name}")
    return sorted(paths)


def capture_manifest(root=ROOT):
    root = Path(root)
    hashes = {name: sha256(root / name) for name in source_inputs(root)}
    tree_hash = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    return {"schema": 1, "files": hashes, "treeSHA256": tree_hash}


def read_manifest(path):
    with Path(path).open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    hashes = manifest.get("files")
    if manifest.get("schema") != 1 or not isinstance(hashes, dict) or not hashes:
        raise ValueError("Invalid build-source manifest schema")
    for name, digest in hashes.items():
        if not isinstance(name, str) or not name or Path(name).is_absolute() or \
           ".." in Path(name).parts or Path(name).as_posix() != name or \
           not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Invalid path or digest in build-source manifest")
    tree_hash = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    if manifest.get("treeSHA256") != tree_hash:
        raise ValueError("Build-source manifest tree hash is invalid")
    return manifest


def verify_manifest(path, root=ROOT):
    before = read_manifest(path)
    after = capture_manifest(root)
    if before != after:
        changed = sorted(name for name in before["files"].keys() | after["files"].keys()
                         if before["files"].get(name) != after["files"].get(name))
        raise ValueError("Source inputs changed during the build: " + ", ".join(changed[:12])
                         + (f" (and {len(changed) - 12} more)" if len(changed) > 12 else ""))
    return after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("capture").add_argument("--output", required=True, type=Path)
    commands.add_parser("verify").add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "capture":
            manifest = capture_manifest()
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        else:
            manifest = verify_manifest(args.manifest)
        print(f"Build source {args.command}: {len(manifest['files'])} files, {manifest['treeSHA256']}")
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
