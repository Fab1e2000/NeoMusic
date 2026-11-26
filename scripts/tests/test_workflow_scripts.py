import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
ZERO = "0" * 40


class AppSizeAuditTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="neomusic-app-audit-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.app = self.directory / "Sample.app"
        self.write("Info.plist", plistlib.dumps({"CFBundleExecutable": "MusicBinary"}))
        self.write("MusicBinary", b"binary")
        self.write("Assets.car", b'[{"Name":"ProductionArtwork"}]')
        command = self.directory / "assetutil"
        command.write_text('#!/bin/sh\n[ "$1" = "--info" ] || exit 2\ncat "$2"\n')
        command.chmod(0o755)

    def write(self, path, data):
        destination = self.app / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)

    def run_audit(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/audit-app-size.py"), str(self.app)],
            env={**os.environ, "PATH": f"{self.directory}{os.pathsep}{os.environ['PATH']}"},
            text=True, capture_output=True,
        )
        return result, json.loads(result.stdout)

    def test_reports_sizes_and_limits_other_files_to_ten(self):
        self.write("Frameworks/Player.framework/Player", b"x" * 200)
        for index in range(12):
            self.write(f"Resources/file-{index:02d}", b"x" * (300 + index))
        outside = self.directory / "outside"
        outside.write_bytes(b"x" * 900)
        (self.app / "alias").symlink_to(outside)

        result, report = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["main_executable"], {"path": "MusicBinary", "bytes": 6})
        self.assertEqual(report["frameworks"]["bytes"], 200)
        self.assertEqual(report["assets_car"]["bytes"], (self.app / "Assets.car").stat().st_size)
        sizes = [path.stat().st_size for path in self.app.rglob("*") if path.is_file() and not path.is_symlink()]
        self.assertEqual(report["total_bytes"], sum(sizes))
        other = report["other_top_files"]
        self.assertEqual(len(other), 10)
        self.assertEqual(other[0], {"path": "Resources/file-11", "bytes": 311})
        self.assertEqual(report["release_audit"]["inspected_catalogs"], ["Assets.car"])
        self.assertTrue(report["release_audit"]["clean"])

    def test_rejects_catalog_renditions_loose_previews_and_test_products(self):
        self.write("Assets.car", b'[{"Name":"AlbumSample01","RenditionName":"cover.jpg"}]')
        self.write("Frameworks/Player.framework/Assets.car", b'[{"RenditionName":"AlbumSample23@2x.png"}]')
        self.write("HomePreviewAssets.xcassets/Contents.json", b"{}")
        (self.app / "PlugIns/NeoMusicTests.xctest").mkdir(parents=True)
        self.write("Frameworks/libXCTestSwiftSupport.dylib", b"test")
        self.write("__preview.dylib", b"preview")

        result, report = self.run_audit()
        self.assertEqual(result.returncode, 1)
        audit = report["release_audit"]
        self.assertFalse(audit["clean"])
        self.assertEqual(audit["violations"], [
            {"path": "Assets.car", "kind": "preview_asset", "asset": "AlbumSample01"},
            {"path": "Frameworks/Player.framework/Assets.car", "kind": "preview_asset", "asset": "AlbumSample23@2x.png"},
            {"path": "Frameworks/libXCTestSwiftSupport.dylib", "kind": "test_artifact"},
            {"path": "HomePreviewAssets.xcassets", "kind": "preview_resource"},
            {"path": "PlugIns/NeoMusicTests.xctest", "kind": "test_artifact"},
            {"path": "__preview.dylib", "kind": "preview_resource"},
        ])

    def test_fails_when_a_catalog_cannot_be_inspected(self):
        self.write("Assets.car", b"corrupt")
        result, report = self.run_audit()
        self.assertEqual(result.returncode, 1)
        audit = report["release_audit"]
        self.assertFalse(audit["clean"])
        self.assertEqual(audit["inspected_catalogs"], [])
        self.assertEqual(audit["inspection_errors"][0]["path"], "Assets.car")


