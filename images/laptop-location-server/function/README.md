# Portable server function

`main.py` contains `check_repository()`, a standalone Python function with no third-party dependencies. Copy it into a cloud function, scheduled worker, or any environment with Python and HTTPS access to GitHub or Codeberg. It needs no Docker container, local state, or cloud SDK.

For GitHub Actions, use the [server composite action](../../../.github/actions/server-check), which runs this CLI and exposes its JSON result and scheduling decision as outputs.

Configure your runtime to invoke it once per day. It makes the repository public after **strictly more than 30 days** of inactivity, then calls the supplied schedule-removal callback. GitHub uses `pushed_at`. Codeberg uses `updated_at` conservatively because its API has no equivalent last-push field: pushes refresh the timestamp, and other repository changes may delay publication. The repository's contents and Git history become public. See the [Codeberg schema](https://codeberg.org/swagger.v1.json) and [Forgejo push handling](https://codeberg.org/forgejo/forgejo/src/branch/forgejo/services/repository/push.go).

## Call the function

```python
import os
from main import check_repository


def run_scheduled_check(remove_this_schedule):
    return check_repository(
        repository=os.environ["REPOSITORY"],
        token=os.environ["REPOSITORY_TOKEN"],
        inactivity_days=int(os.environ.get("INACTIVITY_DAYS", "30")),
        provider=os.environ.get("REPOSITORY_PROVIDER", "github"),
        disable_schedule=remove_this_schedule,
    )
```

Pass a synchronous `remove_this_schedule()` callable implemented using your hosting runtime's scheduler API or an injected scheduler client. It takes no arguments, must finish removing the schedule before returning, must be safe to call more than once, and should raise an exception if it cannot remove the schedule. Asynchronous callbacks are rejected. Give the function permission to remove only its own schedule. Your runtime's handler calls this wrapper; the handler's signature and registration are specific to your runtime.

Set `provider="codeberg"` for Codeberg; the default remains `"github"`. The callback runs only after the provider confirms that the repository is public, including when a retry finds it already public. If removal fails, `RepositoryCheckError` propagates so the runtime can retry. A later invocation retries removal without another visibility change when the repository remains public.

For an orchestrator that consumes results itself, omit `disable_schedule` and remove the schedule when `result["stop_schedule"]` is `True`. The function cannot remove an arbitrary external scheduler without that integration.

## Configuration and result

| Argument / CLI variable | Value |
| --- | --- |
| `provider` / `REPOSITORY_PROVIDER` | `github` (default) or `codeberg`. |
| `repository` / `REPOSITORY` | `OWNER/REPOSITORY`, matching the client's destination. |
| `token` / `REPOSITORY_TOKEN` | Selected provider's API token supplied through your runtime's secret configuration. |
| `inactivity_days` / `INACTIVITY_DAYS` | Positive integer, default `30`. |
| `disable_schedule` | Optional Python callback; not an environment variable. |

Use a GitHub fine-grained token scoped to the repository, with **Administration: read and write** and **Metadata: read** permissions. The token owner must be allowed to change visibility. The client's SSH deploy key is insufficient. Keep the token valid throughout the intended monitoring period. See GitHub's [repository API and permissions](https://docs.github.com/en/rest/repos/repos#update-a-repository).

For Codeberg, use a repository administrator's token with **write:repository** and **All (public, private, and limited)** access; specific-repository tokens cannot change a private repository to public. The function only confirms public visibility when both `private` and `internal` are false. See [Forgejo token permissions](https://forgejo.org/docs/latest/user/authentication/token-scope/).

The CLI still accepts `GITHUB_REPOSITORY` and `GITHUB_TOKEN` when the generic variables are absent and the provider is GitHub. These legacy variables are never used for Codeberg. API hosts are fixed to `api.github.com` and `codeberg.org`; arbitrary self-hosted Forgejo instances are not configured by this function.

The function returns a JSON-serializable dictionary:

```json
{
  "provider": "github",
  "repository": "owner/repository",
  "repository_id": 123,
  "status": "published",
  "pushed_at": "2026-01-01T00:00:00Z",
  "activity_at": "2026-01-01T00:00:00Z",
  "activity_source": "pushed_at",
  "stop_schedule": true,
  "schedule_removed": true
}
```

`status` is `active`, `published`, or `already_public`. `schedule_removed` is true only after the supplied callback returns successfully. Without a callback it stays false, even when `stop_schedule` is true.

For Codeberg, `activity_source` is `updated_at`, `activity_at` is that value from the API response, and the result omits `pushed_at`. Codeberg timestamps may include a numeric UTC offset and fractional seconds. GitHub's existing `pushed_at` result field is retained.

Configuration errors raise `ValueError`. API, response-validation, and callback failures raise `RepositoryCheckError`. Keep the schedule on failure. Missing, invalid, or future activity timestamps never trigger publication. A repository already public does not need a valid activity timestamp to complete.

## Run as a command

Supply `REPOSITORY`, `REPOSITORY_TOKEN`, and optionally `REPOSITORY_PROVIDER=codeberg` securely in the process environment, then run:

```sh
python3 main.py
```

The command prints the result as JSON and exits with status `0`, or writes an error to stderr and exits with status `1`. It never prints the token. A successful exit can mean the repository is still active; inspect `stop_schedule` to decide whether to remove the schedule. Running this command alone does **not** remove cron or a cloud schedule.

## Scheduling behavior

- Configure a daily trigger externally, with one invocation at a time. There is no background loop or provider-specific scheduling code in this module.
- Activity is repository-wide. A client push containing no new changes may not advance the timestamp; Codeberg's metadata changes can also postpone publication.
- The function rechecks immediately before publication. The API read and visibility update are separate operations, so a push arriving after that last read can still race with publication.
- The function is stateless. Successful schedule removal must be durable in the hosting scheduler. If that removal fails and someone makes the repository private again before a retry, the next run reevaluates the current repository state. Add completion storage in your runtime wrapper if you need to preserve the earlier publication independently of the provider's current visibility. The container wrapper scopes completion to both provider and repository.
- Manually invoking the function can change repository visibility, just like a scheduled invocation. Keep any HTTP wrapper authenticated.

## Tests

From this directory, run:

```sh
python3 -m unittest discover -s tests -v
```

Tests replace network calls with fixtures and do not change any remote repository. The [Alpine server](..) runs this same function from cron, adding mounted configuration, locking, durable completion, and automatic schedule removal.
