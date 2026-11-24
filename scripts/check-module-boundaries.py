#!/usr/bin/env python3
"""Check native dependencies and the NetEase account's actual source ownership."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
COMMON_IMPORTS = {"SwiftUI", "UIKit", "AVKit", "PhotosUI", "UniformTypeIdentifiers", "Foundation",
                  "AVFoundation", "MediaPlayer", "Observation", "ImageIO", "CryptoKit"}
PLAYER_IMPORTS = {"LNPopupUI", "Nuke", "NukeUI", "CoreImage", "CoreGraphics", "MetalKit"}
COMPONENT_ROOT = Path("NeoMusic/Features/Player/FullScreenPlayer")
COMPONENT_IMPORTS = {"SwiftUI", "UIKit", "Foundation", "Observation", "AVKit", "AVFoundation",
                     "MediaPlayer", "MetalKit", "CoreImage", "CoreGraphics", "UniformTypeIdentifiers"}
NETEASE_IMPORTS = {"Foundation", "Observation", "CryptoKit", "CommonCrypto", "Security"}


def check_source(relative: Path, text: str) -> list[str]:
    errors = []
    netease = relative.is_relative_to("NeoMusic/Core/Netease")
    account_ui = relative.is_relative_to("NeoMusic/Features/Account")
    app = relative.is_relative_to("NeoMusic/App")
    feature = relative.is_relative_to("NeoMusic/Features")
    player = relative.is_relative_to("NeoMusic/Features/Player")
    component = relative.is_relative_to(COMPONENT_ROOT)
    if relative.suffix == ".metal" and not player:
        errors.append("player shaders belong in Features/Player")
    if "Modules" in relative.parts:
        errors.append("online source code belongs in Core/Netease")
    if feature and re.search(r"\bLocalLibrary\s*\.", text):
        errors.append("features must receive library dependencies from App assembly")
    if relative.suffix == ".swift":
        for module in re.findall(r"^\s*(?:@\w+\s+)?import\s+([A-Za-z_][A-Za-z_0-9]*)", text, re.MULTILINE):
            allowed = module in (NETEASE_IMPORTS if netease else COMMON_IMPORTS)
            allowed |= player and module in PLAYER_IMPORTS
            allowed |= relative in {
                Path("NeoMusic/Features/Home/HomePlaylistArtwork.swift"),
                Path("NeoMusic/Features/Library/ArtistDetailBackdrop.swift"),
                Path("NeoMusic/Features/Library/AlbumArtworkBackdrop.swift"),
            } and module == "CoreImage"
            allowed |= account_ui and module == "WebKit"
            allowed |= relative == Path("NeoMusic/Core/Netease/NeteaseMusicStore.swift") and module == "Network"
            allowed |= relative == Path("NeoMusic/Core/Netease/NeteaseArtworkCache.swift") and module == "Nuke"
            allowed |= relative == Path("NeoMusic/Core/Netease/NeteasePageCache.swift") and module == "SQLite3"
            allowed |= relative == Path("NeoMusic/Core/Playback/StreamingPlaybackDeck.swift") and module == "AudioStreaming"
            allowed |= relative == Path("NeoMusic/Core/PerformanceDiagnostics.swift") and module in {"os", "OSLog"}
            allowed |= relative == Path("NeoMusic/Core/LocalMusic/DownloadedAudioTags.swift") and module == "AudioTagBridge"
            allowed |= (app or (player and not component)) and module == "FullScreenPlayer"
            if component:
                allowed = module in COMPONENT_IMPORTS
                allowed |= relative == COMPONENT_ROOT / "NowPlaying/NowPlayingAirPlayButton.swift" and module == "CoreBluetooth"
            if not allowed:
                errors.append(f"import {module} is outside this source's dependency boundary")
    if component:
        if re.search(r"\b(?:NowPlayingModel|LibrarySongItem|ReferenceLibrary|ReferenceLyricsReader|LyricsReader|LyricsDocument|LocalLibrary\w*|LibraryToast|LibraryHaptics|PerformanceDiagnostics|ArtworkImagePipeline|ArtworkLoadAction)\b", text):
            errors.append("full-screen presentation must consume host interfaces, not app implementations")
        if re.search(r'Bundle\.main|UIImage\(named:|"netease:|"preview\.appearance', text):
            errors.append("full-screen resources and identities must not depend on the app bundle or account format")
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
                     if path.suffix in {".swift", ".m", ".mm", ".h", ".metal"})
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
