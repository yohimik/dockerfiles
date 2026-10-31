"""Provider-independent checks; every GitHub and Codeberg request is mocked."""

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


def codeberg_repository(age=timedelta(days=31), *, public=False):
    return {
        "id": 456,
        "full_name": REPOSITORY,
        "private": not public,
        "internal": False,
        "updated_at": (NOW - age).isoformat(),
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

    def test_codeberg_request_uses_fixed_endpoint_and_provider_headers(self):
        self.response.read.return_value = json.dumps(codeberg_repository(public=True)).encode("utf-8")
        result = function._codeberg_request(REPOSITORY, TOKEN, method="PATCH", data={"private": False})
        self.assertEqual(result, codeberg_repository(public=True))
        request = self.opener.open.call_args[0][0]
        self.assertEqual(request.full_url, "https://codeberg.org/api/v1/repos/" + REPOSITORY)
        self.assertEqual(request.get_method(), "PATCH")
        self.assertEqual(request.get_header("Authorization"), "token " + TOKEN)
        self.assertEqual(request.get_header("Accept"), "application/json")
        self.assertIsNone(request.get_header("X-github-api-version"))
        self.assertEqual(json.loads(request.data), {"private": False})

    def test_codeberg_redirect_and_transport_errors_are_sanitized(self):
        for error in (
            HTTPError("https://codeberg.org/", 302, TOKEN, {}, io.BytesIO(TOKEN.encode("ascii"))),
            URLError(TOKEN),
        ):
            with self.subTest(error=type(error).__name__):
                self.opener.open.reset_mock()
                self.opener.open.side_effect = error
                with self.assertRaises(function.RepositoryCheckError) as raised:
                    function._codeberg_request(REPOSITORY, TOKEN)
                self.assertNotIn(TOKEN, str(raised.exception))
                self.assertIn("Codeberg", str(raised.exception))
                self.opener.open.assert_called_once()
                self.assertIsInstance(self.build.call_args[0][0], function._RejectRedirects)

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


class CodebergRepositoryTests(unittest.TestCase):
    def setUp(self):
        clock = mock.patch.object(function, "_utc_now", return_value=NOW)
        clock.start()
        self.addCleanup(clock.stop)
        transport = mock.patch.object(function, "_codeberg_request")
        self.transport = transport.start()
        self.addCleanup(transport.stop)
        github = mock.patch.object(function, "_github_request")
        self.github = github.start()
        self.addCleanup(github.stop)
        self.addCleanup(self.github.assert_not_called)
        self.disable = mock.Mock()

    def check(self, **kwargs):
        return function.check_repository(
            REPOSITORY, TOKEN, provider="codeberg", disable_schedule=self.disable, **kwargs
        )

    def test_recent_and_exact_threshold_activity_keep_schedule(self):
        for age in (timedelta(days=1), timedelta(days=30)):
            with self.subTest(age=age):
                self.transport.reset_mock()
                self.transport.return_value = codeberg_repository(age)
                result = self.check()
                self.assertEqual(result["status"], "active")
                self.assertEqual(result["provider"], "codeberg")
                self.assertEqual(result["activity_source"], "updated_at")
                self.assertEqual(result["activity_at"], self.transport.return_value["updated_at"])
                self.assertNotIn("pushed_at", result)
                self.assertFalse(result["stop_schedule"])
                self.transport.assert_called_once_with(REPOSITORY, TOKEN)
                self.disable.assert_not_called()

    def test_old_activity_publishes_only_after_recheck_and_confirmation(self):
        stale = codeberg_repository(timedelta(days=30, seconds=1))
        self.transport.side_effect = [stale, dict(stale), dict(stale, private=False)]
        result = self.check()
        self.assertEqual(result["status"], "published")
        self.assertTrue(result["schedule_removed"])
        self.assertEqual(self.transport.call_args_list, [
            mock.call(REPOSITORY, TOKEN), mock.call(REPOSITORY, TOKEN),
            mock.call(REPOSITORY, TOKEN, method="PATCH", data={"private": False}),
        ])
        self.disable.assert_called_once_with()

    def test_rfc3339_offset_and_fraction_are_compared_as_instants(self):
        instant = (NOW - timedelta(days=30, microseconds=500000)).astimezone(timezone(timedelta(hours=4)))
        stale = dict(codeberg_repository(), updated_at=instant.isoformat())
        self.transport.side_effect = [stale, dict(stale), dict(stale, private=False)]
        self.assertEqual(self.check()["status"], "published")
        self.assertEqual(self.transport.call_count, 3)

    def test_missing_invalid_and_future_activity_never_publishes(self):
        for value in (None, "", 123, "not-a-date", "2030-02-31T00:00:00Z",
                      "2029-01-01T00:00:00", "2029-01-01T00:00:00+24:00",
                      "2029-01-01T00:00:00+00:61", "2030-02-01T12:00:00Z"):
            with self.subTest(updated_at=value):
                self.transport.reset_mock()
                self.transport.return_value = dict(codeberg_repository(), updated_at=value)
                with self.assertRaises(function.RepositoryCheckError):
                    self.check()
                self.transport.assert_called_once()
                self.disable.assert_not_called()

    def test_codeberg_never_falls_back_to_a_pushed_at_field(self):
        response = codeberg_repository()
        response["pushed_at"] = response.pop("updated_at")
        self.transport.return_value = response
        with self.assertRaises(function.RepositoryCheckError):
            self.check()
        self.disable.assert_not_called()

    def test_recent_repository_changes_delay_publication_despite_old_push_date(self):
        self.transport.return_value = dict(codeberg_repository(timedelta(days=1)),
                                           pushed_at="2020-01-01T00:00:00Z")
        result = self.check()
        self.assertEqual(result["status"], "active")
        self.transport.assert_called_once()
        self.disable.assert_not_called()

    def test_activity_arriving_on_recheck_prevents_publication(self):
        self.transport.side_effect = [codeberg_repository(), codeberg_repository(timedelta(seconds=1))]
        self.assertEqual(self.check()["status"], "active")
        self.assertEqual(self.transport.call_count, 2)
        self.disable.assert_not_called()

    def test_already_public_needs_no_activity_timestamp_or_patch(self):
        self.transport.return_value = dict(codeberg_repository(public=True), updated_at=None)
        self.assertEqual(self.check()["status"], "already_public")
        self.transport.assert_called_once()
        self.disable.assert_called_once_with()

    def test_public_on_recheck_does_not_patch_again(self):
        self.transport.side_effect = [codeberg_repository(), codeberg_repository(public=True)]
        self.assertEqual(self.check()["status"], "already_public")
        self.assertEqual(self.transport.call_count, 2)
        self.disable.assert_called_once_with()

    def test_internal_repository_is_never_confirmed_as_public(self):
        internal = dict(codeberg_repository(public=True), internal=True)
        self.transport.side_effect = [internal, dict(internal), dict(internal)]
        with self.assertRaises(function.RepositoryCheckError):
            self.check()
        self.assertEqual(self.transport.call_count, 3)
        self.disable.assert_not_called()

    def test_invalid_identity_or_visibility_keeps_schedule(self):
        for response in (None, [], {}, dict(codeberg_repository(), id=True),
                         dict(codeberg_repository(), full_name="different/repo"),
                         dict(codeberg_repository(), private="false"),
                         dict(codeberg_repository(), internal=None),
                         dict(codeberg_repository(), internal="false")):
            with self.subTest(response=response):
                self.transport.reset_mock()
                self.transport.return_value = response
                with self.assertRaises(function.RepositoryCheckError):
                    self.check()
                self.transport.assert_called_once()
                self.disable.assert_not_called()

    def test_failed_unconfirmed_or_wrong_identity_update_keeps_schedule(self):
        for patch in (function.RepositoryCheckError("denied"), codeberg_repository(),
                      dict(codeberg_repository(public=True), id=999)):
            with self.subTest(patch=patch):
                self.transport.reset_mock()
                self.transport.side_effect = [codeberg_repository(), codeberg_repository(), patch]
                with self.assertRaises(function.RepositoryCheckError):
                    self.check()
                self.assertEqual(self.transport.call_count, 3)
                self.disable.assert_not_called()

    def test_invalid_provider_and_names_fail_before_api_calls(self):
        for provider in ("forgejo", "", None, "CODEBERG"):
            with self.subTest(provider=provider):
                with self.assertRaises(ValueError):
                    function.check_repository(REPOSITORY, TOKEN, provider=provider)
        for name in ("../repo", "owner/repo/extra", "owner/..", "bad__owner/repo",
                     "trailing-/repo", "a" * 41 + "/repo"):
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    function.check_repository(name, TOKEN, provider="codeberg")
        for name in ("code_berg/my-repo", "code.berg/my_repo", "a" * 40 + "/repo"):
            function._validate_settings(name, TOKEN, 30, None, provider="codeberg")
        self.transport.assert_not_called()


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

    @mock.patch.object(function, "check_repository")
    def test_cli_selects_codeberg_with_generic_configuration(self, check):
        check.return_value = {"provider": "codeberg", "status": "active"}
        code, stdout, stderr = self.run_main({
            "REPOSITORY_PROVIDER": "codeberg", "REPOSITORY": REPOSITORY,
            "REPOSITORY_TOKEN": "codeberg_test_token", "INACTIVITY_DAYS": "45",
        })
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["provider"], "codeberg")
        check.assert_called_once_with(REPOSITORY, "codeberg_test_token", 45, provider="codeberg")

    @mock.patch.object(function, "check_repository")
    def test_cli_generic_github_values_override_legacy_variables(self, check):
        check.return_value = {"status": "active"}
        code, _, stderr = self.run_main({
            "REPOSITORY": "generic/repo", "REPOSITORY_TOKEN": "generic_token",
            "GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": TOKEN,
        })
        self.assertEqual(code, 0, stderr)
        check.assert_called_once_with("generic/repo", "generic_token", 30, provider="github")

    def test_codeberg_cli_never_uses_legacy_github_credentials(self):
        with mock.patch.object(function, "_codeberg_request") as transport:
            for extra in ({}, {"REPOSITORY": REPOSITORY}, {"REPOSITORY_TOKEN": "codeberg_token"}):
                with self.subTest(extra=extra):
                    code, stdout, stderr = self.run_main({
                        "REPOSITORY_PROVIDER": "codeberg", "GITHUB_REPOSITORY": REPOSITORY,
                        "GITHUB_TOKEN": TOKEN, **extra,
                    })
                    self.assertEqual(code, 1)
                    self.assertNotIn(TOKEN, stdout + stderr)
            transport.assert_not_called()

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
