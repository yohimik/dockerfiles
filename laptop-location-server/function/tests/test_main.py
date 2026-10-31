"""Provider-independent checks; every GitHub request is mocked."""

import contextlib
import copy
import gc
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import sys
import unittest
import warnings
from datetime import datetime, timedelta, timezone
from http.client import IncompleteRead
from unittest import mock
from urllib.error import HTTPError, URLError


MODULE_PATH = Path(__file__).resolve().parents[1] / "main.py"
SPEC = importlib.util.spec_from_file_location("repository_function", MODULE_PATH)
function = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = function
SPEC.loader.exec_module(function)

NOW = datetime(2030, 1, 31, 12, 0, 0, tzinfo=timezone.utc)
REPOSITORY = "test-owner/test-repo"
TOKEN = "github_pat_test_secret"


def repository(age=timedelta(days=31), *, public=False, repository_id=123):
    return {
        "id": repository_id,
        "full_name": REPOSITORY,
        "private": not public,
        "visibility": "public" if public else "private",
        "pushed_at": (NOW - age).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


class CheckRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.clock = mock.patch.object(function, "_utc_now", return_value=NOW)
        self.clock.start()
        self.addCleanup(self.clock.stop)
        self.transport_patch = mock.patch.object(function, "_github_request")
        self.transport = self.transport_patch.start()
        self.addCleanup(self.transport_patch.stop)
        self.disable = mock.Mock()

    def check(self, **kwargs):
        return function.check_repository(
            REPOSITORY, TOKEN, disable_schedule=self.disable, **kwargs
        )

    def assert_active(self, result):
        self.assertEqual(result["status"], "active")
        self.assertFalse(result["stop_schedule"])
        self.assertFalse(result["schedule_removed"])
        self.disable.assert_not_called()

    def test_recent_push_keeps_schedule(self):
        self.transport.return_value = repository(timedelta(days=1))
        self.assert_active(self.check())
        self.transport.assert_called_once()

    def test_exactly_30_days_keeps_schedule(self):
        self.transport.return_value = repository(timedelta(days=30))
        self.assert_active(self.check())
        self.transport.assert_called_once()

    def test_one_second_over_30_days_publishes_and_removes_schedule(self):
        stale = repository(timedelta(days=30, seconds=1))
        public = dict(stale, private=False, visibility="public")
        self.transport.side_effect = [stale, copy.deepcopy(stale), public]
        result = self.check()
        self.assertEqual(result["status"], "published")
        self.assertTrue(result["stop_schedule"])
        self.assertTrue(result["schedule_removed"])
        self.assertEqual(self.transport.call_count, 3)
        self.disable.assert_called_once_with()
        args, kwargs = self.transport.call_args
        self.assertEqual(args[:2], (REPOSITORY, TOKEN))
        method = kwargs.get("method", args[2] if len(args) > 2 else "GET")
        data = kwargs.get("data", args[3] if len(args) > 3 else None)
        self.assertEqual(method, "PATCH")
        self.assertEqual(data, {"visibility": "public"})

    def test_custom_threshold_is_used(self):
        self.transport.return_value = repository(timedelta(days=31))
        self.assert_active(self.check(inactivity_days=60))

    def test_push_arriving_before_recheck_prevents_publication(self):
        self.transport.side_effect = [repository(), repository(timedelta(seconds=1))]
        self.assert_active(self.check())
        self.assertEqual(self.transport.call_count, 2)

    def test_already_public_repository_removes_schedule_without_push_date(self):
        self.transport.return_value = dict(repository(public=True), pushed_at=None)
        result = self.check()
        self.assertEqual(result["status"], "already_public")
        self.assertTrue(result["stop_schedule"])
        self.assertTrue(result["schedule_removed"])
        self.transport.assert_called_once()
        self.disable.assert_called_once_with()

    def test_public_on_recheck_needs_no_patch(self):
        self.transport.side_effect = [repository(), repository(public=True)]
        result = self.check()
        self.assertEqual(result["status"], "already_public")
        self.assertEqual(self.transport.call_count, 2)
        self.disable.assert_called_once_with()

    def test_no_callback_requests_scheduler_cleanup_in_result(self):
        self.transport.return_value = repository(public=True)
        result = function.check_repository(REPOSITORY, TOKEN)
        self.assertTrue(result["stop_schedule"])
        self.assertFalse(result["schedule_removed"])

    def test_bad_push_timestamps_never_publish(self):
        for value in (None, "", "not-a-date", "2030-02-31T00:00:00Z", 123,
                      "2030-02-01T12:00:00Z"):
            with self.subTest(pushed_at=value):
                self.transport.reset_mock()
                self.transport.return_value = dict(repository(), pushed_at=value)
                with self.assertRaises(function.RepositoryCheckError):
                    self.check()
                self.transport.assert_called_once()
                self.disable.assert_not_called()

    def test_bad_push_timestamp_on_recheck_never_publishes(self):
        self.transport.side_effect = [repository(), dict(repository(), pushed_at=None)]
        with self.assertRaises(function.RepositoryCheckError):
            self.check()
        self.assertEqual(self.transport.call_count, 2)
        self.disable.assert_not_called()

    def test_repository_identity_change_never_publishes(self):
        self.transport.side_effect = [repository(), repository(repository_id=456)]
        with self.assertRaises(function.RepositoryCheckError):
            self.check()
        self.assertEqual(self.transport.call_count, 2)
        self.disable.assert_not_called()

    def test_wrong_repository_response_never_publishes(self):
        self.transport.return_value = dict(repository(), full_name="other-owner/repo")
        with self.assertRaises(function.RepositoryCheckError):
            self.check()
        self.transport.assert_called_once()
        self.disable.assert_not_called()

    def test_repository_name_matching_is_case_insensitive(self):
        self.transport.return_value = dict(repository(public=True), full_name=REPOSITORY.upper())
        result = self.check()
        self.assertEqual(result["status"], "already_public")

    def test_malformed_repository_responses_never_publish(self):
        for response in (None, [], {}, dict(repository(), id=True),
                         dict(repository(), private=False), dict(repository(), id=0)):
            with self.subTest(response=response):
                self.transport.reset_mock()
                self.transport.return_value = response
                with self.assertRaises(function.RepositoryCheckError):
                    self.check()
                self.transport.assert_called_once()
                self.disable.assert_not_called()

    def test_patch_failure_keeps_schedule(self):
        self.transport.side_effect = [repository(), repository(),
                                      function.RepositoryCheckError("API failed")]
        with self.assertRaises(function.RepositoryCheckError):
            self.check()
        self.disable.assert_not_called()

    def test_unconfirmed_public_visibility_keeps_schedule(self):
        self.transport.side_effect = [repository(), repository(), repository()]
        with self.assertRaises(function.RepositoryCheckError):
            self.check()
        self.disable.assert_not_called()

    def test_patch_identity_mismatch_keeps_schedule(self):
        self.transport.side_effect = [repository(), repository(),
                                      repository(public=True, repository_id=456)]
        with self.assertRaises(function.RepositoryCheckError):
            self.check()
        self.disable.assert_not_called()

    def test_callback_failure_can_retry_on_next_invocation(self):
        self.transport.side_effect = [repository(), repository(), repository(public=True)]
        self.disable.side_effect = RuntimeError("scheduler unavailable: " + TOKEN)
        with self.assertRaises(function.RepositoryCheckError) as raised:
            self.check()
        self.assertNotIn(TOKEN, str(raised.exception))
        self.disable.assert_called_once_with()
        self.transport.reset_mock(side_effect=True)
        self.transport.return_value = repository(public=True)
        self.disable.reset_mock(side_effect=True)
        result = self.check()
        self.assertEqual(result["status"], "already_public")
        self.assertTrue(result["schedule_removed"])
        self.transport.assert_called_once()
        self.disable.assert_called_once_with()

    def test_async_callback_is_rejected_before_api_call(self):
        callback_body = mock.Mock()

        async def disable_schedule():
            callback_body()

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always", RuntimeWarning)
            with self.assertRaises(ValueError):
                function.check_repository(REPOSITORY, TOKEN, disable_schedule=disable_schedule)
            gc.collect()
        self.transport.assert_not_called()
        callback_body.assert_not_called()
        self.assertFalse([item for item in caught if issubclass(item.category, RuntimeWarning)])

    def test_sync_callback_returning_coroutine_is_closed_and_reports_failure(self):
        self.transport.return_value = repository(public=True)
        callback_body = mock.Mock()
        returned_coroutines = []

        async def remove_schedule():
            callback_body()

        def disable_schedule():
            coroutine = remove_schedule()
            returned_coroutines.append(coroutine)
            return coroutine

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always", RuntimeWarning)
            with self.assertRaises(function.RepositoryCheckError):
                function.check_repository(REPOSITORY, TOKEN, disable_schedule=disable_schedule)
            self.assertEqual(len(returned_coroutines), 1)
            self.assertEqual(inspect.getcoroutinestate(returned_coroutines[0]), inspect.CORO_CLOSED)
            returned_coroutines.clear()
            gc.collect()
        self.transport.assert_called_once()
        callback_body.assert_not_called()
        self.assertFalse([item for item in caught if issubclass(item.category, RuntimeWarning)])

    def test_invalid_configuration_never_calls_api(self):
        for repo in ("", "owner", "owner/repo/extra", "../repo", "owner/.."):
            with self.subTest(repository=repo):
                with self.assertRaises(ValueError):
                    function.check_repository(repo, TOKEN)
        for token in ("", "token\nheader", "token\rheader"):
            with self.subTest(token=token):
                with self.assertRaises(ValueError):
                    function.check_repository(REPOSITORY, token)
        for days in (0, -1, True, 1.5):
            with self.subTest(inactivity_days=days):
                with self.assertRaises(ValueError):
                    function.check_repository(REPOSITORY, TOKEN, days)
        with self.assertRaises(ValueError):
            function.check_repository(REPOSITORY, TOKEN, disable_schedule="invalid")
        self.transport.assert_not_called()


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.opener = mock.MagicMock()
        self.response = self.opener.open.return_value.__enter__.return_value
        self.response.status = 200
        self.response.read.return_value = json.dumps(repository()).encode("utf-8")
        self.build_patch = mock.patch.object(function, "build_opener", return_value=self.opener)
        self.build = self.build_patch.start()
        self.addCleanup(self.build_patch.stop)

    def test_request_uses_authenticated_https_and_parses_json(self):
        result = function._github_request(REPOSITORY, TOKEN, method="PATCH", data={"visibility": "public"})
        self.assertEqual(result, repository())
        request = self.opener.open.call_args[0][0]
        self.assertEqual(request.full_url, "https://api.github.com/repos/" + REPOSITORY)
        self.assertEqual(request.get_method(), "PATCH")
        self.assertEqual(request.get_header("Authorization"), "Bearer " + TOKEN)
        self.assertEqual(json.loads(request.data), {"visibility": "public"})
        self.assertGreater(self.opener.open.call_args[1]["timeout"], 0)
        self.assertLessEqual(self.opener.open.call_args[1]["timeout"], 60)
        self.assertLessEqual(self.response.read.call_args[0][0], 1024 * 1024 + 1)

    def test_redirect_is_rejected_and_never_retried(self):
        self.opener.open.side_effect = HTTPError(
            "https://api.github.com/repos/" + REPOSITORY, 302, "redirect", {}, io.BytesIO(b"")
        )
        with self.assertRaises(function.RepositoryCheckError):
            function._github_request(REPOSITORY, TOKEN)
        self.opener.open.assert_called_once()
        handler = self.build.call_args[0][0]
        request = self.opener.open.call_args[0][0]
        self.assertIsNone(handler.redirect_request(request, None, 302, "redirect", {}, "https://other.example/"))

    def test_http_errors_do_not_expose_response_body(self):
        body = io.BytesIO(TOKEN.encode("ascii"))
        self.opener.open.side_effect = HTTPError(
            "https://api.github.com/repos/" + REPOSITORY, 403, TOKEN, {}, body
        )
        with self.assertRaises(function.RepositoryCheckError) as raised:
            function._github_request(REPOSITORY, TOKEN)
        self.assertNotIn(TOKEN, str(raised.exception))
        self.assertTrue(body.closed)

    def test_network_and_truncated_response_errors_are_sanitized(self):
        for failure in (URLError(TOKEN), OSError(TOKEN), IncompleteRead(TOKEN.encode("ascii"))):
            with self.subTest(error=type(failure).__name__):
                self.opener.open.side_effect = failure
                with self.assertRaises(function.RepositoryCheckError) as raised:
                    function._github_request(REPOSITORY, TOKEN)
                self.assertNotIn(TOKEN, str(raised.exception))

    def test_non_200_response_is_rejected(self):
        self.response.status = 202
        with self.assertRaises(function.RepositoryCheckError):
            function._github_request(REPOSITORY, TOKEN)
        self.response.read.assert_not_called()

    def test_invalid_json_or_encoding_is_rejected(self):
        for body in (b"{bad-json", b"\xff\xfe\xff"):
            with self.subTest(body=body):
                self.response.read.return_value = body
                with self.assertRaises(function.RepositoryCheckError):
                    function._github_request(REPOSITORY, TOKEN)

    def test_oversized_response_is_rejected(self):
        self.response.read.return_value = b" " * (1024 * 1024 + 1)
        with self.assertRaises(function.RepositoryCheckError):
            function._github_request(REPOSITORY, TOKEN)

    def test_import_does_not_contact_github_or_emit_output(self):
        spec = importlib.util.spec_from_file_location("isolated_repository_function", MODULE_PATH)
        module = importlib.util.module_from_spec(spec)
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch("urllib.request.build_opener") as build:
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                spec.loader.exec_module(module)
        build.assert_not_called()
        self.assertEqual(stdout.getvalue() + stderr.getvalue(), "")


class CommandLineTests(unittest.TestCase):
    def run_main(self, env):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env, clear=True):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = function.main()
        return code, stdout.getvalue(), stderr.getvalue()

    @mock.patch.object(function, "check_repository")
    def test_cli_outputs_json_and_uses_default_threshold(self, check):
        result = {"status": "active", "stop_schedule": False, "schedule_removed": False}
        check.return_value = result
        code, stdout, stderr = self.run_main({"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": TOKEN})
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout), result)
        self.assertEqual(stderr, "")
        args, kwargs = check.call_args
        self.assertEqual(args[:2], (REPOSITORY, TOKEN))
        days = kwargs.get("inactivity_days", args[2] if len(args) > 2 else 30)
        self.assertEqual(days, 30)

    @mock.patch.object(function, "check_repository")
    def test_cli_reads_custom_threshold(self, check):
        check.return_value = {"status": "active", "stop_schedule": False, "schedule_removed": False}
        code, _, _ = self.run_main({"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": TOKEN,
                                     "INACTIVITY_DAYS": "45"})
        self.assertEqual(code, 0)
        args, kwargs = check.call_args
        self.assertEqual(kwargs.get("inactivity_days", args[2] if len(args) > 2 else None), 45)

    def test_missing_configuration_fails_without_exposing_secrets(self):
        with mock.patch.object(function, "_github_request") as transport:
            for env in ({}, {"GITHUB_TOKEN": TOKEN}, {"GITHUB_REPOSITORY": REPOSITORY}):
                with self.subTest(env=list(env)):
                    code, stdout, stderr = self.run_main(env)
                    self.assertEqual(code, 1)
                    self.assertNotIn(TOKEN, stdout + stderr)
            transport.assert_not_called()

    def test_invalid_threshold_fails_without_network(self):
        with mock.patch.object(function, "_github_request") as transport:
            code, stdout, stderr = self.run_main({"GITHUB_REPOSITORY": REPOSITORY,
                                                   "GITHUB_TOKEN": TOKEN, "INACTIVITY_DAYS": "bad"})
        self.assertEqual(code, 1)
        self.assertNotIn(TOKEN, stdout + stderr)
        transport.assert_not_called()

    @mock.patch.object(function, "check_repository", side_effect=function.RepositoryCheckError("GitHub request failed"))
    def test_api_errors_return_nonzero(self, _check):
        code, stdout, stderr = self.run_main({"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": TOKEN})
        self.assertEqual(code, 1)
        self.assertNotIn(TOKEN, stdout + stderr)
        self.assertTrue(stdout or stderr)


if __name__ == "__main__":
    unittest.main()
