"""Exercise the cron adapter with real function logic and no network calls."""

import contextlib
from datetime import datetime, timedelta, timezone
import fcntl
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
APP_DIR = Path("/app") if Path("/app/check.py").is_file() else PROJECT / "container"
sys.path.insert(0, str(PROJECT / "function"))
sys.path.insert(0, str(APP_DIR))
SPEC = importlib.util.spec_from_file_location("cron_runtime", APP_DIR / "check.py")
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)
function = runtime.repository_function
NOW = datetime(2030, 1, 31, 12, 0, 0, tzinfo=timezone.utc)
REPOSITORY = "test-owner/test-repo"
TOKEN = "github_pat_test_secret"
CODEBERG_TOKEN = "codeberg_test_secret"
SCHEDULE = "0 0 * * * /usr/bin/python3 /app/check.py\n"


def repository(*, age=timedelta(days=31), public=False):
    return {
        "id": 123,
        "full_name": REPOSITORY,
        "private": not public,
        "visibility": "public" if public else "private",
        "pushed_at": (NOW - age).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def codeberg_repository(*, age=timedelta(days=31), public=False):
    return {
        "id": 123,
        "full_name": REPOSITORY,
        "private": not public,
        "internal": False,
        "updated_at": (NOW - age).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


class CronRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="server-runtime-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.settings = self.root / "config" / "settings.sh"
        self.crontab = self.root / "config" / "crontab"
        self.token = self.root / "credentials" / "repository_token"
        self.github_token = self.root / "credentials" / "github_token"
        self.data = self.root / "data"
        for directory in (self.settings.parent, self.token.parent, self.data):
            directory.mkdir()
        self.settings.write_text(
            "GITHUB_REPOSITORY='test-owner/test-repo'\n"
            "INACTIVITY_DAYS=30\nTZ='Etc/UTC'\n", encoding="utf-8"
        )
        self.crontab.write_text(SCHEDULE, encoding="utf-8")
        self.token.write_text(TOKEN + "\n", encoding="utf-8")
        for name, value in (
            ("SETTINGS_FILE", self.settings), ("CRONTAB_FILE", self.crontab),
            ("TOKEN_FILE", self.token), ("GITHUB_TOKEN_FILE", self.github_token),
            ("DATA_DIR", self.data),
        ):
            patcher = mock.patch.object(runtime, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        transport = mock.patch.object(function, "_github_request")
        self.transport = transport.start()
        self.addCleanup(transport.stop)
        clock = mock.patch.object(function, "_utc_now", return_value=NOW)
        clock.start()
        self.addCleanup(clock.stop)

    def run_main(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = runtime.main()
        return code, stdout.getvalue(), stderr.getvalue()

    def assert_schedule_retained(self):
        self.assertEqual(self.crontab.read_text(encoding="utf-8"), SCHEDULE)
        self.assertFalse((self.data / "completed.json").exists())

    def assert_schedule_removed(self):
        self.assertTrue(self.crontab.is_file())
        self.assertTrue(all(
            not line.strip() or line.lstrip().startswith("#")
            for line in self.crontab.read_text(encoding="utf-8").splitlines()
        ))

    def test_active_check_keeps_schedule_without_completion(self):
        self.transport.return_value = repository(age=timedelta(days=1))
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["status"], "active")
        self.assert_schedule_retained()
        self.transport.assert_called_once_with(REPOSITORY, TOKEN)

    def test_publication_records_completion_and_removes_schedule(self):
        self.transport.side_effect = [repository(), repository(), repository(public=True)]
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        result = json.loads(stdout)
        self.assertEqual(result["status"], "published")
        self.assertTrue(result["schedule_removed"])
        self.assert_schedule_removed()
        completed = json.loads((self.data / "completed.json").read_text(encoding="utf-8"))
        self.assertEqual(completed["repository"], REPOSITORY)
        self.assertEqual(completed["provider"], "github")
        self.assertEqual(completed["repository_id"], 123)
        self.assertIsInstance(completed["completed_at"], str)
        self.assertEqual(self.transport.call_count, 3)

    def test_completion_survives_restart_without_token_or_api(self):
        self.transport.return_value = repository(public=True)
        self.assertEqual(self.run_main()[0], 0)
        self.token.unlink()
        self.transport.reset_mock()
        self.crontab.write_text(SCHEDULE, encoding="utf-8")
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        self.assertTrue(json.loads(stdout)["schedule_removed"])
        self.assert_schedule_removed()
        self.transport.assert_not_called()

    def test_failed_removal_keeps_completion_and_retries_without_api(self):
        self.transport.return_value = repository(public=True)
        with mock.patch.object(runtime, "remove_schedule", side_effect=OSError(TOKEN)):
            code, stdout, stderr = self.run_main()
        self.assertEqual(code, 1)
        self.assertTrue((self.data / "completed.json").is_file())
        self.assertEqual(self.crontab.read_text(encoding="utf-8"), SCHEDULE)
        self.assertNotIn(TOKEN, stdout + stderr)
        self.transport.reset_mock()
        self.token.unlink()
        self.assertEqual(self.run_main()[0], 0)
        self.assert_schedule_removed()
        self.transport.assert_not_called()

    def test_completed_case_insensitive_repository_needs_no_token(self):
        (self.data / "completed.json").write_text(json.dumps({
            "repository": REPOSITORY.upper(), "repository_id": 123,
            "completed_at": NOW.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }), encoding="utf-8")
        self.token.unlink()
        code, _, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        self.assert_schedule_removed()
        self.transport.assert_not_called()

    def test_completion_for_another_repository_does_not_skip_check(self):
        (self.data / "completed.json").write_text(json.dumps({
            "repository": "another-owner/repo", "repository_id": 456,
            "completed_at": NOW.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }), encoding="utf-8")
        self.transport.return_value = repository(age=timedelta(days=1))
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["status"], "active")
        self.transport.assert_called_once_with(REPOSITORY, TOKEN)
        self.assertEqual(self.crontab.read_text(encoding="utf-8"), SCHEDULE)

    def test_corrupt_completion_never_calls_api_or_removes_schedule(self):
        (self.data / "completed.json").write_text("{broken", encoding="utf-8")
        code, _, stderr = self.run_main()
        self.assertEqual(code, 1)
        self.assertTrue(stderr)
        self.transport.assert_not_called()
        self.assertEqual(self.crontab.read_text(encoding="utf-8"), SCHEDULE)

    def test_api_error_keeps_schedule_and_does_not_record_completion(self):
        self.transport.side_effect = function.RepositoryCheckError("API unavailable")
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 1)
        self.assertNotIn(TOKEN, stdout + stderr)
        self.assert_schedule_retained()

    def test_settings_and_credentials_are_reread_without_restart(self):
        self.settings.write_text(
            "# Mounted configuration\nGITHUB_REPOSITORY='test-owner/test-repo' # target\n"
            "INACTIVITY_DAYS=60\nTZ='Etc/UTC'\n", encoding="utf-8"
        )
        self.transport.return_value = repository()
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["status"], "active")
        self.transport.assert_called_once_with(REPOSITORY, TOKEN)
        self.transport.reset_mock()
        self.transport.side_effect = [repository(), repository(), repository(public=True)]
        self.settings.write_text(
            "GITHUB_REPOSITORY='test-owner/test-repo'\nINACTIVITY_DAYS=30\nTZ='Etc/UTC'\n",
            encoding="utf-8",
        )
        self.token.write_text("github_pat_rotated_token\n", encoding="utf-8")
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["status"], "published")
        self.assertEqual(self.transport.call_count, 3)
        for call in self.transport.call_args_list:
            self.assertEqual(call.args[:2], (REPOSITORY, "github_pat_rotated_token"))

    def test_overlapping_check_skips_without_api(self):
        with (self.data / "check.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["status"], "skipped")
        self.transport.assert_not_called()
        self.assert_schedule_retained()

    def test_removed_schedule_is_not_rewritten_on_each_completed_check(self):
        self.transport.return_value = repository(public=True)
        self.assertEqual(self.run_main()[0], 0)
        previous = self.crontab.stat()
        self.transport.reset_mock()
        self.assertEqual(self.run_main()[0], 0)
        current = self.crontab.stat()
        self.assertEqual((current.st_ino, current.st_mtime_ns),
                         (previous.st_ino, previous.st_mtime_ns))
        self.transport.assert_not_called()

    def test_settings_do_not_execute_shell_commands(self):
        marker = self.root / "executed"
        self.settings.write_text(
            "GITHUB_REPOSITORY='test-owner/test-repo'\nINACTIVITY_DAYS=30\n"
            "touch '{}'\n".format(marker), encoding="utf-8"
        )
        code, _, _ = self.run_main()
        self.assertEqual(code, 1)
        self.assertFalse(marker.exists())
        self.transport.assert_not_called()
        self.assert_schedule_retained()

    def test_generic_github_settings_take_precedence_over_legacy_name(self):
        self.settings.write_text(
            "REPOSITORY_PROVIDER='github'\nREPOSITORY='test-owner/test-repo'\n"
            "GITHUB_REPOSITORY='legacy-owner/unused-repo'\nINACTIVITY_DAYS=30\n",
            encoding="utf-8",
        )
        self.transport.return_value = repository(age=timedelta(days=1))
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["status"], "active")
        self.transport.assert_called_once_with(REPOSITORY, TOKEN)
        self.assert_schedule_retained()

    def test_legacy_github_settings_and_token_file_remain_supported(self):
        self.token.unlink()
        self.github_token.write_text(TOKEN + "\n", encoding="utf-8")
        self.transport.return_value = repository(age=timedelta(days=1))
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["status"], "active")
        self.transport.assert_called_once_with(REPOSITORY, TOKEN)
        self.assert_schedule_retained()

    def test_codeberg_never_uses_legacy_github_token_file(self):
        self.settings.write_text(
            "REPOSITORY_PROVIDER='codeberg'\nREPOSITORY='test-owner/test-repo'\n"
            "INACTIVITY_DAYS=30\n", encoding="utf-8"
        )
        self.token.unlink()
        self.github_token.write_text(TOKEN + "\n", encoding="utf-8")
        with mock.patch.object(function, "_codeberg_request") as codeberg:
            code, stdout, stderr = self.run_main()
        self.assertEqual(code, 1)
        self.assertNotIn(TOKEN, stdout + stderr)
        codeberg.assert_not_called()
        self.transport.assert_not_called()
        self.assert_schedule_retained()

    def test_codeberg_requires_generic_repository_setting(self):
        self.settings.write_text(
            "REPOSITORY_PROVIDER='codeberg'\nGITHUB_REPOSITORY='test-owner/test-repo'\n"
            "INACTIVITY_DAYS=30\n", encoding="utf-8"
        )
        with mock.patch.object(function, "_codeberg_request") as codeberg:
            code, _, _ = self.run_main()
        self.assertEqual(code, 1)
        codeberg.assert_not_called()
        self.transport.assert_not_called()
        self.assert_schedule_retained()

    def test_codeberg_uses_generic_settings_and_token(self):
        self.settings.write_text(
            "REPOSITORY_PROVIDER='codeberg'\nREPOSITORY='test-owner/test-repo'\n"
            "INACTIVITY_DAYS=30\n", encoding="utf-8"
        )
        self.token.write_text(CODEBERG_TOKEN + "\n", encoding="utf-8")
        with mock.patch.object(function, "_codeberg_request") as codeberg:
            codeberg.return_value = codeberg_repository(age=timedelta(days=1))
            code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        result = json.loads(stdout)
        self.assertEqual(result["status"], "active")
        self.assertEqual(result["provider"], "codeberg")
        self.assertEqual(result["activity_source"], "updated_at")
        self.assertNotIn("pushed_at", result)
        codeberg.assert_called_once_with(REPOSITORY, CODEBERG_TOKEN)
        self.transport.assert_not_called()
        self.assert_schedule_retained()

    def test_completion_for_same_name_on_another_provider_does_not_skip_check(self):
        with mock.patch.object(function, "_codeberg_request") as codeberg:
            for completed_provider, current_provider in (
                (None, "codeberg"), ("github", "codeberg"), ("codeberg", "github")
            ):
                with self.subTest(completed=completed_provider, current=current_provider):
                    completion = {
                        "repository": REPOSITORY, "repository_id": 123,
                        "completed_at": NOW.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    }
                    if completed_provider is not None:
                        completion["provider"] = completed_provider
                    (self.data / "completed.json").write_text(
                        json.dumps(completion), encoding="utf-8"
                    )
                    self.settings.write_text(
                        "REPOSITORY_PROVIDER='{}'\nREPOSITORY='{}'\nINACTIVITY_DAYS=30\n"
                        .format(current_provider, REPOSITORY), encoding="utf-8"
                    )
                    self.transport.reset_mock()
                    codeberg.reset_mock()
                    self.transport.return_value = repository(age=timedelta(days=1))
                    codeberg.return_value = codeberg_repository(age=timedelta(days=1))
                    code, stdout, stderr = self.run_main()
                    self.assertEqual(code, 0, stderr)
                    result = json.loads(stdout)
                    self.assertEqual(result["status"], "active")
                    self.assertEqual(result["provider"], current_provider)
                    called, unused = ((codeberg, self.transport) if current_provider == "codeberg"
                                      else (self.transport, codeberg))
                    called.assert_called_once_with(REPOSITORY, TOKEN)
                    unused.assert_not_called()
                    self.assertEqual(self.crontab.read_text(encoding="utf-8"), SCHEDULE)

    def test_codeberg_completion_retries_cleanup_without_credentials_or_api(self):
        self.settings.write_text(
            "REPOSITORY_PROVIDER='codeberg'\nREPOSITORY='test-owner/test-repo'\n"
            "INACTIVITY_DAYS=30\n", encoding="utf-8"
        )
        self.token.write_text(CODEBERG_TOKEN + "\n", encoding="utf-8")
        with mock.patch.object(function, "_codeberg_request") as codeberg:
            codeberg.side_effect = [
                codeberg_repository(), codeberg_repository(), codeberg_repository(public=True)
            ]
            with mock.patch.object(runtime, "remove_schedule", side_effect=OSError(CODEBERG_TOKEN)):
                code, stdout, stderr = self.run_main()
            self.assertEqual(code, 1)
            self.assertNotIn(CODEBERG_TOKEN, stdout + stderr)
            completed = json.loads((self.data / "completed.json").read_text(encoding="utf-8"))
            self.assertEqual(completed["provider"], "codeberg")
            self.assertEqual(completed["repository"], REPOSITORY)
            self.assertEqual(codeberg.call_count, 3)
            self.assertEqual(codeberg.call_args.kwargs, {"method": "PATCH", "data": {"private": False}})
            self.assertEqual(self.crontab.read_text(encoding="utf-8"), SCHEDULE)
            codeberg.reset_mock()
            self.token.unlink()
            code, stdout, stderr = self.run_main()
            self.assertEqual(code, 0, stderr)
            result = json.loads(stdout)
            self.assertEqual(result["provider"], "codeberg")
            self.assertEqual(result["status"], "completed")
            self.assertTrue(result["schedule_removed"])
            self.assert_schedule_removed()
            codeberg.assert_not_called()
            self.transport.assert_not_called()


if __name__ == "__main__":
    unittest.main()
