# Laptop location client

A Docker client with two default cron jobs: capture and commit files every **30 minutes**, then publish pending committed files every **5 minutes**. Outgoing filenames include the machine model and an increasing push-attempt number. Conflicting files stay queued while nonconflicting files are published.

The same Linux container runs on Docker Engine for Linux and Docker Desktop for macOS or Windows. On Windows, run the setup script from Git Bash or WSL. The image uses Git, OpenSSH, jq, curl, coreutils, flock, and [Supercronic](https://github.com/aptible/supercronic), a cron runner for containers. It contains no Python or native host helper code.

The Dockerfile has a prepared stage for dependencies and scripts, followed by a runtime stage that defines only the cron entrypoint. Supercronic reads `/config/crontab` directly and watches the mounted file for changes. No schedule, settings, or credentials are baked into the image.

Precise location requires an external host location provider. A Linux container cannot itself call macOS or Windows Location Services. The `bridge` mode lets an existing host provider respond when cron requests a fresh fix; `command` mode runs a configured command that returns location JSON. No approximate-IP fallback is enabled.

## Configuration

Edit or replace these files. There is no separate environment file.

| File | Purpose |
| --- | --- |
| `config/settings.sh` | Shell-compatible `KEY=value` assignments for Git settings and runtime timezone; also loaded by Compose as an `env_file`. |
| `config/crontab` | Live five-field cron schedules, including arbitrary shell jobs and an optional `CRON_TZ` override. |
| `config/commit-jobs` | Capture jobs to run before committing; location and device reporting are enabled by default. |
| `config/jobs/*.sh` | Location options, extra-file list, pre-command and timeout for each capture job. |
| `config/files.tsv` | Tab-separated source and destination paths. |
| `config/device.json` | Optional model-name and machine-field overrides. |
| `config/device-report.sh` | Device input paths and optional configuration/container reporting. |
| `config/device-files.tsv` | Destination filename for the device report in the Git repository. |
| `jobs/*.sh` | Your own shell scripts, mounted read-only in the container. |

For example, set the destination in `config/settings.sh`:

```sh
GIT_URL='git@github.com:YOUR_USER/YOUR_REPOSITORY.git'
GIT_BRANCH='main'
GIT_AUTHOR_NAME='Laptop Location Client'
GIT_AUTHOR_EMAIL='location-client@localhost'
REPOSITORY_DIR='/data/repository'
COMMIT_JOBS_FILE='/config/commit-jobs'
PUSH_TIMEOUT_SECONDS=300
TZ='Etc/UTC'
```

Keep `config/settings.sh` to simple `KEY=value` assignments and comments so both Compose and the shell can read it. Other `.sh` job/configuration files remain trusted executable shell code. Keep secrets out of these files. The two default entries in `config/crontab` are:

```cron
*/30 * * * * /app/commit.sh >>/proc/1/fd/1 2>>/proc/1/fd/2
*/5 * * * * /app/push.sh >>/proc/1/fd/1 2>>/proc/1/fd/2
```

The mounted crontab reloads automatically after edits, including replacing it with a newly saved file in the same directory. **Schedule changes require no rebuild or container restart.** Keep the whole `config/` directory mounted as shown in Compose so replacement files remain visible. Save valid, complete crontabs; a malformed schedule causes the cron process to exit and Compose to retry it. Active jobs finish before a reload completes.

Use normal five-field cron syntax with ranges, lists and steps; Sunday is `0`. The supplied jobs run only at their scheduled times, not immediately on startup. To change the scheduling timezone through the volume too, add or edit this line in `config/crontab`:

```cron
CRON_TZ=Asia/Dubai
```

Without `CRON_TZ`, scheduling uses `TZ` from `config/settings.sh`. Changing that process environment value requires recreating the container, without rebuilding the image:

```sh
docker compose up -d --force-recreate
```

Git settings and job files are read again on each run. SSH credentials are copied from their read-only mount into private temporary storage under the publishing lock on each push, so credential changes apply on the next push without a restart.

## Local commits and pushes

`REPOSITORY_DIR` is a dedicated Git repository root under `/data`; the default `/data/repository` maps to `.state/data/repository` on the host. The commit job initializes it if necessary, runs the jobs listed in `config/commit-jobs`, then runs `git add -A` and commits any changes. This includes files you place directly in that directory, modifications, and deletions, while honoring `.gitignore`. There is no fetch, pull, or push in the commit job, so it can work offline. A failed capture is logged; other captures and existing repository changes can still be committed.

The push job reads the latest local commit, not uncommitted worktree edits. It publishes changed or previously unpublished regular files in a separate temporary checkout of `GIT_URL`/`GIT_BRANCH`. Local capture names and commit history stay intact; the remote receives publication commits with suffixed filenames. Only the latest committed contents of a pending file are exported if several captures accumulate before a successful push.

For a model named `MacBook Pro`, `reports/status.json` is published as `reports/status-MacBook-Pro-1.json`, then `reports/status-MacBook-Pro-2.json` on a later attempt with new contents. Directories and the final file extension are preserved. The model comes from `config/device.json`, falling back to the collected host model; unknown models use `device`. Unsafe filename characters become hyphens. Custom device-metadata paths in `config/device-report.sh` are respected.

The counter starts at `1`, increases by one per push invocation with pending files, and survives restarts. Internal network retries use the same counter. When no committed files need publishing, no new attempt is allocated. State is kept inside the capture repository's `.git` directory and is scoped to the remote URL and branch; retain that directory when moving the client.

The first push is tried normally. If another client advances the remote, this client fetches again, leaves conflicting destinations untouched, and retries only nonconflicting files. A different file already occupying the outgoing name is also retained. Successful files are acknowledged individually, so the next five-minute invocation retries only pending files with the next counter. A partial push reports a nonzero status and logs the files still pending. Unrelated remote files and older attempt filenames are preserved. Deleting a local file is recorded locally; it does not erase previously published snapshots.

The commit and push jobs share a lock, so their coinciding schedules cannot change the repository during publication. Source files must have safe repository-relative paths; symlinks and submodules are not published as regular files.

## Run

Install Docker and Docker Compose, then edit the settings above. For GitHub SSH access, the optional setup command uses your authenticated GitHub CLI to create or reuse a repository-specific writable deploy key:

```sh
gh auth login --hostname github.com
./setup.sh --github-key
```

Alternatively, put an existing deploy key in `.state/credentials/id_ed25519` and verified server host keys in `.state/credentials/known_hosts`, then run:

```sh
./setup.sh
```

SSH host verification stays enabled. Git URL, branch and author come from settings; the GitHub key setup is only a convenience for GitHub URLs. Other Git servers can use manually provisioned credentials. Credential files and runtime data are ignored by Git and excluded from the image build.

Setup also captures host machine information into `.state/input/device-info.json` using standard host commands and the image's jq. It does not publish anything during setup; cron runs the publishing jobs later.

## Device report

The enabled `config/jobs/device.sh` capture writes `device/client-info.json` into the local repository every 30 minutes. The push job adds the model and attempt suffix when publishing it, for example `device/client-info-MacBook-Air-1.json`. By default, the report includes **only machine specifications and model name**, plus a schema version and report timestamp. Client configuration and container information are disabled by default.

Machine fields are `model_name`, `model_identifier`, `system`, `release`, `architecture`, `os_description`, `cpu_model`, `logical_cpus`, and `memory_bytes`. Unsupported or unavailable values are `null`. Hostnames, serial numbers, network addresses, environment variables, and unrelated input files are excluded from the default report.

The host snapshot is collected at setup time. Refresh it after hardware or OS changes:

```sh
./collect-device-info.sh
```

The collector runs on the host; container hardware is not presented as laptop information. Git Bash and WSL may report details of their execution environment, and unavailable hardware values stay unknown. You can correct the model name or other machine fields in `config/device.json`:

```json
{
  "model_name": "MacBook Air",
  "memory_bytes": 17179869184
}
```

Nonempty configured values override detected values; unknown keys are ignored. Use JSON numbers for `logical_cpus` and `memory_bytes`. If you start Compose directly without the setup script, run the collector yourself; otherwise only configured fields are available.

Change the local repository filename (and the outgoing name before its suffix) by editing the second, tab-separated column in `config/device-files.tsv`:

```text
/data/generated/device-report.json	device/client-info.json
```

To opt in to more content, edit `config/device-report.sh`:

```sh
INCLUDE_CONFIGURATION=true
INCLUDE_CONTAINER_INFO=true
```

The configuration snapshot includes the complete text of every regular file under `config/` and `jobs/`, plus `compose.yaml` and `Dockerfile` under `deployment/`. It does not source job scripts. Symlinks and special files fail the report instead of following them into other mounts. Credentials, other input files, bridge data, and runtime state are not copied. Configuration/script text is uploaded verbatim when enabled, so keep secrets in `.state/credentials`, not in those files.

Optional runtime details are explicitly labeled `container_runtime`. The default report has `configuration` and `container_runtime` set to `null`. Failed report generation leaves the previous capture unchanged; the push job can still publish previously committed files.

To disable device capture, comment out its line in `config/commit-jobs`. Each successful report publication counts as repository activity for the server's inactivity check, even when the location capture fails.

## Capture jobs

Each capture job is a shell settings file:

```sh
JOB_NAME='location'
LOCATION_MODE='bridge'
LOCATION_FILE='device/location.json'
LOCATION_COMMAND=''
FILES_LIST='/config/files.tsv'
BEFORE_COMMAND=''
TIMEOUT_SECONDS=300
```

`LOCATION_MODE` is `bridge`, `command`, or `none`. Use `none` for file-only or command-only jobs. `BEFORE_COMMAND`, when set, runs inside the container before collecting location and files. Capture jobs run sequentially, each with its configured execution timeout.

For extra files, put host files in `.state/input`. The container reads that directory as `/input`; generated files can be written under `/data`, which maps to `.state/data`. Add one source and destination per line in `config/files.tsv`, separated by a literal tab:

```text
/input/notes.txt	device/notes.txt
/data/generated/status.txt	reports/status.txt
```

Use repository-relative destination paths. Nested directories are supported; absolute destinations, parent traversal and `.git` paths are rejected. Missing source files fail that capture without replacing its previous output. The commit job also commits other files already present in the repository directory.

The included `config/jobs/files.sh` and `jobs/example.sh` demonstrate generating and capturing a container status file. Uncomment the files-job line in `config/commit-jobs` to enable it. An empty `config/commit-jobs` still commits files already present in the configured repository. Add other shell jobs directly to the crontab when no Git update is needed.

## Location provider

For `command` mode, set `LOCATION_COMMAND` to a command that prints only a location object, for example a file refreshed by a host location tool:

```sh
LOCATION_MODE='command'
LOCATION_COMMAND='cat /input/location.json'
```

The provider must return this shape using its real measured values:

```json
{
  "source": "host_location_service",
  "observed_at": "YYYY-MM-DDTHH:MM:SSZ",
  "latitude": 0,
  "longitude": 0,
  "horizontal_accuracy_m": 0,
  "altitude_m": null
}
```

The values above illustrate the schema, not a usable fix. Coordinates, accuracy and observation time are validated. Fixes older than 180 seconds are rejected. The client adds `recorded_at` and saves the latest accepted sample in `.state/data/location.json`.

In `bridge` mode, the container writes `.state/bridge/requests/request.json`:

```json
{"request_id":"a UUID","requested_at_unix":0}
```

The external host provider must write `.state/bridge/responses/response.json` atomically, using the same request ID:

```json
{"request_id":"the same UUID","status":"ok","location":{"source":"host_location_service","observed_at":"YYYY-MM-DDTHH:MM:SSZ","latitude":0,"longitude":0,"horizontal_accuracy_m":0,"altitude_m":null}}
```

For a failure, return `{"request_id":"the same UUID","status":"error","error":"reason"}`. Each request waits up to 120 seconds. This repository does not install a native location provider; install/configure one separately for the host OS, or use file-only jobs.

## Inspect and control

```sh
docker compose ps
docker compose logs --tail 60 client
# Capture configured jobs and commit all repository changes now:
docker compose exec client /app/commit.sh
# Push pending committed files now:
docker compose exec client /app/push.sh
# Capture one job, commit all repository changes, and push as a convenience:
docker compose exec client /app/push.sh /config/jobs/device.sh
# Stop or resume schedules:
docker compose stop
docker compose start
```

On Windows Git Bash, prefix a `docker compose exec` command with `MSYS_NO_PATHCONV=1` if it would otherwise rewrite container paths.

The laptop must be awake and Docker running; missed cron times are not replayed. A healthy container means cron is alive, not that the most recent commit or push succeeded. Read the logs and `/data/status` for job results. Failed location capture leaves previous remote snapshots intact.

## Tests

Run `./tests/run.sh` to build the image and exercise report generation, credential preparation, publishing, and live schedule reloads in containers with networking disabled. The tests use mocked hardware, harmless cron commands, and a temporary local Git repository; they do not push to GitHub.
