#!/usr/bin/env python3
"""Verify local paths referenced as inline code in vendored package notices."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
NOTICES = (
    "LNPopupController/NEOMUSIC-PATCHES.md",
    "LNPopupUI/NEOMUSIC-PATCHES.md",
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


def main() -> int:
    errors = [error for name in NOTICES for error in check_notice(ROOT, ROOT / "Packages" / name)]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Vendor notice paths passed ({len(NOTICES)} packages).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
