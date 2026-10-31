# Laptop location client

A Docker client implemented with cron and POSIX `.sh` scripts. It captures location from a configured provider, reports machine specifications and model name, copies selected files, and commits and pushes them to the Git URL in its configuration. It can also run other scheduled shell commands.

The same Linux container runs on Docker Engine for Linux and Docker Desktop for macOS or Windows. On Windows, run the setup script from Git Bash or WSL. The image uses standard command-line tools: Git, OpenSSH, jq, curl, coreutils, and flock. It contains no Python or native host helper code.

Precise location requires an external host location provider. A Linux container cannot itself call macOS or Windows Location Services. The `bridge` mode lets an existing host provider respond when cron requests a fresh fix; `command` mode runs a configured command that returns location JSON. No approximate-IP fallback is enabled.

## Configuration

Edit or replace these files. There is no separate environment file.

| File | Purpose |
| --- | --- |
| `config/settings.sh` | Git URL, branch, commit author and IANA timezone. |
| `config/crontab` | Normal five-field cron schedules, including arbitrary shell jobs. |
| `config/jobs/*.sh` | Location options, extra-file list, pre-command and timeout for each publishing job. |
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
TZ='Etc/UTC'
```

The `.sh` settings are trusted executable shell configuration. Keep secrets out of them. To change location capture from hourly to every two hours, edit its line in `config/crontab`:

```cron
0 */2 * * * /app/push.sh /config/jobs/location.sh >>/proc/1/fd/1 2>>/proc/1/fd/2
```

Use numeric cron fields with ranges, lists and steps. Sunday is `0`; this BusyBox cron does not support the `7` alias or `@reboot`. The client does not automatically publish on startup. Restart the container after changing its cron schedule, timezone, or credentials:

```sh
docker compose restart
```

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

The enabled `config/jobs/device.sh` job publishes `device/client-info.json` every hour at minute `5`, independently of location capture. By default, the report includes **only machine specifications and model name**, plus a schema version and report timestamp. Client configuration and container information are disabled by default.

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

Change the repository filename by editing the second, tab-separated column in `config/device-files.tsv`:

```text
/data/generated/device-report.json	device/client-info.json
```

To opt in to more content, edit `config/device-report.sh`:

```sh
INCLUDE_CONFIGURATION=true
INCLUDE_CONTAINER_INFO=true
```

The configuration snapshot includes the complete text of every regular file under `config/` and `jobs/`, plus `compose.yaml` and `Dockerfile` under `deployment/`. It does not source job scripts. Symlinks and special files fail the report instead of following them into other mounts. Credentials, other input files, bridge data, and runtime state are not copied. Configuration/script text is uploaded verbatim when enabled, so keep secrets in `.state/credentials`, not in those files.

Optional runtime details are explicitly labeled `container_runtime`. The default report has `configuration` and `container_runtime` set to `null`. A failed report generation fails the job before any push; an older cached report is not uploaded as a replacement.

To disable this job, comment out its line in `config/crontab` and restart the container. Each successful report update counts as repository activity for the server's inactivity check, even when the location job fails.

## Publishing jobs

Each publishing job is a shell settings file:

```sh
JOB_NAME='location'
LOCATION_MODE='bridge'
LOCATION_FILE='device/location.json'
LOCATION_COMMAND=''
FILES_LIST='/config/files.tsv'
BEFORE_COMMAND=''
TIMEOUT_SECONDS=300
```

`LOCATION_MODE` is `bridge`, `command`, or `none`. Use `none` for file-only or command-only jobs. `BEFORE_COMMAND`, when set, runs inside the container before collecting location and files. All commands run with the job's execution timeout. Different publishing jobs run sequentially; overlapping instances of the same job are skipped.

For extra files, put host files in `.state/input`. The container reads that directory as `/input`; generated files can be written under `/data`, which maps to `.state/data`. Add one source and destination per line in `config/files.tsv`, separated by a literal tab:

```text
/input/notes.txt	device/notes.txt
/data/generated/status.txt	reports/status.txt
```

Use repository-relative destination paths. Nested directories are supported; absolute destinations, parent traversal and `.git` paths are rejected. Missing source files fail the job without a push. Only configured files are updated; unrelated repository files are preserved.

The included `config/jobs/files.sh` and `jobs/example.sh` demonstrate generating and publishing a container status file. Uncomment their schedule in `config/crontab` to enable them. Add other shell jobs directly to the crontab when no Git update is needed.

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
# Run one job now:
docker compose exec client /app/push.sh /config/jobs/location.sh
# Publish the device report now:
docker compose exec client /app/push.sh /config/jobs/device.sh
# Stop or resume schedules:
docker compose stop
docker compose start
```

On Windows Git Bash, prefix a `docker compose exec` command with `MSYS_NO_PATHCONV=1` if it would otherwise rewrite container paths.

The laptop must be awake and Docker running; missed cron times are not replayed. A healthy container means cron is alive, not that the most recent push succeeded. Read the logs for job results. Failed location capture leaves the previous remote file intact. Updating one path retains earlier versions in Git history.

## Tests

Run `./tests/run.sh` to build the image and exercise report generation and publishing in a container with networking disabled. The tests use a temporary local Git repository and do not push to GitHub.
