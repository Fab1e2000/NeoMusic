#!/usr/bin/env python3
"""Verify local paths referenced as inline code in vendored package notices."""

import argparse
from hashlib import sha256
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
NOTICES = (
    "AudioStreaming/NOTICE.md",
    "AudioTags/PROVENANCE.md",
)
PATH_REFERENCE = re.compile(
    r"(?:[\w. +()-]+/)+[\w. +()-]+"
    r"|[\w+-]+\.(?:swift|h|m|mm|c|cc|cpp|resolved|md)"
    r"|Sources|Tests|LICENSE|COPYING\.[A-Z]+|UTFCPP-LICENSE"
)


def check_notice(root: Path, notice: Path) -> list[str]:
    try:
        lines = notice.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        return [f"{notice.relative_to(root)}: {error.strerror}"]

    errors = []
    has_references = False
    for line_number, line in enumerate(lines, start=1):
        for reference in re.findall(r"`([^`]+)`", line):
            if not PATH_REFERENCE.fullmatch(reference):
                continue
            has_references = True
            path = (notice.parent / reference).resolve()
            if not path.is_relative_to(root) or not path.exists():
                errors.append(f"{notice.relative_to(root)}:{line_number}: invalid local path {reference}")
    if not has_references:
        errors.append(f"{notice.relative_to(root)}: no local paths documented")
    return errors


def baseline_report(packages: Path) -> None:
    for name in NOTICES:
        notice = packages / name
        lines = notice.read_text(encoding="utf-8").splitlines()
        package = notice.parent.name
        references = re.findall(r"`([^`]+)`", "\n".join(lines))
        paths = []
        if package == "AudioStreaming":
            baseline = [line for line in lines if line.startswith(("Source:", "Version:", "NeoMusic trial baseline:"))]
            paths = [item for item in references if item.startswith("Sources/") or item == "Tests/AudioStreamingTests"]
        else:
            baseline = [" ".join(lines[2:4]), next(line for line in lines if line.startswith("utfcpp is pinned"))]
            paths = [item for item in references if item.startswith("Sources/") or item == "Package.swift"]
        print(f"\n{package} ({notice.name})")
        for line in baseline:
            print(" ", line.replace("`", ""))
        for reference in sorted(set(paths)):
            path = notice.parent / reference
            print(f"  {reference}{'/' if path.is_dir() else ''}")
            # A notice may name a directory when its changes are documented by behavior.
            files = sorted(file for file in path.rglob("*") if file.is_file()) if path.is_dir() else [path]
            for file in files:
                digest = sha256(file.read_bytes()).hexdigest()
                print(f"    {digest}  {file.relative_to(notice.parent).as_posix()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true",
                        help="report upstream revisions and SHA-256 fingerprints of documented changes")
    options = parser.parse_args()
    errors = [error for name in NOTICES for error in check_notice(ROOT, ROOT / "Packages" / name)]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Vendor notice paths passed ({len(NOTICES)} packages).")
    if options.baseline:
        baseline_report(ROOT / "Packages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
