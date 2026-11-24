#!/usr/bin/env python3
"""Report logical file sizes and check a built app for development artifacts."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess


PREVIEW_NAME = re.compile(r"(?<![a-z0-9])(?:homepreviewassets|albumsample[0-9]+)(?![a-z0-9])", re.IGNORECASE)
TEST_SUFFIXES = (".xctest", ".xctestrun", ".xcresult", ".xctestplan", "tests-runner.app")
TEST_SUPPORT = {
    "testing.framework", "libtesting.dylib", "xctautomationsupport.framework",
    "xcuiautomation.framework",
}


def is_test_artifact(name):
    name = name.lower()
    return name.endswith(TEST_SUFFIXES) or name in TEST_SUPPORT or name.startswith(("xctest", "libxctest"))


def find_executable(app):
    layout = Path("Contents") if (app / "Contents/Info.plist").is_file() else Path()
    with (app / layout / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = info.get("CFBundleExecutable") if isinstance(info, dict) else None
    if not isinstance(executable, str) or not executable or Path(executable).name != executable or executable in (".", ".."):
        raise ValueError("Info.plist must contain a valid CFBundleExecutable")
    return layout, layout / ("MacOS" if layout.parts else "") / executable


def asset_names(catalog):
    result = subprocess.run(["assetutil", "--info", str(catalog)], check=True, capture_output=True, text=True)
    entries = json.loads(result.stdout)
    if not isinstance(entries, list) or not entries or any(not isinstance(entry, dict) for entry in entries):
        raise ValueError("unexpected assetutil output")
    return {
        entry[key]
        for entry in entries
        for key in ("Name", "RenditionName")
        if isinstance(entry.get(key), str)
    }


def audit(app):
    if app.suffix.lower() != ".app" or not app.is_dir():
        raise ValueError("expected a built .app directory")
    layout, executable = find_executable(app)
    frameworks = layout / "Frameworks"
    main_catalog = layout / ("Resources" if layout.parts else "") / "Assets.car"
    sizes = {}
    violations = []
    errors = []
    inspected = []

    def scan_failed(error):
        raise error

    for parent, directories, files in os.walk(app, onerror=scan_failed):
        for name in directories + files:
            entry = Path(parent) / name
            path = entry.relative_to(app)
            if PREVIEW_NAME.search(name) or name.lower() == "__preview.dylib":
                violations.append({"path": str(path), "kind": "preview_resource"})
            if is_test_artifact(name):
                violations.append({"path": str(path), "kind": "test_artifact"})
            if entry.is_symlink() or not entry.is_file():
                continue
            sizes[path] = entry.stat().st_size
            if entry.suffix.lower() == ".car":
                try:
                    names = asset_names(entry)
                except (OSError, ValueError, subprocess.CalledProcessError) as error:
                    detail = getattr(error, "stderr", None) or str(error)
                    errors.append({"path": str(path), "error": detail.strip()})
                else:
                    inspected.append(str(path))
                    for asset in names:
                        if PREVIEW_NAME.search(asset):
                            violations.append({"path": str(path), "kind": "preview_asset", "asset": asset})

    if executable not in sizes:
        raise ValueError(f"main executable is missing or is not a regular file: {executable}")

    def size_entry(path):
        return {"path": str(path), "bytes": sizes.get(path, 0)}

    other = sorted(
        (path for path in sizes if path not in (executable, main_catalog) and not path.is_relative_to(frameworks)),
        key=lambda path: (-sizes[path], str(path)),
    )
    return {
        "app": str(app),
        "total_bytes": sum(sizes.values()),
        "main_executable": size_entry(executable),
        "frameworks": {"path": str(frameworks), "bytes": sum(size for path, size in sizes.items() if path.is_relative_to(frameworks))},
        "assets_car": size_entry(main_catalog),
        "other_top_files": [size_entry(path) for path in other[:10]],
        "release_audit": {
            "clean": not violations and not errors,
            "inspected_catalogs": sorted(inspected),
            "violations": sorted(violations, key=lambda item: (item["path"], item["kind"], item.get("asset", ""))),
            "inspection_errors": sorted(errors, key=lambda item: item["path"]),
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="path to the built Release .app")
    app = parser.parse_args().app
    try:
        report = audit(app)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(2, f"{parser.prog}: {error}\n")
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0 if report["release_audit"]["clean"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
