# Portable server function

`main.py` contains `check_repository()`, a standalone Python function with no third-party dependencies. Copy it into a cloud function, scheduled worker, or any environment with Python and HTTPS access to GitHub. It needs no Docker container, local state, or cloud SDK.

Configure your runtime to invoke it once per day. It checks the configured GitHub repository's `pushed_at`, makes it public after **strictly more than 30 days** without a push, and then calls the supplied schedule-removal callback. The repository's contents and Git history become public.

## Call the function

```python
import os
from main import check_repository


def run_scheduled_check(remove_this_schedule):
    return check_repository(
        repository=os.environ["GITHUB_REPOSITORY"],
        token=os.environ["GITHUB_TOKEN"],
        inactivity_days=int(os.environ.get("INACTIVITY_DAYS", "30")),
        disable_schedule=remove_this_schedule,
    )
```

Pass a synchronous `remove_this_schedule()` callable implemented using your hosting runtime's scheduler API or an injected scheduler client. It takes no arguments, must finish removing the schedule before returning, must be safe to call more than once, and should raise an exception if it cannot remove the schedule. Asynchronous callbacks are rejected. Give the function permission to remove only its own schedule. Your runtime's handler calls this wrapper; the handler's signature and registration are specific to your runtime.

The callback runs only after GitHub confirms that the repository is public, including when a retry finds it already public. If removal fails, `RepositoryCheckError` propagates so the runtime can retry. A later invocation retries removal without another visibility change when the repository remains public.

For an orchestrator that consumes results itself, omit `disable_schedule` and remove the schedule when `result["stop_schedule"]` is `True`. The function cannot remove an arbitrary external scheduler without that integration.

## Configuration and result

| Argument / CLI variable | Value |
| --- | --- |
| `repository` / `GITHUB_REPOSITORY` | `OWNER/REPOSITORY`, matching the client's destination. |
| `token` / `GITHUB_TOKEN` | GitHub API token supplied through your runtime's secret configuration. |
| `inactivity_days` / `INACTIVITY_DAYS` | Positive integer, default `30`. |
| `disable_schedule` | Optional Python callback; not an environment variable. |

Use a GitHub fine-grained token scoped to the repository, with **Administration: read and write** and **Metadata: read** permissions. The token owner must be allowed to change visibility. The client's SSH deploy key is insufficient. Keep the token valid throughout the intended monitoring period. See GitHub's [repository API and permissions](https://docs.github.com/en/rest/repos/repos#update-a-repository).

The function returns a JSON-serializable dictionary:

```json
{
  "repository": "owner/repository",
  "repository_id": 123,
  "status": "published",
  "pushed_at": "2026-01-01T00:00:00Z",
  "stop_schedule": true,
  "schedule_removed": true
}
```

`status` is `active`, `published`, or `already_public`. `schedule_removed` is true only after the supplied callback returns successfully. Without a callback it stays false, even when `stop_schedule` is true.

Configuration errors raise `ValueError`. API, response-validation, and callback failures raise `RepositoryCheckError`. Keep the schedule on failure. Missing, invalid, or future `pushed_at` values never trigger publication. A repository already public does not need a valid push timestamp to complete.

## Run as a command

Supply `GITHUB_REPOSITORY` and `GITHUB_TOKEN` securely in the process environment, then run:

```sh
python3 main.py
```

The command prints the result as JSON and exits with status `0`, or writes an error to stderr and exits with status `1`. It never prints the token. A successful exit can mean the repository is still active; inspect `stop_schedule` to decide whether to remove the schedule. Running this command alone does **not** remove cron or a cloud schedule.

## Scheduling behavior

- Configure a daily trigger externally, with one invocation at a time. There is no background loop or provider-specific scheduling code in this module.
- Push activity is repository-wide. A client push containing no new changes may not advance GitHub's timestamp.
- The function rechecks immediately before publication. GitHub does not support an atomic check-and-publish operation, so a push arriving after that last read can still race with publication.
- The function is stateless. Successful schedule removal must be durable in the hosting scheduler. If that removal fails and someone makes the repository private again before a retry, the next run reevaluates the current repository state. Add completion storage in your runtime wrapper if you need to preserve the earlier publication independently of GitHub's current visibility.
- Manually invoking the function can change repository visibility, just like a scheduled invocation. Keep any HTTP wrapper authenticated.

## Tests

From this directory, run:

```sh
python3 -m unittest discover -s tests -v
```

Tests replace network calls with fixtures and do not change a GitHub repository. The [Alpine server](..) runs this same function from cron, adding mounted configuration, locking, durable completion, and automatic schedule removal.
