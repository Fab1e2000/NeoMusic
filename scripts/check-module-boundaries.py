#!/usr/bin/env python3
"""Check native dependencies and the NetEase account's actual source ownership."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
COMMON_IMPORTS = {"SwiftUI", "UIKit", "AVKit", "PhotosUI", "UniformTypeIdentifiers", "Foundation",
                  "AVFoundation", "MediaPlayer", "Observation", "ImageIO", "CryptoKit"}
PLAYER_IMPORTS = {"LNPopupUI", "Nuke", "NukeUI", "CoreImage", "CoreGraphics", "MetalKit"}
NETEASE_IMPORTS = {"Foundation", "Observation", "CryptoKit", "CommonCrypto", "Security"}


def check_source(relative: Path, text: str) -> list[str]:
    errors = []
    netease = relative.is_relative_to("NeoMusic/Core/Netease")
    account_ui = relative.is_relative_to("NeoMusic/Features/Account")
    app = relative.is_relative_to("NeoMusic/App")
    player = relative.is_relative_to("NeoMusic/Features/Player")
    if "Modules" in relative.parts:
        errors.append("online source code belongs in Core/Netease")
    if relative.suffix == ".swift":
        for module in re.findall(r"^\s*(?:@\w+\s+)?import\s+([A-Za-z_][A-Za-z_0-9]*)", text, re.MULTILINE):
            allowed = module in (NETEASE_IMPORTS if netease else COMMON_IMPORTS)
            allowed |= player and module in PLAYER_IMPORTS
            # Native image processing is owned by these concrete artwork renderers.
            allowed |= relative in {
                Path("NeoMusic/Features/Home/HomePlaylistArtwork.swift"),
                Path("NeoMusic/Features/Library/ArtistDetailBackdrop.swift"),
            } and module == "CoreImage"
            allowed |= account_ui and module == "WebKit"
            allowed |= relative == Path("NeoMusic/Core/Netease/NeteaseAvatarSnapshot.swift") and module == "ImageIO"
            allowed |= relative == Path("NeoMusic/Core/Netease/NeteaseMusicStore.swift") and module == "Network"
            if not allowed:
                errors.append(f"import {module} is outside this source's dependency boundary")
    # Scan Swift and Objective-C together; moving code does not exempt it.
    if not (netease or account_ui or app) and re.search(r"\bNetease\w*\b", text):
        errors.append("NetEase types belong in Core/Netease, Features/Account or App assembly")
    if not netease and re.search(r"\b(?:URLSession|NSURLSession|HTTPCookieStorage|SecItem\w+|CommonCrypto)\b", text):
        errors.append("account transport and credentials belong in Core/Netease")
    if not (netease or account_ui) and re.search(r"\b(?:URLRequest|HTTPCookie|WKWebView|WKWebsiteDataStore|WebPage)\b", text):
        errors.append("account requests and website authentication are outside the account boundary")
    if not (netease or account_ui) and re.search(r"(?:music\.163\.com|netease\.session)", text):
        errors.append("NetEase endpoints and credential keys belong in the account boundary")
    if netease and re.search(r"\b(?:LocalLibrary\w*|LocalMusic\w*|PlaylistLibrary|NowPlayingModel|ReferencePlayer\w*)\b", text):
        errors.append("NetEase services must not own local library or player state")
    return [f"{relative}: {error}" for error in errors]


def main() -> int:
    sources = sorted(path for path in (ROOT / "NeoMusic").rglob("*")
                     if path.suffix in {".swift", ".m", ".mm", ".h"})
    errors = [error for source in sources
              for error in check_source(source.relative_to(ROOT), source.read_text())]
    if not sources:
        errors.append("No app sources found")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Source boundaries passed ({len(sources)} source files; NetEase account ownership checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
