"""Portable repository inactivity check; only the Python standard library is used."""

import inspect
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from http.client import HTTPException
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener


class RepositoryCheckError(RuntimeError):
    """The check or schedule removal failed and should be retried later."""


class _RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _github_request(repository, token, method="GET", data=None):
    request = Request(
        "https://api.github.com/repos/" + repository,
        data=json.dumps(data).encode("utf-8") if data is not None else None,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2026-03-10",
            "Content-Type": "application/json",
            "User-Agent": "laptop-location-server",
        },
        method=method,
    )
    # Never forward credentials to a redirect or silently follow a renamed repo.
    opener = build_opener(_RejectRedirects())
    try:
        with opener.open(request, timeout=15) as response:
            if response.status != 200:
                raise RepositoryCheckError("GitHub returned an unexpected HTTP status")
            body = response.read(1024 * 1024 + 1)
    except HTTPError as error:
        code = error.code
        error.close()
        raise RepositoryCheckError("GitHub request failed (HTTP {})".format(code)) from None
    except (URLError, OSError, HTTPException):
        raise RepositoryCheckError("GitHub request failed; retry later") from None
    if len(body) > 1024 * 1024:
        raise RepositoryCheckError("GitHub response exceeded the size limit")
    try:
        return json.loads(body)
    except (ValueError, UnicodeError):
        raise RepositoryCheckError("GitHub returned invalid JSON") from None


def _validate_settings(repository, token, inactivity_days, disable_schedule):
    if not isinstance(repository, str) or "/" not in repository:
        raise ValueError("repository must be OWNER/REPOSITORY")
    owner, name = repository.split("/", 1)
    if (
        not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", owner)
        or not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", name)
        or name in (".", "..")
    ):
        raise ValueError("repository must be a valid GitHub OWNER/REPOSITORY")
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_]+", token):
        raise ValueError("token must be a GitHub API token")
    if type(inactivity_days) is not int or not 1 <= inactivity_days <= 36500:
        raise ValueError("inactivity_days must be an integer from 1 through 36500")
    if disable_schedule is not None and not callable(disable_schedule):
        raise ValueError("disable_schedule must be a callable or None")
    if inspect.iscoroutinefunction(disable_schedule):
        raise ValueError("disable_schedule must be synchronous")


def _validate_repository(response, repository, expected_id=None):
    if not isinstance(response, dict):
        raise RepositoryCheckError("Unexpected GitHub repository response")
    repo_id = response.get("id")
    full_name = response.get("full_name")
    private = response.get("private")
    visibility = response.get("visibility")
    if (
        type(repo_id) is not int
        or repo_id <= 0
        or not isinstance(full_name, str)
        or full_name.lower() != repository.lower()
        or type(private) is not bool
        or not (
            (visibility == "public" and private is False)
            or (visibility in ("private", "internal") and private is True)
        )
        or (expected_id is not None and repo_id != expected_id)
    ):
        raise RepositoryCheckError("Unexpected GitHub repository identity or visibility")
    return response


def _utc_now():
    return datetime.now(timezone.utc)


def _is_inactive(response, inactivity_days):
    value = response.get("pushed_at")
    if not isinstance(value, str) or not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value
    ):
        raise RepositoryCheckError("Missing or invalid pushed_at; schedule must be retained")
    try:
        pushed_at = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        raise RepositoryCheckError("Invalid pushed_at date; schedule must be retained") from None
    age = _utc_now() - pushed_at
    if age < timedelta(0):
        raise RepositoryCheckError("pushed_at is in the future; schedule must be retained")
    return age > timedelta(days=inactivity_days)


def _result(response, status, disable_schedule):
    stop_schedule = status != "active"
    schedule_removed = False
    if stop_schedule and disable_schedule is not None:
        try:
            completion = disable_schedule()
            if inspect.isawaitable(completion):
                if inspect.iscoroutine(completion):
                    completion.close()
                raise TypeError("disable_schedule must complete synchronously")
        except Exception:
            # Callback errors may contain provider credentials; keep them out of logs.
            raise RepositoryCheckError(
                "Repository is public, but schedule removal failed; retry schedule removal"
            ) from None
        schedule_removed = True
    return {
        "repository": response["full_name"],
        "repository_id": response["id"],
        "status": status,
        "pushed_at": response.get("pushed_at"),
        "stop_schedule": stop_schedule,
        "schedule_removed": schedule_removed,
    }


def check_repository(repository, token, inactivity_days=30, *, disable_schedule=None):
    """Publish after strictly more than inactivity_days since GitHub's last push.

    Call from any Python runtime. disable_schedule is an optional, synchronous,
    idempotent, zero-argument callback that removes the external schedule.
    Without it, the caller must act on stop_schedule=True in the returned dict.
    Errors raise ValueError or RepositoryCheckError; retain the schedule and retry.
    No configuration is read and no API calls are made at import time.
    """
    _validate_settings(repository, token, inactivity_days, disable_schedule)
    response = _validate_repository(_github_request(repository, token), repository)
    if response["visibility"] == "public":
        return _result(response, "already_public", disable_schedule)
    if not _is_inactive(response, inactivity_days):
        return _result(response, "active", disable_schedule)

    repo_id = response["id"]
    # A fresh read catches intervening pushes. GitHub has no atomic conditional
    # visibility update, so a push after this read can still race with publication.
    response = _validate_repository(_github_request(repository, token), repository, repo_id)
    if response["visibility"] == "public":
        return _result(response, "already_public", disable_schedule)
    if not _is_inactive(response, inactivity_days):
        return _result(response, "active", disable_schedule)

    response = _validate_repository(
        _github_request(repository, token, method="PATCH", data={"visibility": "public"}),
        repository,
        repo_id,
    )
    if response["visibility"] != "public":
        raise RepositoryCheckError("GitHub did not confirm public visibility; retain the schedule")
    return _result(response, "published", disable_schedule)


def main():
    """CLI: read environment configuration and print one JSON result."""
    days = os.environ.get("INACTIVITY_DAYS", "30")
    try:
        if not re.fullmatch(r"[1-9][0-9]{0,4}", days):
            raise ValueError("INACTIVITY_DAYS must be an integer from 1 through 36500")
        result = check_repository(
            os.environ.get("GITHUB_REPOSITORY", ""),
            os.environ.get("GITHUB_TOKEN", ""),
            int(days),
        )
    except (ValueError, RepositoryCheckError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
