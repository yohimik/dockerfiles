"""Exercise the composite action adapter without making network requests."""

import contextlib
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from urllib.error import URLError


ACTION_DIR = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("server_check_action", ACTION_DIR / "run.py")
action = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(action)
server = action.server
NOW = datetime(2030, 1, 31, 12, 0, 0, tzinfo=timezone.utc)
REPOSITORY = "test-owner/test-repo"
TOKEN = "github_pat_action_test_secret"


def repository(*, provider="github", age=timedelta(days=1), public=False):
    result = {
        "id": 123,
        "full_name": REPOSITORY,
        "private": not public,
    }
    activity_at = (NOW - age).strftime("%Y-%m-%dT%H:%M:%SZ")
    if provider == "github":
        result.update(visibility="public" if public else "private", pushed_at=activity_at)
    else:
        result.update(internal=False, updated_at=activity_at)
    return result


def read_outputs(path):
    """Read GitHub's single-line and delimited multiline output records."""
    lines = iter(path.read_text(encoding="utf-8").splitlines())
    result = {}
    for line in lines:
        if "<<" in line:
            key, delimiter = line.split("<<", 1)
            value = []
            for following in lines:
                if following == delimiter:
                    break
                value.append(following)
            else:
                raise AssertionError("unterminated output record")
            result[key] = "\n".join(value)
        else:
            key, value = line.split("=", 1)
            result[key] = value
    return result


class CompositeActionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="server-action-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = self.root / "github-output"
        self.env = {
            "REPOSITORY": REPOSITORY,
            "REPOSITORY_TOKEN": TOKEN,
            "GITHUB_OUTPUT": str(self.output),
        }
        for name in ("_github_request", "_codeberg_request"):
            patcher = mock.patch.object(server, name)
            setattr(self, name[1:], patcher.start())
            self.addCleanup(patcher.stop)
        clock = mock.patch.object(server, "_utc_now", return_value=NOW)
        clock.start()
        self.addCleanup(clock.stop)
        # A missed transport mock must never turn these tests into a live check.
        network = mock.patch("socket.create_connection", side_effect=AssertionError("network forbidden"))
        network.start()
        self.addCleanup(network.stop)

    def run_main(self, **settings):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, dict(self.env, **settings), clear=True):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = action.main()
        return code, stdout.getvalue(), stderr.getvalue()

    def assert_no_outputs(self):
        if self.output.exists():
            self.assertEqual(self.output.read_text(encoding="utf-8"), "")

    def test_default_github_check_exports_machine_readable_outputs(self):
        self.github_request.return_value = repository()
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        result = json.loads(stdout)
        outputs = read_outputs(self.output)
        self.assertEqual(result, json.loads(outputs["result"]))
        self.assertEqual(result["provider"], "github")
        self.assertEqual(outputs["status"], "active")
        self.assertEqual(outputs["stop-schedule"], "false")
        self.assertEqual(outputs["activity-source"], "pushed_at")
        self.assertEqual(outputs["activity-at"], result["activity_at"])
        self.assertEqual(len(stdout.splitlines()), 1)
        self.assertEqual(len(outputs["result"].splitlines()), 1)
        self.assertNotIn(TOKEN, stdout + stderr + self.output.read_text())
        self.github_request.assert_called_once_with(REPOSITORY, TOKEN)
        self.codeberg_request.assert_not_called()

    def test_codeberg_publishes_and_reports_stop_without_removing_a_schedule(self):
        stale = repository(provider="codeberg", age=timedelta(days=31))
        public = repository(provider="codeberg", public=True)
        self.codeberg_request.side_effect = [stale, dict(stale), public]
        code, stdout, stderr = self.run_main(REPOSITORY_PROVIDER="codeberg")
        self.assertEqual(code, 0, stderr)
        result = json.loads(stdout)
        outputs = read_outputs(self.output)
        self.assertEqual(result["provider"], "codeberg")
        self.assertEqual(outputs["status"], "published")
        self.assertEqual(outputs["stop-schedule"], "true")
        self.assertEqual(outputs["activity-source"], "updated_at")
        self.assertFalse(result["schedule_removed"])
        self.assertNotIn("pushed_at", result)
        self.assertEqual(self.codeberg_request.call_count, 3)
        self.assertEqual(self.codeberg_request.call_args.kwargs,
                         {"method": "PATCH", "data": {"private": False}})
        self.github_request.assert_not_called()

    def test_custom_inactivity_threshold_reaches_the_server_script(self):
        self.github_request.return_value = repository(age=timedelta(days=31))
        code, stdout, stderr = self.run_main(INACTIVITY_DAYS="60")
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["status"], "active")
        self.github_request.assert_called_once_with(REPOSITORY, TOKEN)

    def test_invalid_inputs_fail_before_api_without_outputs(self):
        for settings in (
            {"REPOSITORY_PROVIDER": "unsupported"},
            {"INACTIVITY_DAYS": "0"},
            {"INACTIVITY_DAYS": "bad"},
            {"REPOSITORY": "owner/repo; touch injected"},
            {"REPOSITORY_TOKEN": ""},
        ):
            with self.subTest(settings=list(settings)):
                code, stdout, stderr = self.run_main(**settings)
                self.assertNotEqual(code, 0)
                self.assertNotIn(TOKEN, stdout + stderr)
                self.assert_no_outputs()
                self.github_request.assert_not_called()
                self.codeberg_request.assert_not_called()

    def test_missing_or_unwritable_output_fails_before_api(self):
        for target in ("", str(self.root), str(self.root / "missing" / "output")):
            with self.subTest(output=target):
                code, stdout, stderr = self.run_main(GITHUB_OUTPUT=target)
                self.assertNotEqual(code, 0)
                self.assertNotIn(TOKEN, stdout + stderr)
                self.github_request.assert_not_called()
                self.codeberg_request.assert_not_called()
                self.assert_no_outputs()

    def test_api_errors_propagate_without_false_success_outputs(self):
        self.github_request.side_effect = server.RepositoryCheckError("Provider unavailable")
        code, stdout, stderr = self.run_main()
        self.assertNotEqual(code, 0)
        self.assertIn("Provider unavailable", stderr)
        self.assertNotIn(TOKEN, stdout + stderr)
        self.assert_no_outputs()

    def test_transport_error_does_not_expose_credentials(self):
        # Exercise the shared transport's real sanitization through server.main.
        self.github_request.side_effect = lambda *args, **kwargs: server._request(
            *args, method="GET", data=None, provider="github"
        )
        opener = mock.Mock()
        opener.open.side_effect = URLError(TOKEN)
        with mock.patch.object(server, "build_opener", return_value=opener):
            code, stdout, stderr = self.run_main()
        self.assertNotEqual(code, 0)
        self.assertNotIn(TOKEN, stdout + stderr)
        self.assert_no_outputs()

    def test_existing_outputs_are_preserved_when_appending_result(self):
        self.output.write_text("previous=value\n", encoding="utf-8")
        self.github_request.return_value = repository()
        code, _, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        outputs = read_outputs(self.output)
        self.assertEqual(outputs["previous"], "value")
        self.assertEqual(outputs["status"], "active")

    def test_public_repository_without_activity_has_empty_activity_output(self):
        self.github_request.return_value = dict(repository(public=True), pushed_at=None)
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        outputs = read_outputs(self.output)
        self.assertEqual(outputs["status"], "already_public")
        self.assertEqual(outputs["activity-at"], "")
        self.assertEqual(outputs["stop-schedule"], "true")
        self.assertIsNone(json.loads(stdout)["activity_at"])

    def test_untrusted_activity_text_cannot_inject_extra_outputs(self):
        activity = "2030-01-01T00:00:00Z\nstop-schedule=false\ninjected=unexpected"
        self.github_request.return_value = dict(repository(public=True), pushed_at=activity)
        code, stdout, stderr = self.run_main()
        self.assertEqual(code, 0, stderr)
        outputs = read_outputs(self.output)
        self.assertEqual(outputs["stop-schedule"], "true")
        self.assertNotIn("injected", outputs)
        self.assertEqual(outputs["activity-at"], activity)
        self.assertEqual(len(stdout.splitlines()), 1)

    def test_bundled_server_resolution_does_not_depend_on_callers_directory(self):
        # A consuming repository may have its own unrelated main.py.
        (self.root / "main.py").write_text("raise RuntimeError('wrong server imported')\n")
        original_directory = Path.cwd()
        try:
            os.chdir(self.root)
            isolated_spec = importlib.util.spec_from_file_location(
                "server_check_action_other_cwd", ACTION_DIR / "run.py"
            )
            isolated = importlib.util.module_from_spec(isolated_spec)
            isolated_spec.loader.exec_module(isolated)
            expected = ACTION_DIR.parents[2] / "images/laptop-location-server/function/main.py"
            self.assertEqual(Path(isolated.server.__file__).resolve(), expected.resolve())
            response = repository()
            with mock.patch.object(isolated.server, "_github_request", return_value=response) as transport:
                with mock.patch.object(isolated.server, "_utc_now", return_value=NOW):
                    stdout, stderr = io.StringIO(), io.StringIO()
                    with mock.patch.dict(os.environ, self.env, clear=True):
                        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                            code = isolated.main()
            self.assertEqual(code, 0, stderr.getvalue())
            self.assertEqual(json.loads(stdout.getvalue())["status"], "active")
            transport.assert_called_once_with(REPOSITORY, TOKEN)
        finally:
            os.chdir(original_directory)


if __name__ == "__main__":
    unittest.main()
