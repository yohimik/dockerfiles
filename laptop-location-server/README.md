# Laptop location server

For a cloud function or another Python runtime, use the [portable function](function). It has no third-party dependencies and accepts a callback to remove the hosting scheduler's trigger.

An Alpine container running BusyBox cron and POSIX shell scripts. Once a day it checks the GitHub repository used by the [client](../laptop-location-client). When GitHub's `pushed_at` timestamp is **more than 30 days old**, it changes the repository to public, saves completion, and removes its cron job. This makes the repository's contents and Git history publicly accessible.

Run it on an always-on server independently of the laptop. It uses GitHub's repository API; it does not clone the repository or need the client's SSH deploy key.

## Configure and run

In `config/settings.sh`, set the same repository the client pushes to, using `OWNER/REPOSITORY` without a URL or `.git` suffix:

```sh
GITHUB_REPOSITORY='YOUR_USER/YOUR_REPOSITORY'
INACTIVITY_DAYS=30
TZ='Etc/UTC'
```

The default `config/crontab` checks at midnight every day in that timezone. Settings are trusted executable shell files. Restart the container after changing settings, the schedule, or credentials.

Create a GitHub fine-grained personal access token scoped to the target repository with **Administration: read and write** and **Metadata: read** permissions. The token owner must be allowed to change repository visibility; organization policy may prevent it. A client deploy key cannot change visibility. Choose a token lifetime covering the intended monitoring period and replace it before it expires.

Store the token as a single line in `.state/credentials/github_token`:

```sh
cd laptop-location-server
mkdir -p .state/credentials
chmod 700 .state .state/credentials
# Save your token into .state/credentials/github_token using your editor.
chmod 600 .state/credentials/github_token
./setup.sh
```

The setup script prepares local state and starts `docker compose up -d --build`. It requires Docker with Linux containers and Docker Compose. Run it from Git Bash or WSL on Windows. Credentials and runtime state are ignored by Git, excluded from the image, and mounted separately; credentials are read-only inside the container.

## Behavior

- No check runs automatically at startup. The first check runs at the next scheduled midnight. Missed checks while the server is down are not replayed.
- The default threshold is strictly greater than `30 * 86400` seconds. With daily checks, publication happens at the first scheduled check after that threshold, while the server and GitHub API are available.
- `pushed_at` is repository-wide GitHub metadata, not a commit's author date. A successful client job that pushes no changes does not necessarily advance it; any new push to the repository can postpone publication.
- A fresh API read immediately before the visibility change catches pushes arriving during the first check. GitHub provides no atomic check-and-publish operation, so a push in the final interval before the update can still race with publication.
- Authentication, network, invalid/missing/future timestamps, and failed or unconfirmed visibility changes leave the job installed for the next day. Check logs for failures.
- A repository already public is treated as complete without another visibility update.
- Only after GitHub confirms public visibility does the server write `/data/completed.json` and remove its installed crontab. That state survives restarts and container recreation through `.state/data`; the job stays removed even if you later make the repository private manually.
- Cron keeps running without jobs after completion, so the container remains healthy. The health check verifies cron is alive, not that API calls succeed. This container's crontab is dedicated to this one job and is removed in full on completion.

Keep `.state/data` when moving or recreating the server. To deliberately monitor the same repository again, stop the server, remove `.state/data/completed.json`, and restart it. It will apply the configured inactivity rule at its next check.

## Inspect and control

```sh
docker compose ps
docker compose logs --tail 60 server
# Run a check now; this can make the configured repository public:
docker compose exec server /app/check.sh
docker compose stop
docker compose start
```

On Windows Git Bash, use `MSYS_NO_PATHCONV=1` before `docker compose exec` if it rewrites container paths.

## Tests

Run `./tests/run.sh` from this directory. It builds the image and exercises the real Alpine scripts with fixture API responses in a container with networking disabled. No GitHub repository is changed by the tests.

GitHub API references: [repository metadata](https://docs.github.com/en/rest/repos/repos#get-a-repository), [visibility updates and permissions](https://docs.github.com/en/rest/repos/repos#update-a-repository), and [conditional request limitations](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api#use-conditional-requests).