class RepositoryFixture(unittest.TestCase):
    def setUp(self):
        self.environment = os.environ.copy()
        for name in subprocess.check_output(["git", "rev-parse", "--local-env-vars"], text=True).splitlines():
            self.environment.pop(name, None)
        self.temporary = tempfile.TemporaryDirectory(prefix="neomusic-workflow-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.git("init", "-q")
        self.write(".gitignore", "build/\nbin/\n")

    def write(self, name, content):
        path = self.directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def executable(self, name, content):
        path = self.write(name, textwrap.dedent(content).lstrip())
        path.chmod(0o755)

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.directory,
                                       env=self.environment, text=True).strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=Workflow Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-qm", message)
        return self.git("rev-parse", "HEAD")


class PrePushTests(RepositoryFixture):
    def setUp(self):
        super().setUp()
        self.write("scripts/pre-push.sh", (ROOT / "scripts/pre-push.sh").read_text())
        self.write("scripts/ci.sh", '#!/bin/bash\necho "FIXTURE_CI"\nexit "${FIXTURE_CI_EXIT:-0}"\n')
        self.write("App.swift", "let value = 1\n")
        self.base = self.commit("base")
        self.git("update-ref", "refs/remotes/origin/main", self.base)

    def push(self, local, remote, extra="", environment=None):
        line = f"refs/heads/main {local} refs/heads/main {remote}\n"
        return subprocess.run(["bash", "scripts/pre-push.sh"], cwd=self.directory,
                              input=line + extra, text=True, capture_output=True,
                              env={**self.environment, **(environment or {})})

    def code_commit(self):
        self.write("App.swift", "let value = 2\n")
        return self.commit("code")

    def assert_ci(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("FIXTURE_CI"), 1)

    def test_clean_head_runs_ci(self):
        self.assert_ci(self.push(self.code_commit(), self.base))

    def test_docs_only_skips_ci_with_dirty_worktree(self):
        self.write("docs/guide.md", "guide\n")
        docs = self.commit("docs")
        self.write("App.swift", "uncommitted\n")
        result = self.push(docs, self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("FIXTURE_CI", result.stdout)

    def test_different_head_rejects_before_ci(self):
        code = self.code_commit()
        self.git("checkout", "-q", "--detach", self.base)
        result = self.push(code, self.base)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("FIXTURE_CI", result.stdout)

    def test_dirty_staged_and_untracked_inputs_reject_before_ci(self):
        code = self.code_commit()
        for kind in ("unstaged", "staged", "untracked"):
            with self.subTest(kind=kind):
                if kind == "untracked":
                    self.write("New.swift", "new\n")
                else:
                    self.write("App.swift", "uncommitted\n")
                    if kind == "staged":
                        self.git("add", "App.swift")
                result = self.push(code, self.base)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("FIXTURE_CI", result.stdout)
                self.git("reset", "--hard", "-q", code)
                (self.directory / "New.swift").unlink(missing_ok=True)

    def test_annotated_tag_resolves_to_head(self):
        code = self.code_commit()
        self.git("-c", "user.name=Workflow Fixture", "-c", "user.email=fixture@example.invalid",
                 "tag", "-a", "v1.0.0", "-m", "fixture")
        tag = self.git("rev-parse", "v1.0.0")
        self.assertNotEqual(tag, code)
        self.assert_ci(self.push(tag, ZERO))

    def test_multiple_refs_run_ci_once_and_allow_docs_only_other_commit(self):
        self.write("docs/guide.md", "guide\n")
        docs = self.commit("docs")
        code = self.code_commit()
        extra = f"refs/heads/docs {docs} refs/heads/docs {self.base}\n"
        self.assert_ci(self.push(code, docs, extra))

    def test_multiple_code_refs_must_all_match_head(self):
        code = self.code_commit()
        self.write("App.swift", "let value = 3\n")
        current = self.commit("more code")
        extra = f"refs/heads/older {code} refs/heads/older {self.base}\n"
        result = self.push(current, code, extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("FIXTURE_CI", result.stdout)

    def test_rename_source_into_docs_runs_ci(self):
        (self.directory / "docs").mkdir()
        self.git("mv", "App.swift", "docs/archive.md")
        renamed = self.commit("archive source")
        self.assert_ci(self.push(renamed, self.base))

    def test_new_root_and_unknown_base_use_complete_tree(self):
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        self.assert_ci(self.push(self.base, ZERO))
        self.write("docs/guide.md", "guide\n")
        docs = self.commit("docs after existing code")
        self.assert_ci(self.push(docs, ZERO))

    def test_missing_object_fails_closed(self):
        result = self.push(self.code_commit(), "f" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("FIXTURE_CI", result.stdout)

    def test_failed_worktree_inspection_fails_closed(self):
        code = self.code_commit()
        self.executable("bin/git", '''
            #!/bin/bash
            if [ "$1" = status ]; then exit 11; fi
            exec "$FIXTURE_REAL_GIT" "$@"
        ''')
        result = self.push(code, self.base, environment={
            "PATH": str(self.directory / "bin") + os.pathsep + os.environ["PATH"],
            "FIXTURE_REAL_GIT": shutil.which("git"),
        })
        self.assertEqual(result.returncode, 11)
        self.assertNotIn("FIXTURE_CI", result.stdout)

    def test_deleted_ref_skips_ci(self):
        result = self.push(ZERO, self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("FIXTURE_CI", result.stdout)

    def test_ci_failure_is_returned(self):
        result = self.push(self.code_commit(), self.base, environment={"FIXTURE_CI_EXIT": "7"})
        self.assertEqual(result.returncode, 7)


class CIRecordTests(RepositoryFixture):
    def setUp(self):
        super().setUp()
        self.write("scripts/ci.sh", (ROOT / "scripts/ci.sh").read_text())
        self.write("scripts/tests/test_gate.py", textwrap.dedent('''
            import os
            import unittest
            class GateTest(unittest.TestCase):
                def test_gate(self):
                    self.assertNotEqual(os.environ.get("FIXTURE_GATE_FAIL"), "1")
        '''))
        self.write("scripts/check-module-boundaries.py", 'print("FIXTURE_BOUNDARIES")\n')
        self.write("scripts/check-vendor-notices.py", 'print("FIXTURE_VENDOR_NOTICES")\n')
        self.executable("bin/swift", '''
            #!/bin/bash
            echo "FIXTURE_SWIFT $*"
            exit "${FIXTURE_SWIFT_EXIT:-0}"
        ''')
        self.executable("bin/xcodegen", '#!/bin/bash\necho "FIXTURE_XCODEGEN"\n')
        self.executable("bin/xcrun", '''
            #!/bin/bash
            echo '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"isAvailable":true,"name":"iPhone 18 Pro","state":"Booted","udid":"fixture"}]}}'
        ''')
        self.executable("bin/xcodebuild", '''
            #!/bin/bash
            echo "FIXTURE_XCODEBUILD"
            if [ "$1" = "-version" ]; then exit 0; fi
            mkdir -p build/ci/TestResults.xcresult
            exit "${FIXTURE_XCODE_EXIT:-0}"
        ''')
        self.head = self.commit("ci fixture")

    def run_ci(self, environment=None):
        return subprocess.run(["bash", "scripts/ci.sh"], cwd=self.directory, text=True,
                              capture_output=True, env={**self.environment,
                              "PATH": str(self.directory / "bin") + os.pathsep + os.environ["PATH"],
                              **(environment or {})})

    def state(self):
        return json.loads((self.directory / "build/ci/source-state.json").read_text())

    def test_success_records_clean_commit_without_paths(self):
        result = self.run_ci()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FIXTURE_VENDOR_NOTICES", result.stdout)
        self.assertIn("FIXTURE_SWIFT test --package-path Packages/AudioStreaming", result.stdout)
        self.assertIn("FIXTURE_SWIFT test --package-path Packages/AudioStreaming",
                      (self.directory / "build/ci/audio-streaming.log").read_text())
        state = self.state()
        self.assertEqual(state["commit"], self.head)
        self.assertFalse(state["dirty"])
        self.assertFalse(state["finishedDirty"])
        self.assertEqual(state["status"], "passed")
        self.assertEqual(state["exitCode"], 0)
        self.assertEqual(set(state), {"commit", "dirty", "finishedDirty", "startedAt",
                                     "finishedAt", "status", "exitCode"})

    def test_script_regression_failure_stops_before_build_and_records_failure(self):
        result = self.run_ci({"FIXTURE_GATE_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("FIXTURE_BOUNDARIES", result.stdout)
        self.assertNotIn("FIXTURE_XCODEGEN", result.stdout)
        self.assertEqual(self.state()["status"], "failed")

    def test_xcode_failure_and_dirty_state_are_recorded(self):
        self.write("PrivateFixture.swift", "local fixture\n")
        result = self.run_ci({"FIXTURE_XCODE_EXIT": "9"})
        self.assertEqual(result.returncode, 9)
        state = self.state()
        self.assertEqual(state["commit"], self.head)
        self.assertTrue(state["dirty"])
        self.assertTrue(state["finishedDirty"])
        self.assertEqual(state["status"], "failed")
        self.assertEqual(state["exitCode"], 9)
        self.assertNotIn("PrivateFixture", json.dumps(state))

    def test_package_test_failure_stops_before_build_and_records_failure(self):
        result = self.run_ci({"FIXTURE_SWIFT_EXIT": "8"})
        self.assertEqual(result.returncode, 8)
        self.assertNotIn("FIXTURE_XCODEGEN", result.stdout)
        self.assertEqual(self.state()["status"], "failed")

    def test_existing_result_is_rotated_with_its_source_record(self):
        self.write("build/ci/TestResults.xcresult/record", "latest result")
        self.write("build/ci/TestResults.previous.xcresult/obsolete", "older result")
        self.write("build/ci/source-state.json", '{"commit":"previous"}\n')
        result = self.run_ci()
        self.assertEqual(result.returncode, 0, result.stderr)
        previous = self.directory / "build/ci/TestResults.previous.xcresult"
        self.assertEqual((previous / "record").read_text(), "latest result")
        self.assertFalse((previous / "obsolete").exists())
        record = self.directory / "build/ci/source-state.previous.json"
        self.assertEqual(json.loads(record.read_text()), {"commit": "previous"})
        self.assertTrue((self.directory / "build/ci/TestResults.xcresult").is_dir())
        self.assertEqual(self.state()["commit"], self.head)

    def test_failure_before_xcode_preserves_the_previous_result_record(self):
        self.write("build/ci/TestResults.xcresult/record", "latest result")
        self.write("build/ci/source-state.json", '{"commit":"previous"}\n')
        for _ in range(2):
            result = self.run_ci({"FIXTURE_SWIFT_EXIT": "8"})
            self.assertEqual(result.returncode, 8)
        record = self.directory / "build/ci/source-state.previous.json"
        self.assertEqual(json.loads(record.read_text()), {"commit": "previous"})


class SmokeUIWorkflowTests(RepositoryFixture):
    def setUp(self):
        super().setUp()
        self.write("scripts/smoke-ui.sh", (ROOT / "scripts/smoke-ui.sh").read_text())
        self.executable("bin/xcrun", r'''
            #!/bin/bash
            printf '%s\n' "$FIXTURE_DEVICES"
        ''')
        self.executable("bin/xcodegen", '#!/bin/bash\necho "FIXTURE_XCODEGEN"\n')
        self.executable("bin/xcodebuild", r'''
            #!/bin/bash
            printf '%s\n' "$@"
            mkdir build/ci/SmokeUIResults.xcresult
            exit "${FIXTURE_XCODE_EXIT:-0}"
        ''')
        self.devices = {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
                {"isAvailable": True, "name": "iPhone 18 Pro", "state": "Shutdown", "udid": "stopped"},
                {"isAvailable": True, "name": "iPhone 18", "state": "Booted", "udid": "selected"},
                {"isAvailable": True, "name": "iPhone Duo", "state": "Booted", "udid": "duo"},
                {"isAvailable": False, "name": "iPhone 18 Pro", "state": "Booted", "udid": "unavailable"},
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {"isAvailable": True, "name": "iPhone 18 Pro", "state": "Booted", "udid": "old"},
            ],
        }

    def run_smoke(self, **environment):
        return subprocess.run(["bash", "scripts/smoke-ui.sh"], cwd=self.directory, text=True,
                              capture_output=True, env={**self.environment,
                              "PATH": str(self.directory / "bin") + os.pathsep + os.environ["PATH"],
                              "FIXTURE_DEVICES": json.dumps({"devices": self.devices}), **environment})

    def test_runs_only_smoke_in_debug_on_available_iphone_and_rotates_result(self):
        self.write("build/ci/SmokeUIResults.xcresult/current", "latest result")
        self.write("build/ci/SmokeUIResults.previous.xcresult/old", "older result")
        result = self.run_smoke(NEOMUSIC_DERIVED_DATA="build/custom")
        self.assertEqual(result.returncode, 0, result.stderr)
        log = (self.directory / "build/ci/smoke-ui.log").read_text()
        self.assertIn("-configuration\nDebug", log)
        self.assertIn("platform=iOS Simulator,id=selected", log)
        self.assertIn("-only-testing:NeoMusicNavigationUITests/SmokeJourneyUITests", log)
        self.assertIn("-derivedDataPath\nbuild/custom", log)
        self.assertIn("-parallel-testing-enabled\nNO", log)
        self.assertTrue((self.directory / "build/ci/SmokeUIResults.xcresult").is_dir())
        self.assertTrue((self.directory / "build/ci/SmokeUIResults.previous.xcresult/current").exists())
        self.assertFalse((self.directory / "build/ci/SmokeUIResults.previous.xcresult/old").exists())
        self.assertIn("Smoke UI 通过", result.stdout)

    def test_xcodebuild_failure_survives_tee(self):
        result = self.run_smoke(FIXTURE_XCODE_EXIT="27")
        self.assertEqual(result.returncode, 27)
        self.assertIn("Smoke UI 失败", result.stderr)
        self.assertTrue((self.directory / "build/ci/smoke-ui.log").exists())

    def test_missing_simulator_leaves_existing_result_in_place(self):
        del self.devices["com.apple.CoreSimulator.SimRuntime.iOS-27-1"]
        self.write("build/ci/SmokeUIResults.xcresult/current", "latest result")
        result = self.run_smoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("需要已安装 iOS 27", result.stderr)
        self.assertNotIn("FIXTURE_XCODEGEN", result.stdout)
        self.assertTrue((self.directory / "build/ci/SmokeUIResults.xcresult/current").exists())


class VendorBaselineTests(unittest.TestCase):
    def test_baseline_lists_documented_scopes_and_file_fingerprints(self):
        output = subprocess.check_output(
            [sys.executable, str(ROOT / "scripts/check-vendor-notices.py"), "--baseline"], text=True)
        for package_path, revision, file in [
            ("FrontAM/Vendor/LNPopupController", "fe0d1b8ce3c6464a63f0dc5e82d4c1b641adb8cc", "Package.swift"),
            ("FrontAM/Vendor/LNPopupUI", "60853564423524c9ed15cc74c5969d3e1ca666f1", "Sources/LNPopupUI/LNPopupUI.swift"),
            ("AudioStreaming", "3b937b3682f6274ef6157aef156cd59d32ba3dc5", None),
            ("AudioTags", "deadc2990767dfbda0701e0ab35fdeea653db08f", "Sources/AudioTagBridge/AudioTagBridge.mm"),
        ]:
            package = ROOT / "Packages" / package_path
            self.assertIn(f"\n{package.name} (", output)
            self.assertIn(revision, output)
            if file:
                digest = hashlib.sha256((package / file).read_bytes()).hexdigest()
                self.assertIn(f"{digest}  {file}", output)
        self.assertRegex(output, r"[a-f0-9]{64}  Sources/AudioStreaming/Streaming/.+\.swift")


class ReleaseDraftTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="neomusic-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        lines = (ROOT / ".github/workflows/release.yml").read_text().splitlines()
        step = lines.index("      - name: Create or update draft release")
        start = lines.index("        run: |", step) + 1
        body = []
        for line in lines[start:]:
            if line.startswith("      - "):
                break
            body.append(line[10:])
        self.script = "\n".join(body)
        (self.directory / "dist").mkdir()
        (self.directory / "dist/fixture.ipa").touch()
        (self.directory / "dist/SHA256SUMS.txt").touch()
        stub = self.directory / "gh"
        stub.write_text(textwrap.dedent('''
            #!/usr/bin/env python3
            import json, os, sys
            from pathlib import Path
            with Path("commands.jsonl").open("a") as output:
                output.write(json.dumps(sys.argv[1:]) + "\\n")
            if sys.argv[1] == "api":
                mode = os.environ["FIXTURE_RELEASE_STATE"]
                if mode == "missing":
                    print("HTTP/2.0 404 Not Found\\r\\n\\r\\n{}")
                    sys.exit(1)
                if mode == "error":
                    print("HTTP/2.0 500 Internal Server Error\\r\\n\\r\\n{}")
                    sys.exit(1)
                if mode == "transport":
                    sys.exit(1)
                draft = {"draft": "true", "published": "false", "invalid": "null"}[mode]
                print("HTTP/2.0 200 OK\\r\\nContent-Type: application/json\\r\\n\\r\\n" + draft)
            elif sys.argv[1:3] == ["release", "upload"]:
                sys.exit(int(os.environ.get("FIXTURE_UPLOAD_EXIT", "0")))
        ''').lstrip())
        stub.chmod(0o755)

    def run_release(self, state, environment=None):
        result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.script],
                                cwd=self.directory, text=True, capture_output=True,
                                env={**os.environ, "TAG": "v1.2.3", "FIXTURE_RELEASE_STATE": state,
                                     "PATH": str(self.directory) + os.pathsep + os.environ["PATH"],
                                     **(environment or {})})
        commands = [json.loads(line) for line in (self.directory / "commands.jsonl").read_text().splitlines()]
        writes = [command for command in commands if command[0] == "release"]
        return result, writes

    def test_missing_release_creates_only_a_draft(self):
        result, writes = self.run_release("missing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0][:2], ["release", "create"])
        self.assertIn("--draft", writes[0])
        self.assertIn("--verify-tag", writes[0])

    def test_existing_draft_keeps_draft_state(self):
        result, writes = self.run_release("draft")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([command[1] for command in writes], ["upload", "edit"])
        self.assertIn("--draft", writes[1])
        self.assertNotIn("--latest", writes[1])

    def test_published_release_has_no_writes(self):
        result, writes = self.run_release("published")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(writes, [])

    def test_lookup_failures_and_invalid_state_have_no_writes(self):
        for state in ("error", "transport", "invalid"):
            with self.subTest(state=state):
                (self.directory / "commands.jsonl").unlink(missing_ok=True)
                result, writes = self.run_release(state)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(writes, [])

    def test_failed_draft_upload_stops_before_edit(self):
        result, writes = self.run_release("draft", {"FIXTURE_UPLOAD_EXIT": "8"})
        self.assertEqual(result.returncode, 8)
        self.assertEqual([command[1] for command in writes], ["upload"])


if __name__ == "__main__":
    unittest.main()
