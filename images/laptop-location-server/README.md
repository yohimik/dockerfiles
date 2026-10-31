# Laptop location server

For a cloud function or another Python runtime, use the [portable function](function). It has no third-party dependencies and accepts a callback to remove the hosting scheduler's trigger.

An Alpine container with a preparation stage and a runtime stage whose only instruction starts [Supercronic](https://github.com/aptible/supercronic) directly. Its daily cron job runs Python, which calls the same portable `check_repository()` function used outside Docker. When GitHub's `pushed_at` timestamp is **more than 30 days old**, it changes the [client](../laptop-location-client)'s repository to public, saves completion, and removes its cron job. This makes the repository's contents and Git history publicly accessible.

Run it on an always-on server independently of the laptop. It uses GitHub's repository API; it does not clone the repository or need the client's SSH deploy key.

## Configure and run

In `config/settings.sh`, set the same repository the client pushes to, using `OWNER/REPOSITORY` without a URL or `.git` suffix:

```sh
GITHUB_REPOSITORY='YOUR_USER/YOUR_REPOSITORY'
INACTIVITY_DAYS=30
TZ='Etc/UTC'
```

Keep `config/settings.sh` to simple `KEY=value` assignments with optional quotes and comments; shell commands and expansions are not supported. Compose reads it as an `env_file`, and the Python job reads the mounted file on every invocation. Repository, threshold, and credential changes apply on the next check without rebuilding or restarting.

The default mounted `config/crontab` checks at midnight every day:

```cron
0 0 * * * /usr/bin/python3 /app/check.py >>/proc/1/fd/1 2>>/proc/1/fd/2
```

**Schedule changes require only editing the mounted file.** Supercronic reloads in-place edits and atomic file replacements without a rebuild or container restart. Keep the whole `config/` directory mounted as shown in Compose. Save valid, complete crontabs; an invalid schedule causes cron to exit and Compose to retry it. Active jobs finish before a reload completes.

To change the scheduling timezone through the volume alone, add `CRON_TZ=Asia/Dubai` above the job in `config/crontab`. Without `CRON_TZ`, cron uses `TZ` from Compose's environment. Changing that environment value in `config/settings.sh` requires `docker compose up -d --force-recreate` to update the cron process.

Create a GitHub fine-grained personal access token scoped to the target repository with **Administration: read and write** and **Metadata: read** permissions. The token owner must be allowed to change repository visibility; organization policy may prevent it. A client deploy key cannot change visibility. Choose a token lifetime covering the intended monitoring period and replace it before it expires.

Store the token as a single line in `.state/credentials/github_token`:

```sh
cd images/laptop-location-server
mkdir -p .state/credentials
chmod 700 .state .state/credentials
# Save your token into .state/credentials/github_token using your editor.
chmod 600 .state/credentials/github_token
./setup.sh
```

The setup script prepares local state and starts `docker compose up -d --build`. It requires Docker with Linux containers and Docker Compose. Run it from Git Bash or WSL on Windows. Configuration, credentials, and runtime state are excluded from the image and supplied by volumes; credentials and runtime state are ignored by Git. Credentials are mounted read-only. The `config/` mount is writable so the Python job can clear its dedicated crontab after confirmed completion; the container's root filesystem remains read-only.

## Behavior

- No check runs automatically at startup. The first check runs at the next scheduled midnight. Missed checks while the server is down are not replayed.
- The default threshold is strictly greater than `30 * 86400` seconds. With daily checks, publication happens at the first scheduled check after that threshold, while the server and GitHub API are available.
- `pushed_at` is repository-wide GitHub metadata, not a commit's author date. A successful client job that pushes no changes does not necessarily advance it; any new push to the repository can postpone publication.
- A fresh API read immediately before the visibility change catches pushes arriving during the first check. GitHub provides no atomic check-and-publish operation, so a push in the final interval before the update can still race with publication.
- Authentication, network, invalid/missing/future timestamps, and failed or unconfirmed visibility changes leave the job installed for the next day. Check logs for failures.
- A repository already public is treated as complete without another visibility update.
- Only after the Python function confirms public visibility does the server write `/data/completed.json` and replace `/config/crontab` with a completion comment. Supercronic reloads the file and removes the job. Both mounted files survive container recreation; the job stays removed even if you later make the repository private manually.
- Completion is recorded before removing the schedule. If removal fails or the process stops in between, the next invocation retries removal without credentials or another API request.
- Cron keeps running without jobs after completion, so the container remains healthy. The health check verifies cron is alive, not that API calls succeed. This container's crontab is dedicated to this one check and is cleared in full on completion.
- Concurrent checks share a file lock; an overlapping invocation exits without calling GitHub.

Keep `.state/data` and `config/` when moving or recreating the server. To deliberately monitor the same repository again, stop the server, remove `.state/data/completed.json`, restore the daily line in `config/crontab`, and restart it. To switch repositories after completion, update `config/settings.sh` and restore the schedule; completion is matched to the configured repository. Checks resume at the next scheduled time.

## Inspect and control

```sh
docker compose ps
docker compose logs --tail 60 server
# Run a check now; this can make the configured repository public:
docker compose exec server /usr/bin/python3 /app/check.py
docker compose stop
docker compose start
```

On Windows Git Bash, use `MSYS_NO_PATHCONV=1` before `docker compose exec` if it rewrites container paths.

## Tests

Run `./tests/run.sh` from this directory. It builds the image and tests the portable Python function, the container wrapper, and live mounted-crontab reloads with networking disabled. GitHub responses are mocked; no repository is changed by the tests.

GitHub API references: [repository metadata](https://docs.github.com/en/rest/repos/repos#get-a-repository), [visibility updates and permissions](https://docs.github.com/en/rest/repos/repos#update-a-repository), and [conditional request limitations](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api#use-conditional-requests).
