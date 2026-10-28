#!/usr/bin/env python3
"""Package a verified branded DMG, ZIP, matching source and checksums.

Default: local preview, no network calls. --release signs/notarizes the DMG;
requires a notarized Developer ID app and a clean committed source checkout.
This script never creates a GitHub repository or release.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(*command, capture=False):
    result = subprocess.run([str(x) for x in command], check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.STDOUT if capture else None)
    return result.stdout.decode().strip() if capture else ""


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_files():
    git_root = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=ROOT,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if git_root.returncode == 0 and Path(git_root.stdout.decode().strip()).resolve() == ROOT:
        result = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                                cwd=ROOT, check=True, stdout=subprocess.PIPE)
        paths = sorted(set(x.decode() for x in result.stdout.split(b"\0") if x) - {"SOURCE-MANIFEST.json"})
    else:
        archived_manifest = ROOT / "SOURCE-MANIFEST.json"
        if not archived_manifest.is_file():
            raise SystemExit("Package from a Git checkout or an intact Feather source archive")
        manifest = json.loads(archived_manifest.read_text())
        paths = sorted(manifest["files"])
        for name in paths:
            path = (ROOT / name).resolve()
            if not path.is_relative_to(ROOT) or not path.is_file() or sha(path) != manifest["files"][name]:
                raise SystemExit(f"Source archive was modified: {name}. Initialize Git to package your own changes.")
    allowed = {"Feather", "FeatherTests", "Support", "Brand", "Tools", "docs", ".github"}
    root_files = {".gitignore", "project.yml", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md",
                  "CONTRIBUTING.md", "SECURITY.md"}
    denied = {".p12", ".p8", ".key", ".mobileprovision", ".provisionprofile", ".dmg", ".xcuserstate"}
    for name in paths:
        path = ROOT / name
        if (Path(name).parts[0] not in allowed and name not in root_files) or \
           name == "Support/Local.xcconfig" or path.suffix in denied or path.is_symlink() or \
           any(p in {".DS_Store", "node_modules", "__pycache__"} for p in Path(name).parts):
            raise SystemExit(f"Unsafe source export path: {name}")
        if not path.is_file() or path.stat().st_size > 25 * 1024 * 1024:
            raise SystemExit(f"Missing or unexpectedly large source input: {name}")
        if path.suffix in {".swift", ".py", ".sh", ".yml", ".xcconfig", ".mjs", ".md"}:
            if re.search(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}", path.read_bytes()):
                raise SystemExit(f"Possible credential in source input: {name}")
    for required in ("LICENSE", "THIRD_PARTY_NOTICES.md", "project.yml", "Tools/Release/build.sh",
                     "Tools/YouTubeLab/upstream/pins.json", "Tools/BlocklistSources/manifest.json"):
        if required not in paths:
            raise SystemExit(f"Source export is incomplete: {required}")
    return paths


def make_source(output, version, paths):
    hashes = {name: sha(ROOT / name) for name in paths}
    tree_hash = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    manifest = {"schema": 1, "treeSHA256": tree_hash, "files": hashes}
    prefix = f"Feather-{version}"
    with tarfile.open(output, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for name in paths:
            archive.add(ROOT / name, arcname=f"{prefix}/{name}", recursive=False)
        data = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
        info = tarfile.TarInfo(f"{prefix}/SOURCE-MANIFEST.json")
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
    return manifest


def bundle_hashes(app):
    return {str(p.relative_to(app)): sha(p) for p in sorted(app.rglob("*")) if p.is_file()}


def verify_dmg(path, original):
    run("hdiutil", "verify", path)
    with tempfile.TemporaryDirectory(prefix="feather-dmg-check-") as temp:
        mount = Path(temp) / "volume"
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, path)
        try:
            run("codesign", "--verify", "--deep", "--strict", mount / "Feather.app")
            if bundle_hashes(mount / "Feather.app") != original:
                raise SystemExit("DMG app differs from signed input")
            link = mount / "Applications"
            if not link.is_symlink() or os.readlink(link) != "/Applications":
                raise SystemExit("DMG Applications shortcut is missing")
        finally:
            run("hdiutil", "detach", mount)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args()
    app, output = args.app.resolve(), args.output_dir.resolve()
    if app.name != "Feather.app" or not (app / "Contents/MacOS/Feather").is_file():
        raise SystemExit("--app must point to a built Feather.app")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("App version must contain three numeric components")
    archs = run("lipo", "-archs", app / "Contents/MacOS/Feather", capture=True).split()
    arch = "universal" if set(archs) == {"arm64", "x86_64"} else "-".join(archs)
    run("codesign", "--verify", "--deep", "--strict", app)
    paths = source_files()
    build_manifest = app / "Contents/Resources/Legal/BUILD-SOURCE.json"
    if not build_manifest.is_file():
        raise SystemExit("App has no build-source manifest; rebuild with Tools/Release/build.sh")
    run(sys.executable, ROOT / "Tools/Release/build-source.py", "verify", "--manifest", build_manifest)
    built_inputs = json.loads(build_manifest.read_text())["files"]
    if set(built_inputs) - set(paths):
        raise SystemExit("Source archive would omit an application build input")
    if args.release:
        if run("git", "-C", ROOT, "status", "--porcelain", capture=True):
            raise SystemExit("Public release requires a clean committed source checkout")
        if "Authority=Developer ID Application:" not in run("codesign", "-dvvv", app, capture=True):
            raise SystemExit("Public release requires Developer ID Application signing")
        run("xcrun", "stapler", "validate", app)
        run("spctl", "--assess", "--type", "execute", app)
        for key in ("DEVELOPER_ID_APPLICATION", "NOTARY_KEYCHAIN_PROFILE"):
            if not os.environ.get(key):
                raise SystemExit(f"Public release requires {key}")
    output.mkdir(parents=True, exist_ok=True)
    stem = f"Feather-{version}-{arch}" + ("" if args.release else "-preview")
    dmg, zip_path = output / f"{stem}.dmg", output / f"{stem}.zip"
    source = output / f"Feather-{version}-source.tar.gz"
    targets = [dmg, zip_path, source, output / "SHA256SUMS", output / "release-manifest.json", output / "release-notes.md"]
    if any(p.exists() for p in targets):
        raise SystemExit("Release files already exist; choose a fresh output directory")
    import dmgbuild
    with tempfile.TemporaryDirectory(prefix="feather-package-") as temp:
        background = Path(temp) / "install-background.png"
        run("swift", ROOT / "Tools/Release/dmg-background.swift", background,
            ROOT / "Brand/Feather-Mark.png", "release" if args.release else "preview")
        shutil.copy2(background, output / "install-background.png")
        settings = {
            "format": "UDZO", "filesystem": "HFS+", "files": [str(app)],
            "symlinks": {"Applications": "/Applications"}, "background": str(background),
            "icon": str(app / "Contents/Resources/AppIcon.icns"),
            "window_rect": ((200, 160), (760, 500)), "default_view": "icon-view",
            "show_toolbar": False, "show_sidebar": False, "show_status_bar": False,
            "show_pathbar": False, "show_tab_view": False, "icon_size": 104, "text_size": 13,
            "grid_spacing": 80,
            "icon_locations": {"Feather.app": (190, 267), "Applications": (570, 267)},
            "include_icon_view_settings": True,
        }
        dmgbuild.build_dmg(str(dmg), f"Feather {version}" + (" Preview" if not args.release else ""), settings=settings)
    if args.release:
        run("codesign", "--force", "--timestamp", "--sign", os.environ["DEVELOPER_ID_APPLICATION"], dmg)
        run(ROOT / "Tools/Release/notarize.sh", "--dmg", dmg)
    hashes = bundle_hashes(app)
    verify_dmg(dmg, hashes)
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path)
    with tempfile.TemporaryDirectory(prefix="feather-zip-check-") as temp:
        run("ditto", "-x", "-k", zip_path, temp)
        restored = Path(temp) / "Feather.app"
        run("codesign", "--verify", "--deep", "--strict", restored)
        if bundle_hashes(restored) != hashes:
            raise SystemExit("ZIP round-trip differs from signed input")
    source_manifest = make_source(source, version, paths)
    artifacts = {p.name: {"sha256": sha(p), "bytes": p.stat().st_size} for p in [dmg, zip_path, source]}
    manifest = {
        "schema": 1, "version": version, "build": info["CFBundleVersion"],
        "architectures": archs, "minimumMacOS": info["LSMinimumSystemVersion"],
        "createdUTC": datetime.now(timezone.utc).isoformat(),
        "distribution": "notarized" if args.release else "local-preview-not-notarized",
        "sourceTreeSHA256": source_manifest["treeSHA256"], "sourceFileCount": len(paths),
        "dmgRoundTripVerified": True, "zipRoundTripVerified": True, "artifacts": artifacts,
    }
    manifest_path = output / "release-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    status = "Developer ID signed and notarized." if args.release else "Local preview. Ad-hoc signed and not notarized; macOS may block a downloaded copy."
    notes = output / "release-notes.md"
    notes.write_text(
        f"# Feather {version}\n\nNative WebKit browser for macOS 26 and later.\n\n{status}\n\n"
        f"Open `{dmg.name}` and drag Feather to Applications. Eject the image, then launch Feather from Applications.\n\n"
        "Vertical tabs, Spaces, Favorites, command bar, reader mode, privacy controls and compatible WebKit extensions. "
        "This early experimental release uses private WebKit APIs. Extension compatibility varies; passkeys require Apple's approved browser entitlement.\n\n"
        "Release resources include an original CC0 ambient tour recording and a pinned GPL-3.0 HaGeZi blocklist. Third-party licenses are included in the app.\n\n"
        f"Matching source: `{source.name}`. Feather is GPL-3.0; third-party materials retain their notices.\n\n"
        "Verify downloads together with `shasum -a 256 -c SHA256SUMS`.\n")
    (output / "SHA256SUMS").write_text("".join(f"{sha(p)}  {p.name}\n" for p in [dmg, zip_path, source, manifest_path, notes]))
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
