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


def _request(repository, token, method, data, provider):
    if provider == "github":
        endpoint = "https://api.github.com/repos/"
        label = "GitHub"
        headers = {
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2026-03-10",
        }
    else:
        endpoint = "https://codeberg.org/api/v1/repos/"
        label = "Codeberg"
        headers = {"Authorization": "token " + token, "Accept": "application/json"}
    headers.update({"Content-Type": "application/json", "User-Agent": "laptop-location-server"})
    request = Request(
        endpoint + repository,
        data=json.dumps(data).encode("utf-8") if data is not None else None,
        headers=headers,
        method=method,
    )
    # Never forward credentials to a redirect or silently follow a renamed repo.
    opener = build_opener(_RejectRedirects())
    try:
        with opener.open(request, timeout=15) as response:
            if response.status != 200:
                raise RepositoryCheckError(label + " returned an unexpected HTTP status")
            body = response.read(1024 * 1024 + 1)
    except HTTPError as error:
        code = error.code
        error.close()
        raise RepositoryCheckError(label + " request failed (HTTP {})".format(code)) from None
    except (URLError, OSError, HTTPException):
        raise RepositoryCheckError(label + " request failed; retry later") from None
    if len(body) > 1024 * 1024:
        raise RepositoryCheckError(label + " response exceeded the size limit")
    try:
        return json.loads(body)
    except (ValueError, UnicodeError):
        raise RepositoryCheckError(label + " returned invalid JSON") from None


def _github_request(repository, token, method="GET", data=None):
    return _request(repository, token, method, data, "github")


def _codeberg_request(repository, token, method="GET", data=None):
    return _request(repository, token, method, data, "codeberg")


def _validate_settings(repository, token, inactivity_days, disable_schedule, provider="github"):
    if provider not in ("github", "codeberg"):
        raise ValueError("provider must be github or codeberg")
    if not isinstance(repository, str) or "/" not in repository:
        raise ValueError("repository must be OWNER/REPOSITORY")
    owner, name = repository.split("/", 1)
    if provider == "github":
        valid_owner = re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", owner)
    else:
        valid_owner = re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,38}[A-Za-z0-9])?", owner)
        valid_owner = valid_owner and not re.search(r"[-._]{2,}", owner)
    if (
        not valid_owner
        or not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", name)
        or name in (".", "..")
    ):
        raise ValueError("repository must be a valid {} OWNER/REPOSITORY".format(provider))
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_]+", token):
        raise ValueError("token must be a valid API token")
    if type(inactivity_days) is not int or not 1 <= inactivity_days <= 36500:
        raise ValueError("inactivity_days must be an integer from 1 through 36500")
    if disable_schedule is not None and not callable(disable_schedule):
        raise ValueError("disable_schedule must be a callable or None")
    if inspect.iscoroutinefunction(disable_schedule):
        raise ValueError("disable_schedule must be synchronous")


def _validate_repository(response, repository, expected_id=None, provider="github"):
    if not isinstance(response, dict):
        raise RepositoryCheckError("Unexpected repository response")
    repo_id = response.get("id")
    full_name = response.get("full_name")
    private = response.get("private")
    visibility = response.get("visibility")
    if provider == "github":
        valid_visibility = (
            (visibility == "public" and private is False)
            or (visibility in ("private", "internal") and private is True)
        )
    else:
        # Forgejo's internal flag reflects an owner hidden from anonymous users.
        # private=false alone does not establish that a repository is public.
        valid_visibility = type(response.get("internal")) is bool
    if (
        type(repo_id) is not int
        or repo_id <= 0
        or not isinstance(full_name, str)
        or full_name.lower() != repository.lower()
        or type(private) is not bool
        or not valid_visibility
        or (expected_id is not None and repo_id != expected_id)
    ):
        raise RepositoryCheckError("Unexpected repository identity or visibility")
    return response


def _is_public(response, provider):
    if provider == "github":
        return response["visibility"] == "public"
    return response["private"] is False and response["internal"] is False


