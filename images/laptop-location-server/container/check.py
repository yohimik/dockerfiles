#!/usr/bin/env python3
"""Run the portable repository function from a volume-configured cron job."""

import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import tempfile
from datetime import datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import main as repository_function


SETTINGS_FILE = Path("/config/settings.sh")
CRONTAB_FILE = Path("/config/crontab")
TOKEN_FILE = Path("/credentials/repository_token")
GITHUB_TOKEN_FILE = Path("/credentials/github_token")
DATA_DIR = Path("/data")
DISABLED_SCHEDULE = "# Repository monitoring completed; daily check removed.\n"


def load_settings():
    """Read literal assignments shared with Compose, without executing shell."""
    settings = {
        "REPOSITORY_PROVIDER": "github", "REPOSITORY": "", "GITHUB_REPOSITORY": "",
        "INACTIVITY_DAYS": "30", "TZ": "Etc/UTC",
    }
    for line_number, line in enumerate(SETTINGS_FILE.read_text(encoding="utf-8").splitlines(), 1):
        try:
            words = shlex.split(line, comments=True, posix=True)
        except ValueError:
            raise ValueError("Invalid settings assignment on line {}".format(line_number)) from None
        if not words:
            continue
        if len(words) != 1 or "=" not in words[0]:
            raise ValueError("Use simple KEY=value settings assignments on line {}".format(line_number))
        key, value = words[0].split("=", 1)
        if key not in settings:
            raise ValueError("Unsupported settings key on line {}".format(line_number))
        settings[key] = value

    days = settings["INACTIVITY_DAYS"]
    if not re.fullmatch(r"[1-9][0-9]{0,4}", days):
        raise ValueError("INACTIVITY_DAYS must be an integer from 1 through 36500")
    settings["INACTIVITY_DAYS"] = int(days)
    if not settings["REPOSITORY"] and settings["REPOSITORY_PROVIDER"] == "github":
        settings["REPOSITORY"] = settings["GITHUB_REPOSITORY"]
    # Validate configuration before consulting completion, without needing a
    # credential after a repository has already completed monitoring.
    repository_function._validate_settings(
        settings["REPOSITORY"], "validation_only", settings["INACTIVITY_DAYS"], None,
        provider=settings["REPOSITORY_PROVIDER"],
    )
    try:
        ZoneInfo(settings["TZ"])
    except (ValueError, ZoneInfoNotFoundError):
        raise ValueError("TZ must name an installed timezone") from None
    return settings


def atomic_write(path, content, *, preserve_metadata=False):
    """Replace a file in its own directory so cron observes a complete update."""
    metadata = path.stat() if preserve_metadata else None
    descriptor, temporary_name = tempfile.mkstemp(prefix=".server-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(content)
            output.flush()
            if metadata is not None:
                os.fchown(output.fileno(), metadata.st_uid, metadata.st_gid)
                os.fchmod(output.fileno(), stat.S_IMODE(metadata.st_mode))
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def remove_schedule():
    # This container's mounted crontab is dedicated to repository monitoring.
    # Keep a valid file for Supercronic to watch and read again after a restart.
    if CRONTAB_FILE.read_text(encoding="utf-8") != DISABLED_SCHEDULE:
        atomic_write(CRONTAB_FILE, DISABLED_SCHEDULE, preserve_metadata=True)


def completed_repository(repository, provider):
    completion_file = DATA_DIR / "completed.json"
    if not completion_file.exists():
        return None
    try:
        completion = json.loads(completion_file.read_text(encoding="utf-8"))
        if (
            not isinstance(completion, dict)
            or not isinstance(completion.get("repository"), str)
            or type(completion.get("repository_id")) is not int
            or completion["repository_id"] <= 0
            or not isinstance(completion.get("completed_at"), str)
        ):
            raise ValueError
        # Completion records from the original server belong to GitHub.
        completed_provider = completion.get("provider", "github")
        repository_function._validate_settings(
            completion["repository"], "validation_only", 30, None, provider=completed_provider
        )
        datetime.strptime(completion["completed_at"], "%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, UnicodeError):
        raise ValueError("Invalid completed.json; inspect the saved state before retrying") from None
    if completed_provider == provider and completion["repository"].lower() == repository.lower():
        return {**completion, "provider": completed_provider}
    return None


def run_check():
    settings = load_settings()
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with (DATA_DIR / "check.lock").open("a", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"status": "skipped", "reason": "check_already_running"}

        completion = completed_repository(settings["REPOSITORY"], settings["REPOSITORY_PROVIDER"])
        if completion is not None:
            remove_schedule()
            return {
                **completion,
                "status": "completed",
                "stop_schedule": True,
                "schedule_removed": True,
            }

        token_file = TOKEN_FILE
        if not token_file.exists() and settings["REPOSITORY_PROVIDER"] == "github":
            token_file = GITHUB_TOKEN_FILE
        token = token_file.read_text(encoding="utf-8").rstrip("\r\n")
        result = repository_function.check_repository(
            settings["REPOSITORY"], token, settings["INACTIVITY_DAYS"],
            provider=settings["REPOSITORY_PROVIDER"],
        )
        if result["stop_schedule"]:
            completion = {
                "provider": settings["REPOSITORY_PROVIDER"],
                "repository": result["repository"],
                "repository_id": result["repository_id"],
                "completed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
            # Persist confirmation first. If schedule removal fails, the next
            # invocation retries it without credentials or another API call.
            atomic_write(DATA_DIR / "completed.json", json.dumps(completion, sort_keys=True) + "\n")
            remove_schedule()
            result["schedule_removed"] = True
        return result


def main():
    os.umask(0o077)
    try:
        result = run_check()
    except UnicodeError:
        print("Server configuration, credentials, and state must use UTF-8 text", file=sys.stderr)
        return 1
    except (ValueError, repository_function.RepositoryCheckError) as error:
        print(str(error), file=sys.stderr)
        return 1
    except OSError:
        print("Server file operation failed; check mounted configuration, credentials, and state", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
