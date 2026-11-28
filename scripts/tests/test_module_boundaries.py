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

    def test_popup_adapter_belongs_to_player_integration(self):
        adapter = Path("NeoMusic/Features/Player/Integration/PlayerPopup.swift")
        self.assertEqual(boundaries.check_source(adapter, "import FrontAMPopup"), [])
        self.assertTrue(boundaries.check_source(adapter, "import LNPopupUI"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Playback/Engine.swift"), "import FrontAMPopup"))

    def test_navigation_and_pages_imports_stay_in_app_and_features(self):
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Features/Library/CollectionMenu.swift"), "import FrontAMNavigation"), [])
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Features/Library/CollectionMenu.swift"), "import FrontAMPages"), [])
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Playback/Engine.swift"), "import FrontAMNavigation"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Playback/Engine.swift"), "import FrontAMPages"))

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

    def test_netease_cannot_import_imageio_or_coreimage(self):
        for filename in ["NeteaseAvatarSnapshot.swift", "Account.swift"]:
            self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Netease") / filename, "import ImageIO"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Netease/Client.swift"), "import CoreImage"))
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
        for path in ["NeoMusic/Core/Library/LocalLibrary.swift", "NeoMusic/Core/Netease/Client.swift"]:
            self.assertTrue(boundaries.check_source(Path(path), "import AudioStreaming"))

    def test_player_shaders_are_scanned_in_their_owner(self):
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Features/Player/Custom.metal"), "#include <metal_stdlib>"), [])
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Features/Home/PlayerEDRShaders.metal"), "#include <metal_stdlib>"))

    def test_command_scans_host_sources(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            bad = root / "NeoMusic/Features/Home/Leak.swift"
            bad.parent.mkdir(parents=True, exist_ok=True)
            bad.write_text("import Nuke\n")
            errors = StringIO()
            with patch.object(boundaries, "ROOT", root), redirect_stderr(errors):
                self.assertEqual(boundaries.main(), 1)
            self.assertIn("NeoMusic/Features/Home/Leak.swift", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
