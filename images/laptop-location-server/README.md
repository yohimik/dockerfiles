# Laptop location server

For a cloud function or another Python runtime, use the [portable function](function). It has no third-party dependencies and accepts a callback to remove the hosting scheduler's trigger.

An Alpine container with a preparation stage and a runtime stage whose only instruction starts [Supercronic](https://github.com/aptible/supercronic) directly. Its daily cron job runs Python, which calls the same portable `check_repository()` function used outside Docker. It supports **GitHub and Codeberg**. After **more than 30 days of inactivity**, it changes the [client](../laptop-location-client)'s repository to public, saves completion, and removes its cron job. This makes the repository's contents and Git history publicly accessible.

Run it on an always-on server independently of the laptop. It uses the selected provider's repository API; it does not clone the repository or need the client's SSH deploy key. GitHub uses `pushed_at`. Codeberg has no equivalent last-push field, so it uses `updated_at` conservatively: pushes refresh it, and other repository changes can postpone publication. See the [Codeberg API schema](https://codeberg.org/swagger.v1.json) and [Forgejo push handling](https://codeberg.org/forgejo/forgejo/src/branch/forgejo/services/repository/push.go).

## Configure and run

In `config/settings.sh`, set the same repository the client pushes to, using `OWNER/REPOSITORY` without a URL or `.git` suffix:

```sh
REPOSITORY_PROVIDER='github' # github or codeberg
REPOSITORY='YOUR_USER/YOUR_REPOSITORY'
INACTIVITY_DAYS=30
TZ='Etc/UTC'
```

For Codeberg, set `REPOSITORY_PROVIDER='codeberg'` and use the Codeberg owner/repository. Keep `config/settings.sh` to simple `KEY=value` assignments with optional quotes and comments; shell commands and expansions are not supported. Compose reads it as an `env_file`, and the Python job reads the mounted file on every invocation. Provider, repository, threshold, and credential changes apply on the next check without rebuilding or restarting. Existing GitHub configurations using `GITHUB_REPOSITORY` remain supported when `REPOSITORY` is unset.

The default mounted `config/crontab` checks at midnight every day:

```cron
0 0 * * * /usr/bin/python3 /app/check.py >>/proc/1/fd/1 2>>/proc/1/fd/2
```

**Schedule changes require only editing the mounted file.** Supercronic reloads in-place edits and atomic file replacements without a rebuild or container restart. Keep the whole `config/` directory mounted as shown in Compose. Save valid, complete crontabs; an invalid schedule causes cron to exit and Compose to retry it. Active jobs finish before a reload completes.

To change the scheduling timezone through the volume alone, add `CRON_TZ=Asia/Dubai` above the job in `config/crontab`. Without `CRON_TZ`, cron uses `TZ` from Compose's environment. Changing that environment value in `config/settings.sh` requires `docker compose up -d --force-recreate` to update the cron process.

For GitHub, create a fine-grained personal access token scoped to the target repository with **Administration: read and write** and **Metadata: read** permissions. The token owner must be allowed to change repository visibility; organization policy may prevent it.

For Codeberg, create an access token belonging to a repository administrator with **write:repository** and **All (public, private, and limited)** repository access. Specific-repository tokens cannot change private repositories to public. A nonprivate repository under a private-visibility owner is still internal; the check only completes when Codeberg confirms both `private=false` and `internal=false`. See [Codeberg token creation](https://docs.codeberg.org/advanced/access-token/) and [Forgejo token permissions](https://forgejo.org/docs/latest/user/authentication/token-scope/).

A client deploy key cannot change visibility. Keep the API token valid throughout the monitoring period.

Store the selected provider's token as a single line in `.state/credentials/repository_token`:

```sh
cd images/laptop-location-server
mkdir -p .state/credentials
chmod 700 .state .state/credentials
# Save your token into .state/credentials/repository_token using your editor.
chmod 600 .state/credentials/repository_token
./setup.sh
```

Existing GitHub installations may retain `.state/credentials/github_token`; it is used only for GitHub and only when `repository_token` is absent. When switching providers, replace `repository_token` with that provider's credential.

The setup script prepares local state and starts `docker compose up -d --build`. It requires Docker with Linux containers and Docker Compose. Run it from Git Bash or WSL on Windows. Configuration, credentials, and runtime state are excluded from the image and supplied by volumes; credentials and runtime state are ignored by Git. Credentials are mounted read-only. The `config/` mount is writable so the Python job can clear its dedicated crontab after confirmed completion; the container's root filesystem remains read-only.

## Behavior

- No check runs automatically at startup. The first check runs at the next scheduled midnight. Missed checks while the server is down are not replayed.
- The default threshold is strictly greater than `30 * 86400` seconds. With daily checks, publication happens at the first scheduled check after that threshold, while the server and provider API are available.
- GitHub's `pushed_at` and Codeberg's `updated_at` are repository metadata, not commit author dates. Codeberg's update time also includes other repository changes; the server does not infer inactivity from incomplete activity feeds.
- A fresh API read immediately before the visibility change catches activity arriving during the first check. The read and visibility update are separate operations, so a push in the final interval can still race with publication.
- Authentication, network, invalid/missing/future timestamps, and failed or unconfirmed visibility changes leave the job installed for the next day. Check logs for failures.
- A repository already public is treated as complete without another visibility update.
- Only after the Python function confirms public visibility does the server write `/data/completed.json` and replace `/config/crontab` with a completion comment. Supercronic reloads the file and removes the job. Both mounted files survive container recreation; the job stays removed even if you later make the repository private manually.
- Completion is recorded before removing the schedule. If removal fails or the process stops in between, the next invocation retries removal without credentials or another API request.
- Cron keeps running without jobs after completion, so the container remains healthy. The health check verifies cron is alive, not that API calls succeed. This container's crontab is dedicated to this one check and is cleared in full on completion.
- Concurrent checks share a file lock; an overlapping invocation exits without calling either provider.

Keep `.state/data` and `config/` when moving or recreating the server. To deliberately monitor the same repository again, stop the server, remove `.state/data/completed.json`, restore the daily line in `config/crontab`, and restart it. To switch providers or repositories after completion, update `config/settings.sh`, supply the matching token, and restore the schedule. Completion is matched to both provider and repository; older completion records without a provider belong to GitHub. Checks resume at the next scheduled time.

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

Run `./tests/run.sh` from this directory. It builds the image and tests the portable Python function, the container wrapper, and live mounted-crontab reloads with networking disabled. Both providers' responses are mocked; no repository is changed by the tests.

GitHub API references: [repository metadata](https://docs.github.com/en/rest/repos/repos#get-a-repository), [visibility updates and permissions](https://docs.github.com/en/rest/repos/repos#update-a-repository), and [conditional request limitations](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api#use-conditional-requests).
