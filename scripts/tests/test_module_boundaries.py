from contextlib import redirect_stderr
import importlib.util
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("boundaries", Path(__file__).parents[1] / "check-module-boundaries.py")
boundaries = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boundaries)


class ModuleBoundaryTests(unittest.TestCase):
    def test_account_dependencies_stay_in_their_owners(self):
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Core/Netease/Client.swift"),
                         "import Foundation\nimport CommonCrypto\nimport Security\nlet session: URLSession"), [])
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Features/Account/Login.swift"),
                         "import SwiftUI\nimport WebKit\nlet page: WebPage\nlet account: NeteaseAccount"), [])
        self.assertEqual(boundaries.check_source(Path("NeoMusic/App/Composition.swift"),
                         "let account: NeteaseAccount"), [])

    def test_full_screen_component_has_only_native_dependencies(self):
        path = boundaries.FRONTAM_PLAYER / "Surface.swift"
        for module in ("SwiftUI", "UIKit", "Observation", "MetalKit", "AVFoundation", "FrontAMCore"):
            self.assertEqual(boundaries.check_source(path, "import " + module), [])
        for module in ("NeoMusic", "Nuke", "NukeUI", "LNPopupUI", "LNPopupController", "FrontAM", "FrontAMPlayer"):
            self.assertTrue(boundaries.check_source(path, "import " + module))
        for expression in ("NowPlayingModel()", "LibrarySongItem", "LyricsDocument", "AppStoragePaths", "LocalArtworkImages",
                           "LibraryToast", "PerformanceDiagnostics", "Bundle.main", "Foundation.Bundle . main",
                           'UIImage(named: "Sample")', '"netease:123"', "NeteaseMusicClient",
                           "internal import struct Nuke.ImageRequest", '"LNPopupLongPress"',
                           "@objc(NeoMusicLyricsScrollView)"):
            self.assertTrue(boundaries.check_source(path, expression))

    def test_frontam_dependencies_are_directional(self):
        core = boundaries.FRONTAM_CORE / "ArtworkColorSpace.swift"
        umbrella = boundaries.FRONTAM_UMBRELLA / "FrontAM.swift"
        self.assertEqual(boundaries.check_source(core, "import Foundation"), [])
        exports = ("@_exported import FrontAMCore\n@_exported import FrontAMPlayer\n"
                   "@_exported import FrontAMPopup\n@_exported import FrontAMNavigation\n@_exported import FrontAMPages")
        self.assertEqual(boundaries.check_source(umbrella, exports), [])
        for path in (core, umbrella):
            for source in ("import Nuke", "import LNPopupUI", "let bundle = Bundle.main",
                           "let store: NeteaseMusicStore", "let model: NowPlayingModel"):
                self.assertTrue(boundaries.check_source(path, source), (path, source))
        self.assertTrue(boundaries.check_source(core, "import FrontAMPlayer"))
        self.assertTrue(boundaries.check_source(core, "import FrontAM"))
        self.assertTrue(boundaries.check_source(boundaries.FRONTAM_PLAYER / "Player.swift", "import FrontAMPopup"))

    def test_popup_owns_ln_integration_and_consumes_host_interfaces(self):
        popup = boundaries.FRONTAM_POPUP / "PlayerPopup.swift"
        allowed = "import SwiftUI; import UIKit\nimport FrontAMPlayer\nimport LNPopupUI\nlet bar: LNPopupBar"
        self.assertEqual(boundaries.check_source(popup, allowed), [])
        for source in ("import Nuke", "import NukeUI", "import LNPopupController",
                       "let account: NeteaseAccount", "NowPlayingModel()", "ArtworkImagePipeline.prefetch([])",
                       "ArtworkView(artwork: .missing)", "LibraryToastCenter()", "AppLogger.ui", "Bundle.main"):
            self.assertTrue(boundaries.check_source(popup, source), source)
        adapter = Path("NeoMusic/Features/Player/Integration/PlayerPopup.swift")
        self.assertEqual(boundaries.check_source(adapter, "import FrontAMPopup"), [])
        self.assertTrue(boundaries.check_source(adapter, "import LNPopupUI"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Playback/Engine.swift"), "import FrontAMPopup"))

    def test_navigation_consumes_routes_and_chrome_from_its_host(self):
        nav = boundaries.FRONTAM_NAVIGATION / "FrontAMShell.swift"
        self.assertEqual(boundaries.check_source(nav, "import SwiftUI\nimport UIKit\nimport FrontAMCore"), [])
        for source in ("import FrontAMPopup", "import FrontAMPlayer", "import LNPopupUI", "import Nuke", "let route: LibraryRoute", "let preview: LibraryNavigationPreview",
                       "let account: NeteaseAccount", "AccountPage()", "MusicQualitySettingsPage()",
                       "let home: HomeMusicIntegration", "let artist: ArtistMusicIntegration",
                       "let search: SearchMusicIntegration", "let model: SearchPageModel", "let player: NowPlayingModel",
                       "PlaylistLibrary()", "LibraryToastCenter()", "AppDefaultsKey.appTabOrder",
                       "AppLogger.ui", "NavigationDiagnostics.event()"):
            self.assertTrue(boundaries.check_source(nav, source), source)
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Features/Library/CollectionMenu.swift"), "import FrontAMNavigation"), [])
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Playback/Engine.swift"), "import FrontAMNavigation"))

    def test_pages_only_consume_presentation_dependencies(self):
        path = boundaries.FRONTAM_PAGES / "Library/TrackList.swift"
        self.assertEqual(boundaries.check_source(path,
            "import UIKit\nimport FrontAMCore\nimport FrontAMNavigation\nlet item: LibrarySongItem"), [])
        for source in ("import Nuke", "import LNPopupUI", "import FrontAMPopup", "import FrontAMPlayer",
                       "let account: NeteaseAccount", "let player: NowPlayingModel",
                       "let library: PlaylistLibrary", "let queue: LibraryDownloads",
                       "LocalLibrary.playlistLibrary", "LocalArtworkImages.cached(url, pixels: 0)",
                       "let identity: CatalogRouteIdentity", '"netease:1"', '"netease-playlist:1"', '"catalog:album:1"',
                       '"home:playlist:1"', "HomeMusicIntegration()", "AccountPage()"):
            self.assertTrue(boundaries.check_source(path, source), source)

    def test_showcase_uses_only_frontam_and_native_frameworks(self):
        path = boundaries.FRONTAM_SHOWCASE / "Showcase.swift"
        self.assertEqual(boundaries.check_source(path, "import SwiftUI\nimport FrontAM\nlet song: LibrarySongItem"), [])
        for source in ("import Nuke", "import LNPopupUI", "import FrontAMPopup", "import NeoMusic",
                       "let player: NowPlayingModel", "let store: NeteaseMusicStore", '"网易云音乐"', "URLSession.shared"):
            self.assertTrue(boundaries.check_source(path, source), source)

    def test_component_adapter_is_owned_by_app_or_player_integration(self):
        for path in ("NeoMusic/App/Composition.swift", "NeoMusic/Features/Player/Integration/Adapter.swift"):
            for module in ("FrontAM", "FrontAMPlayer", "FrontAMCore"):
                self.assertEqual(boundaries.check_source(Path(path), "import " + module), [])
        for path in ("NeoMusic/Core/Netease/Client.swift", "NeoMusic/Core/Playback/Engine.swift",
                     "NeoMusic/Features/Library/Other.swift"):
            for module in ("FrontAM", "FrontAMPlayer", "FrontAMCore"):
                self.assertTrue(boundaries.check_source(Path(path), "import " + module))

    def test_local_and_player_sources_reject_online_business(self):
        for directory in ["Core/Library", "Core/Playback", "Features/Player", "Features/Library"]:
            with self.subTest(directory=directory):
                path = Path("NeoMusic") / directory / "Source.swift"
                self.assertTrue(boundaries.check_source(path, "let client: NeteaseAccountClient"))
                self.assertTrue(boundaries.check_source(path, "let session = URLSession.shared"))
                self.assertTrue(boundaries.check_source(path, "import Security"))

    def test_features_cannot_access_local_library_even_in_previews(self):
        for filename in ["Account/AccountPage.swift", "Library/ExamplePreview.swift", "Home/Helper.mm"]:
            with self.subTest(filename=filename):
                path = Path("NeoMusic/Features") / filename
                self.assertTrue(boundaries.check_source(path, "LocalLibrary.playlistLibrary"))
                self.assertTrue(boundaries.check_source(path, "LocalLibrary\n  .playlistLibrary"))
                self.assertEqual(boundaries.check_source(path, "playlistLibrary.playlists"), [])

        app = Path("NeoMusic/App/LocalLibraryComposition.swift")
        self.assertEqual(boundaries.check_source(app, "LocalLibrary.playlistLibrary"), [])

    def test_storage_folder_names_are_not_netease_type_references(self):
        path = Path("NeoMusic/Core/AppStoragePaths.swift")
        self.assertEqual(boundaries.check_source(path, 'let folder = "NeteaseMusic"'), [])
        self.assertEqual(boundaries.check_source(path, 'let file = "NeteaseAvatarDisplay.plist"'), [])
        self.assertTrue(boundaries.check_source(path, 'let client = NeteaseMusicClient()'))
        self.assertTrue(boundaries.check_source(path, r'let value = "\(NeteaseMusicClient.self)"'))

    def test_account_ui_cannot_own_credentials_or_transport(self):
        path = Path("NeoMusic/Features/Account/Account.swift")
        self.assertTrue(boundaries.check_source(path, "SecItemDelete(query)"))
        self.assertTrue(boundaries.check_source(path, "URLSession.shared.data(for: request)"))

    def test_netease_cannot_reach_local_state_or_ui(self):
        path = Path("NeoMusic/Core/Netease/Account.swift")
        self.assertTrue(boundaries.check_source(path, "LocalLibrary.player.stop()"))
        self.assertTrue(boundaries.check_source(path, "import SwiftUI"))

    def test_netease_uses_the_shared_imageio_decoder(self):
        self.assertEqual(boundaries.check_source(boundaries.FRONTAM_CORE / "ImageSourceThumbnail.swift",
                                                "import Foundation\nimport ImageIO"), [])
        for filename in ["NeteaseAvatarSnapshot.swift", "Account.swift"]:
            self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Netease") / filename, "import ImageIO"))

    def test_artist_image_filter_keeps_transport_in_netease(self):
        path = boundaries.FRONTAM_CORE / "ArtistDetailBackdrop.swift"
        self.assertEqual(boundaries.check_source(path, "import CoreImage.CIFilterBuiltins"), [])
        self.assertTrue(boundaries.check_source(path, "URLSession.shared"))
        self.assertTrue(boundaries.check_source(path, "let account: NeteaseAccount"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Netease/Client.swift"), "import CoreImage"))

    def test_album_color_processing_stays_in_its_renderer(self):
        path = boundaries.FRONTAM_CORE / "AlbumArtworkBackdrop.swift"
        self.assertEqual(boundaries.check_source(path, "import CoreImage.CIFilterBuiltins"), [])
        self.assertTrue(boundaries.check_source(path, "import FrontAMCore"))
        self.assertTrue(boundaries.check_source(path, "import FrontAMPlayer"))
        self.assertTrue(boundaries.check_source(path, "URLSession.shared"))
        self.assertTrue(boundaries.check_source(path, "let account: NeteaseAccount"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/App/FrontendReviewPreview.swift"), "import CoreImage"))

    def test_objective_c_and_renamed_sources_are_checked(self):
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Playback/Bridge.m"),
                                              "[NSURLSession sharedSession]; SecItemDelete(query);"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Features/Home/Helper.swift"),
                                              'let host = "https://music.163.com"'))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Modules/Other/Client.swift"), "import Foundation"))

    def test_network_monitor_belongs_to_the_music_service(self):
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Core/Netease/NeteaseMusicStore.swift"), "import Network"), [])
        for path in ["NeoMusic/App/OnlineMusicIntegration.swift", "NeoMusic/Core/Playback/LocalPlaybackEngine.swift",
                     "NeoMusic/Features/Library/PlaylistsPage.swift"]:
            self.assertTrue(boundaries.check_source(Path(path), "import Network"))

    def test_performance_logging_has_one_native_owner(self):
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Core/PerformanceDiagnostics.swift"), "import os"), [])
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Netease/Client.swift"), "import os"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Features/Home/HomeFeedView.swift"), "import os"))

    def test_resource_dependencies_have_concrete_owners(self):
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Core/Netease/NeteaseArtworkCache.swift"), "import Nuke"), [])
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Core/Netease/NeteasePageCache.swift"), "import SQLite3"), [])
        for module in ["Nuke", "SQLite3"]:
            self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Netease/Account.swift"), "import " + module))
            self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Library/LocalLibrary.swift"), "import " + module))

    def test_stream_decoder_has_one_host_owner(self):
        deck = Path("NeoMusic/Core/Playback/StreamingPlaybackDeck.swift")
        self.assertEqual(boundaries.check_source(deck, "@preconcurrency import AudioStreaming"), [])
        self.assertTrue(boundaries.check_source(deck, "let account: NeteaseAccount"))
        for path in ["NeoMusic/Core/Library/LocalLibrary.swift", "NeoMusic/Core/Netease/Client.swift",
                     boundaries.FRONTAM_PLAYER / "Shared/PlayerContracts.swift"]:
            self.assertTrue(boundaries.check_source(Path(path), "import AudioStreaming"))

    def test_player_shaders_are_scanned_in_their_owner(self):
        shader = boundaries.FRONTAM_PLAYER / "NowPlaying/NowPlayingStitchableShaders.metal"
        self.assertEqual(boundaries.check_source(shader, "#include <metal_stdlib>"), [])
        self.assertTrue(boundaries.check_source(boundaries.FRONTAM_CORE / shader.name, "#include <metal_stdlib>"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Features/Home/PlayerEDRShaders.metal"), "#include <metal_stdlib>"))
        self.assertTrue(boundaries.check_source(shader, "URLSession.shared"))
        self.assertTrue(boundaries.check_source(shader, "#include <NeoMusic/Bridge.h>"))

    def test_command_scans_nested_frontam_sources_and_unknown_modules(self):
        sources = {
            Path("NeoMusic/App.swift"): "import SwiftUI",
            boundaries.FRONTAM_UMBRELLA / "FrontAM.swift": "@_exported import FrontAMPlayer",
            boundaries.FRONTAM_CORE / "Nested/Artwork.swift": "let store: AppStoragePaths",
            boundaries.FRONTAM_PLAYER / "Nested/Shader.metal": '#include "../Nuke/Image.h"',
            boundaries.FRONTAM_PLAYER / "Nested/Bridge.hpp": '#include <LNPopupUI/Popup.h>',
            boundaries.FRONTAM_POPUP / "Nested/Bar.swift": "import Nuke",
            boundaries.FRONTAM_NAVIGATION / "Nested/Shell.swift": "AccountPage()",
            boundaries.FRONTAM_PAGES / "Nested/Detail.swift": "let library: PlaylistLibrary",
            boundaries.FRONTAM_SOURCES / "Unassigned/Extra.h": "@import LNPopupController;",
            boundaries.FRONTAM_SHOWCASE / "Nested/Examples.swift": "let app = AppContainer()",
        }
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for path, source in sources.items():
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text(source)
            errors = StringIO()
            with patch.object(boundaries, "ROOT", root), redirect_stderr(errors):
                self.assertEqual(boundaries.main(), 1)
            for path in list(sources)[2:]:
                self.assertIn(str(path), errors.getvalue())


if __name__ == "__main__":
    unittest.main()
