#!/usr/bin/env python3
"""Check native dependencies, FrontAM host import boundaries and NetEase account ownership."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
COMMON_IMPORTS = {"SwiftUI", "UIKit", "AVKit", "PhotosUI", "UniformTypeIdentifiers", "Foundation",
                  "AVFoundation", "MediaPlayer", "Observation", "ImageIO", "CryptoKit"}
PLAYER_IMPORTS = {"Nuke", "CoreImage", "CoreGraphics", "MetalKit"}
SOURCE_EXTENSIONS = {".swift", ".metal", ".m", ".mm", ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".s"}
NETEASE_IMPORTS = {"Foundation", "Observation", "CryptoKit", "CommonCrypto", "Security"}
SWIFT_IMPORT = re.compile(r"(?:^|;)\s*(?:@\w+(?:\([^\n]*?\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?"
                          r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)",
                          re.MULTILINE)


def check_source(relative: Path, text: str) -> list[str]:
    errors = []
    netease = relative.is_relative_to("NeoMusic/Core/Netease")
    account_ui = relative.is_relative_to("NeoMusic/Features/Account")
    app = relative.is_relative_to("NeoMusic/App")
    feature = relative.is_relative_to("NeoMusic/Features")
    player = relative.is_relative_to("NeoMusic/Features/Player")
    if relative.suffix == ".metal" and not player:
        errors.append("player shaders belong in Features/Player")
    if "Modules" in relative.parts:
        errors.append("online source code belongs in Core/Netease")
    if feature and re.search(r"\bLocalLibrary\s*\.", text):
        errors.append("features must receive library dependencies from App assembly")
    if relative.suffix == ".swift":
        for module in SWIFT_IMPORT.findall(text):
            allowed = module in (NETEASE_IMPORTS if netease else COMMON_IMPORTS)
            allowed |= player and module in PLAYER_IMPORTS
            allowed |= account_ui and module == "WebKit"
            allowed |= relative == Path("NeoMusic/Core/Netease/NeteaseMusicStore.swift") and module == "Network"
            allowed |= relative == Path("NeoMusic/Core/Netease/NeteaseArtworkCache.swift") and module == "Nuke"
            allowed |= relative == Path("NeoMusic/Core/Netease/NeteasePageCache.swift") and module == "SQLite3"
            allowed |= relative == Path("NeoMusic/Core/Playback/StreamingPlaybackDeck.swift") and module == "AudioStreaming"
            allowed |= relative == Path("NeoMusic/Core/PerformanceDiagnostics.swift") and module in {"os", "OSLog"}
            allowed |= relative == Path("NeoMusic/Core/LocalMusic/DownloadedAudioTags.swift") and module == "AudioTagBridge"
            allowed |= (app or player) and module in {"FrontAM", "FrontAMPlayer", "FrontAMCore"}
            allowed |= player and module == "FrontAMPopup"
            allowed |= (app or feature) and module == "FrontAMNavigation"
            allowed |= (app or feature) and module == "FrontAMPages"
            allowed |= relative in {
                Path("NeoMusic/Core/Library/AlbumArtworkBackdropPreparer.swift"),
                Path("NeoMusic/Core/Library/LocalArtworkImages.swift"),
                Path("NeoMusic/Core/Library/LibrarySongSource.swift"),
            } and module == "FrontAMCore"
            allowed |= relative == Path("NeoMusic/Core/Library/LibrarySongSource.swift") and module == "FrontAMPages"
            if not allowed:
                errors.append(f"import {module} is outside this source's dependency boundary")
    # Literal paths from the shared storage registry should not count as type references.
    type_text = re.sub(r'"[A-Za-z_][\w./-]*"', '""', text)
    if not (netease or account_ui or app) and re.search(r"\bNetease\w*\b", type_text):
        errors.append("NetEase types belong in Core/Netease, Features/Account or App assembly")
    if not netease and re.search(r"\b(?:URLSession|NSURLSession|HTTPCookieStorage|SecItem\w+|CommonCrypto)\b", text):
        errors.append("account transport and credentials belong in Core/Netease")
    if not (netease or account_ui) and re.search(r"\b(?:URLRequest|HTTPCookie|WKWebView|WKWebsiteDataStore|WebPage)\b", text):
        errors.append("account requests and website authentication are outside the account boundary")
    if not (netease or account_ui) and re.search(r"(?:music\.163\.com|netease\.session)", text):
        errors.append("NetEase endpoints and credential keys belong in the account boundary")
    if netease and re.search(r"\b(?:LocalLibrary\w*|LocalMusic\w*|PlaylistLibrary|NowPlayingModel|ReferencePlayer\w*|PlayerState|PlayerPlaybackSource|PlayerServices)\b", text):
        errors.append("NetEase services must not own local library or player state")
    return [f"{relative}: {error}" for error in errors]


def main() -> int:
    sources = sorted(path for path in (ROOT / "NeoMusic").rglob("*")
                     if path.is_file() and path.suffix.lower() in SOURCE_EXTENSIONS)
    errors = [error for source in sources
              for error in check_source(source.relative_to(ROOT), source.read_text())]
    if not sources:
        errors.append("No sources found in NeoMusic")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Source boundaries passed ({len(sources)} source files; NetEase account ownership checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