def _utc_now():
    return datetime.now(timezone.utc)


def _activity_field(provider):
    # Forgejo refreshes updated_at on pushes and other repository changes. This
    # conservative activity bound may delay publication; it is not a push date.
    return "pushed_at" if provider == "github" else "updated_at"


def _is_inactive(response, inactivity_days, provider="github"):
    field = _activity_field(provider)
    value = response.get(field)
    pattern = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    pattern += "Z" if provider == "github" else r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-5][0-9])"
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise RepositoryCheckError("Missing or invalid {}; schedule must be retained".format(field))
    try:
        activity_at = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise RepositoryCheckError("Invalid {} date; schedule must be retained".format(field)) from None
    age = _utc_now() - activity_at
    if age < timedelta(0):
        raise RepositoryCheckError("{} is in the future; schedule must be retained".format(field))
    return age > timedelta(days=inactivity_days)


def _result(response, status, disable_schedule, provider):
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
    result = {
        "provider": provider,
        "repository": response["full_name"],
        "repository_id": response["id"],
        "status": status,
        "activity_at": response.get(_activity_field(provider)),
        "activity_source": _activity_field(provider),
        "stop_schedule": stop_schedule,
        "schedule_removed": schedule_removed,
    }
    if provider == "github":
        result["pushed_at"] = response.get("pushed_at")
    return result


def check_repository(repository, token, inactivity_days=30, *, provider="github", disable_schedule=None):
    """Publish after strictly more than inactivity_days of repository inactivity.

    GitHub uses pushed_at. Codeberg uses its conservative updated_at activity
    timestamp: pushes refresh it, and other changes can postpone publication.

    Call from any Python runtime. disable_schedule is an optional, synchronous,
    idempotent, zero-argument callback that removes the external schedule.
    Without it, the caller must act on stop_schedule=True in the returned dict.
    Errors raise ValueError or RepositoryCheckError; retain the schedule and retry.
    No configuration is read and no API calls are made at import time.
    """
    _validate_settings(repository, token, inactivity_days, disable_schedule, provider)
    request = _github_request if provider == "github" else _codeberg_request
    response = _validate_repository(request(repository, token), repository, provider=provider)
    if _is_public(response, provider):
        return _result(response, "already_public", disable_schedule, provider)
    if not _is_inactive(response, inactivity_days, provider):
        return _result(response, "active", disable_schedule, provider)

    repo_id = response["id"]
    # A fresh read catches intervening activity. Neither API has an atomic conditional
    # visibility update, so a push after this read can still race with publication.
    response = _validate_repository(request(repository, token), repository, repo_id, provider)
    if _is_public(response, provider):
        return _result(response, "already_public", disable_schedule, provider)
    if not _is_inactive(response, inactivity_days, provider):
        return _result(response, "active", disable_schedule, provider)

    response = _validate_repository(
        request(repository, token, method="PATCH", data=(
            {"visibility": "public"} if provider == "github" else {"private": False}
        )),
        repository,
        repo_id,
        provider,
    )
    if not _is_public(response, provider):
        raise RepositoryCheckError("API did not confirm public visibility; retain the schedule")
    return _result(response, "published", disable_schedule, provider)


def main():
    """CLI: read environment configuration and print one JSON result."""
    days = os.environ.get("INACTIVITY_DAYS", "30")
    provider = os.environ.get("REPOSITORY_PROVIDER", "github")
    # Legacy GitHub variables remain supported only for the GitHub provider.
    repository = os.environ.get("REPOSITORY", os.environ.get("GITHUB_REPOSITORY", "") if provider == "github" else "")
    token = os.environ.get("REPOSITORY_TOKEN", os.environ.get("GITHUB_TOKEN", "") if provider == "github" else "")
    try:
        if not re.fullmatch(r"[1-9][0-9]{0,4}", days):
            raise ValueError("INACTIVITY_DAYS must be an integer from 1 through 36500")
        result = check_repository(
            repository,
            token,
            int(days),
            provider=provider,
        )
    except (ValueError, RepositoryCheckError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
