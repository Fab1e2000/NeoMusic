import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
ZERO = "0" * 40


class RepositoryFixture(unittest.TestCase):
    def setUp(self):
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
        return subprocess.check_output(["git", *arguments], cwd=self.directory, text=True).strip()

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
                              env={**os.environ, **(environment or {})})

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

    def test_result_and_source_record_are_archived_together(self):
        code = self.code_commit()
        (self.directory / "build/ci/TestResults.xcresult").mkdir(parents=True)
        self.write("build/ci/source-state.json", '{"commit":"previous"}\n')
        self.assert_ci(self.push(code, self.base))
        self.assertTrue((self.directory / "build/ci/TestResults.previous.xcresult").is_dir())
        self.assertEqual(json.loads((self.directory / "build/ci/source-state.previous.json").read_text()),
                         {"commit": "previous"})


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
                              capture_output=True, env={**os.environ,
                              "PATH": str(self.directory / "bin") + os.pathsep + os.environ["PATH"],
                              **(environment or {})})

    def state(self):
        return json.loads((self.directory / "build/ci/source-state.json").read_text())

    def test_success_records_clean_commit_without_paths(self):
        result = self.run_ci()
        self.assertEqual(result.returncode, 0, result.stderr)
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

    def test_existing_result_preserves_its_source_record(self):
        (self.directory / "build/ci/TestResults.xcresult").mkdir(parents=True)
        self.write("build/ci/source-state.json", '{"commit":"previous"}\n')
        result = self.run_ci()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state(), {"commit": "previous"})
        self.assertNotIn("FIXTURE_XCODEGEN", result.stdout)


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
