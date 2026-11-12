import importlib.util
from pathlib import Path
import unittest

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

    def test_local_and_player_sources_reject_online_business(self):
        for directory in ["Core/Library", "Core/Playback", "Features/Player", "Features/Library"]:
            with self.subTest(directory=directory):
                path = Path("NeoMusic") / directory / "Source.swift"
                self.assertTrue(boundaries.check_source(path, "let client: NeteaseAccountClient"))
                self.assertTrue(boundaries.check_source(path, "let session = URLSession.shared"))
                self.assertTrue(boundaries.check_source(path, "import Security"))

    def test_account_ui_cannot_own_credentials_or_transport(self):
        path = Path("NeoMusic/Features/Account/Account.swift")
        self.assertTrue(boundaries.check_source(path, "SecItemDelete(query)"))
        self.assertTrue(boundaries.check_source(path, "URLSession.shared.data(for: request)"))

    def test_netease_cannot_reach_local_state_or_ui(self):
        path = Path("NeoMusic/Core/Netease/Account.swift")
        self.assertTrue(boundaries.check_source(path, "LocalLibrary.player.stop()"))
        self.assertTrue(boundaries.check_source(path, "import SwiftUI"))

    def test_imageio_is_limited_to_the_avatar_snapshot_source(self):
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Core/Netease/NeteaseAvatarSnapshot.swift"),
                                                "import Foundation\nimport ImageIO"), [])
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Netease/Account.swift"), "import ImageIO"))

    def test_artist_image_filter_keeps_transport_in_netease(self):
        path = Path("NeoMusic/Features/Library/ArtistDetailBackdrop.swift")
        self.assertEqual(boundaries.check_source(path, "import CoreImage.CIFilterBuiltins"), [])
        self.assertTrue(boundaries.check_source(path, "URLSession.shared"))
        self.assertTrue(boundaries.check_source(path, "let account: NeteaseAccount"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Core/Netease/Client.swift"), "import CoreImage"))

    def test_album_color_processing_stays_in_its_renderer(self):
        path = Path("NeoMusic/Features/Library/AlbumArtworkBackdrop.swift")
        self.assertEqual(boundaries.check_source(path, "import CoreImage.CIFilterBuiltins"), [])
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

    def test_player_shaders_are_scanned_in_their_owner(self):
        self.assertEqual(boundaries.check_source(Path("NeoMusic/Features/Player/PlayerEDRShaders.metal"), "#include <metal_stdlib>"), [])
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Features/Home/PlayerEDRShaders.metal"), "#include <metal_stdlib>"))
        self.assertTrue(boundaries.check_source(Path("NeoMusic/Features/Player/PlayerEDRShaders.metal"), "URLSession.shared"))


if __name__ == "__main__":
    unittest.main()
