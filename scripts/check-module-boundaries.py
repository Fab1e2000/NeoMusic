#!/usr/bin/env python3
"""Check native dependencies, FrontAM isolation and NetEase account ownership."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
COMMON_IMPORTS = {"SwiftUI", "UIKit", "AVKit", "PhotosUI", "UniformTypeIdentifiers", "Foundation",
                  "AVFoundation", "MediaPlayer", "Observation", "ImageIO", "CryptoKit"}
PLAYER_IMPORTS = {"Nuke", "CoreImage", "CoreGraphics", "MetalKit"}
FRONTAM_SOURCES = Path("Packages/FrontAM/Sources")
FRONTAM_PLAYER = FRONTAM_SOURCES / "FrontAMPlayer"
FRONTAM_POPUP = FRONTAM_SOURCES / "FrontAMPopup"
FRONTAM_NAVIGATION = FRONTAM_SOURCES / "FrontAMNavigation"
FRONTAM_PAGES = FRONTAM_SOURCES / "FrontAMPages"
FRONTAM_CORE = FRONTAM_SOURCES / "FrontAMCore"
FRONTAM_UMBRELLA = FRONTAM_SOURCES / "FrontAM"
FRONTAM_SHOWCASE = Path("Packages/FrontAM/Examples/FrontAMShowcase/Sources")
SOURCE_EXTENSIONS = {".swift", ".metal", ".m", ".mm", ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".s"}
COMPONENT_IMPORTS = {"SwiftUI", "UIKit", "Foundation", "Observation", "AVKit", "AVFoundation",
                     "MediaPlayer", "MetalKit", "CoreImage", "CoreGraphics", "UniformTypeIdentifiers"}
NETEASE_IMPORTS = {"Foundation", "Observation", "CryptoKit", "CommonCrypto", "Security"}
SWIFT_IMPORT = re.compile(r"(?:^|;)\s*(?:@\w+(?:\([^\n]*?\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?"
                          r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)",
                          re.MULTILINE)
C_IMPORT = re.compile(r'^\s*(?:@import\s+|#\s*(?:import|include)\s+[<"])([\w./+-]+)', re.MULTILINE)
FRONTAM_HOST_REFERENCE = re.compile(
    r"\b(?:NeoMusic\w*|Nuke(?:UI)?|NowPlayingModel|ReferenceLibrary|"
    r"ReferenceLyricsReader|LyricsReader|LyricsDocument|LocalLibrary\w*|LocalArtworkImages|LocalMusic\w*|"
    r"PlaylistLibrary\w*|LibraryDownloads|PerformanceDiagnostics|NavigationDiagnostics|"
    r"OnlineSongIdentity|CatalogRouteIdentity|DeferredArtworkKey|PlaylistRouteIdentity|"
    r"ArtworkImagePipeline|AppContainer|AppRuntime|AppShell|AppLogger|AppDefaultsKey|AppStoragePaths|"
    r"AccountPage|MusicQualitySettingsPage|HomeMusicIntegration|ArtistMusicIntegration|SearchMusicIntegration)\b"
)
FRONTAM_PAGE_PRESENTATION = re.compile(r"\b(?:LibrarySongItem|SearchPageModel|LibraryRoute|LibraryNavigationPreview)\b")
FRONTAM_VISUAL_PRESENTATION = re.compile(r"\b(?:LibraryToast\w*|LibraryHaptics|ArtworkLoadAction|ArtworkView)\b")
NAVIGATION_HOST_REFERENCE = re.compile(
    r"\b(?:SearchPageModel|LibraryRoute|LibraryNavigationPreview|AlbumArtworkBackdrop)\b"
)


def frontam_imports(relative: Path) -> set[str]:
    if relative.is_relative_to(FRONTAM_CORE):
        return {"Foundation", "SwiftUI", "UIKit", "Observation", "CoreImage", "CoreGraphics", "ImageIO"}
    if relative.is_relative_to(FRONTAM_PLAYER):
        imports = COMPONENT_IMPORTS | {"FrontAMCore"}
        if relative == FRONTAM_PLAYER / "NowPlaying/NowPlayingAirPlayButton.swift":
            imports |= {"CoreBluetooth"}
        return imports
    if relative.is_relative_to(FRONTAM_POPUP):
        return {"Foundation", "SwiftUI", "UIKit", "FrontAMCore", "FrontAMPlayer", "LNPopupUI"}
    if relative.is_relative_to(FRONTAM_NAVIGATION):
        return {"Foundation", "SwiftUI", "UIKit", "FrontAMCore"}
    if relative.is_relative_to(FRONTAM_PAGES):
        return {"Foundation", "SwiftUI", "UIKit", "Observation", "CoreImage", "CoreGraphics",
                "PhotosUI", "UniformTypeIdentifiers", "FrontAMCore", "FrontAMNavigation"}
    if relative.is_relative_to(FRONTAM_UMBRELLA):
        return {"FrontAMCore", "FrontAMPlayer", "FrontAMPopup", "FrontAMNavigation", "FrontAMPages"}
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
    showcase = relative.is_relative_to(FRONTAM_SHOWCASE)
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
            if frontam:
                allowed = module in package_imports
            if showcase:
                allowed = module in {"FrontAM", "Foundation", "Observation", "SwiftUI", "UIKit"}
            if not allowed:
                errors.append(f"import {module} is outside this source's dependency boundary")
    if showcase:
        if relative.suffix != ".swift":
            errors.append("FrontAMShowcase app sources must be Swift")
        if FRONTAM_HOST_REFERENCE.search(text) or re.search(r"\bNetease\w*\b|网易云", text, re.IGNORECASE):
            errors.append("FrontAMShowcase must use independent demo data")
    if frontam:
        if not package_imports:
            errors.append("FrontAM source must belong to a declared module")
        if relative.suffix != ".swift":
            native_headers = {module for module in package_imports if not module.startswith("FrontAM")} - {"LNPopupUI"}
            if frontam_player and relative.suffix == ".metal":
                native_headers.add("metal_stdlib")
            for header in C_IMPORT.findall(text):
                if header.split("/", 1)[0].split(".", 1)[0] not in native_headers:
                    errors.append(f"import {header} is outside this source's dependency boundary")
        if FRONTAM_HOST_REFERENCE.search(text):
            errors.append("FrontAM presentation must consume host interfaces")
        if not relative.is_relative_to(FRONTAM_PAGES) and FRONTAM_PAGE_PRESENTATION.search(text):
            errors.append("Page models belong in FrontAMPages")
        if not (relative.is_relative_to(FRONTAM_CORE) or relative.is_relative_to(FRONTAM_PAGES)) and FRONTAM_VISUAL_PRESENTATION.search(text):
            errors.append("Shared page visuals belong in FrontAMCore and FrontAMPages")
        if relative.is_relative_to(FRONTAM_NAVIGATION) and NAVIGATION_HOST_REFERENCE.search(text):
            errors.append("FrontAMNavigation must use host-supplied routes, chrome and content")
        if not relative.is_relative_to(FRONTAM_POPUP) and re.search(r"\bLNPopup\w*\b", text):
            errors.append("LNPopup integration belongs in FrontAMPopup")
        if re.search(r'\bBundle\s*\.\s*main\b|\[\s*NSBundle\s+mainBundle\b|\bUIImage\s*\(\s*named\s*:|"(?:netease[-:]|catalog:|catalog-guest:|home:playlist:|preview\.appearance)', text):
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
    sources = sorted(path for directory in (Path("NeoMusic"), FRONTAM_SOURCES, FRONTAM_SHOWCASE)
                     for path in (ROOT / directory).rglob("*")
                     if path.is_file() and path.suffix.lower() in SOURCE_EXTENSIONS)
    errors = [error for source in sources
              for error in check_source(source.relative_to(ROOT), source.read_text())]
    for directory in (Path("NeoMusic"), FRONTAM_CORE, FRONTAM_PLAYER, FRONTAM_POPUP, FRONTAM_NAVIGATION,
                      FRONTAM_PAGES, FRONTAM_UMBRELLA, FRONTAM_SHOWCASE):
        if not any(source.is_relative_to(ROOT / directory) for source in sources):
            errors.append(f"No sources found in {directory}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Source boundaries passed ({len(sources)} source files; NetEase account ownership checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
