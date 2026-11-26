#!/usr/bin/env python3
"""Check native dependencies, FrontAM isolation and NetEase account ownership."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
COMMON_IMPORTS = {"SwiftUI", "UIKit", "AVKit", "PhotosUI", "UniformTypeIdentifiers", "Foundation",
                  "AVFoundation", "MediaPlayer", "Observation", "ImageIO", "CryptoKit"}
PLAYER_IMPORTS = {"LNPopupUI", "Nuke", "NukeUI", "CoreImage", "CoreGraphics", "MetalKit"}
FRONTAM_SOURCES = Path("Packages/FrontAM/Sources")
FRONTAM_PLAYER = FRONTAM_SOURCES / "FrontAMPlayer"
FRONTAM_CORE = FRONTAM_SOURCES / "FrontAMCore"
FRONTAM_UMBRELLA = FRONTAM_SOURCES / "FrontAM"
SOURCE_EXTENSIONS = {".swift", ".metal", ".m", ".mm", ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".s"}
COMPONENT_IMPORTS = {"SwiftUI", "UIKit", "Foundation", "Observation", "AVKit", "AVFoundation",
                     "MediaPlayer", "MetalKit", "CoreImage", "CoreGraphics", "UniformTypeIdentifiers"}
NETEASE_IMPORTS = {"Foundation", "Observation", "CryptoKit", "CommonCrypto", "Security"}
SWIFT_IMPORT = re.compile(r"(?:^|;)\s*(?:@\w+(?:\([^\n]*?\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?"
                          r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)",
                          re.MULTILINE)
C_IMPORT = re.compile(r'^\s*(?:@import\s+|#\s*(?:import|include)\s+[<"])([\w./+-]+)', re.MULTILINE)
FRONTAM_HOST_REFERENCE = re.compile(
    r"\b(?:NeoMusic\w*|LNPopup\w*|Nuke(?:UI)?|NowPlayingModel|LibrarySongItem|ReferenceLibrary|"
    r"ReferenceLyricsReader|LyricsReader|LyricsDocument|LocalLibrary\w*|LocalArtworkImages|LocalMusic\w*|"
    r"PlaylistLibrary|LibraryDownloads|LibraryToast\w*|LibraryHaptics|PerformanceDiagnostics|"
    r"ArtworkImagePipeline|ArtworkLoadAction|AppContainer|AppRuntime|AppShell|AppLogger|AppDefaultsKey|AppStoragePaths)\b"
)


def frontam_imports(relative: Path) -> set[str]:
    if relative.is_relative_to(FRONTAM_CORE):
        return {"Foundation"}
    if relative.is_relative_to(FRONTAM_PLAYER):
        imports = COMPONENT_IMPORTS | {"FrontAMCore"}
        if relative == FRONTAM_PLAYER / "NowPlaying/NowPlayingAirPlayButton.swift":
            imports |= {"CoreBluetooth"}
        return imports
    if relative.is_relative_to(FRONTAM_UMBRELLA):
        return {"FrontAMCore", "FrontAMPlayer"}
    return set()


def check_source(relative: Path, text: str) -> list[str]:
    errors = []
    netease = relative.is_relative_to("NeoMusic/Core/Netease")
    account_ui = relative.is_relative_to("NeoMusic/Features/Account")
    app = relative.is_relative_to("NeoMusic/App")
    feature = relative.is_relative_to("NeoMusic/Features")
    player = relative.is_relative_to("NeoMusic/Features/Player")
    frontam = relative.is_relative_to(FRONTAM_SOURCES)
    frontam_player = relative.is_relative_to(FRONTAM_PLAYER)
    package_imports = frontam_imports(relative) if frontam else set()
    if relative.suffix == ".metal" and not (player or frontam_player):
        errors.append("player shaders belong in FrontAMPlayer or Features/Player")
    if "Modules" in relative.parts:
        errors.append("online source code belongs in Core/Netease")
    if feature and re.search(r"\bLocalLibrary\s*\.", text):
        errors.append("features must receive library dependencies from App assembly")
    if relative.suffix == ".swift":
        for module in SWIFT_IMPORT.findall(text):
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
            allowed |= (app or player) and module in {"FrontAM", "FrontAMPlayer", "FrontAMCore"}
            allowed |= relative == Path("NeoMusic/Features/Library/AlbumArtworkBackdrop.swift") and module == "FrontAMCore"
            if frontam:
                allowed = module in package_imports
            if not allowed:
                errors.append(f"import {module} is outside this source's dependency boundary")
    if frontam:
        if not package_imports:
            errors.append("FrontAM source must belong to a declared module")
        if relative.suffix != ".swift":
            native_headers = package_imports - {"FrontAMCore", "FrontAMPlayer"}
            if frontam_player and relative.suffix == ".metal":
                native_headers.add("metal_stdlib")
            for header in C_IMPORT.findall(text):
                if header.split("/", 1)[0].split(".", 1)[0] not in native_headers:
                    errors.append(f"import {header} is outside this source's dependency boundary")
        if FRONTAM_HOST_REFERENCE.search(text):
            errors.append("FrontAM presentation must consume host interfaces")
        if re.search(r'\bBundle\s*\.\s*main\b|\[\s*NSBundle\s+mainBundle\b|\bUIImage\s*\(\s*named\s*:|"netease:|"preview\.appearance', text):
            errors.append("FrontAM resources and identities must be independent of the app bundle and account format")
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
    sources = sorted(path for directory in (Path("NeoMusic"), FRONTAM_SOURCES)
                     for path in (ROOT / directory).rglob("*")
                     if path.is_file() and path.suffix.lower() in SOURCE_EXTENSIONS)
    errors = [error for source in sources
              for error in check_source(source.relative_to(ROOT), source.read_text())]
    for directory in (Path("NeoMusic"), FRONTAM_CORE, FRONTAM_PLAYER, FRONTAM_UMBRELLA):
        if not any(source.is_relative_to(ROOT / directory) for source in sources):
            errors.append(f"No sources found in {directory}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Source boundaries passed ({len(sources)} source files; NetEase account ownership checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
