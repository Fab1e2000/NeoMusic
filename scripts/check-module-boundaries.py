#!/usr/bin/env python3
"""Current source boundaries. Extend for the approved NetEase integration when it starts."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
errors = []
sources = sorted((root / "NeoMusic").rglob("*.swift"))
# PhotosUI 和 UniformTypeIdentifiers 用于原生效果稿的播放列表封面选择。
allowed_imports = {"SwiftUI", "UIKit", "AVKit", "PhotosUI", "UniformTypeIdentifiers", "Foundation", "AVFoundation", "MediaPlayer", "Observation", "ImageIO", "CryptoKit"}
for source in sources:
    relative = source.relative_to(root)
    if "Modules" in relative.parts:
        errors.append(f"{relative}: online source code requires the NetEase integration boundary checks first")
    for module in re.findall(r"^\s*import\s+([A-Za-z_][A-Za-z_0-9]*)", source.read_text(), re.MULTILINE):
        # The player also uses MetalKit for its EDR glyph rendering.
        if module in {"LNPopupUI", "Nuke", "NukeUI", "CoreImage", "CoreGraphics", "MetalKit"} and source.is_relative_to(root / "NeoMusic/Features/Player"):
            continue
        if module not in allowed_imports:
            errors.append(f"{relative}: import {module} is outside the current dependency boundary; extend checks for the next stage")
if not sources:
    errors.append("No app sources found")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Source boundaries passed ({len(sources)} Swift files; NetEase integration not yet present).")
