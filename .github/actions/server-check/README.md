# Server repository check

This composite action runs the existing [server Python CLI](../../../images/laptop-location-server/function). It installs Python 3.13, checks GitHub or Codeberg activity, and makes an inactive repository public after the configured threshold. It has no Docker or third-party Python dependency. The bundled script is resolved from the action directory, so using it from another repository does not require checking out this repository yourself.

## Inputs and outputs

| Input | Default | Meaning |
| --- | --- | --- |
| `provider` | `github` | `github` or `codeberg`. |
| `repository` | Required | Target `OWNER/REPOSITORY`. |
| `token` | Required | Provider API token from a secret, with permission to change the target repository's visibility. |
| `inactivity-days` | `30` | Positive integer; publication requires strictly more than this many inactive days. |

Use the [server token permissions](../../../images/laptop-location-server/README.md#configure-and-run) for the chosen provider. GitHub's default `GITHUB_TOKEN` does not grant repository administration; supply a suitable token as a separate secret. Codeberg checks use repository `updated_at` conservatively, so non-push activity can delay publication.

| Output | Meaning |
| --- | --- |
| `result` | Complete JSON result from the server CLI. |
| `status` | `active`, `published`, or `already_public`. |
| `stop-schedule` | String `true` after confirmed public visibility; otherwise `false`. |
| `activity-at` | Provider activity timestamp, or empty when unavailable. |
| `activity-source` | `pushed_at` for GitHub or `updated_at` for Codeberg. |

Invalid settings and API failures fail the step. The action performs one check and leaves schedule management to the caller; it does not create a schedule, retain completion across runs, or disable other workflows. The JSON result's `schedule_removed` remains `false` until the caller handles scheduling separately.

## Use from a workflow

Dispat creates the moving `v1` alias when the server package enters the stable `1.x` line. It is not created for an RC. After that stable tag is pushed, use `yohimik/dockerfiles/.github/actions/server-check@v1`, or pin a published commit SHA. For the current checkout, use the local path shown below.

For a daily check in this repository, save the following as `.github/workflows/repository-monitor.yml` and configure a `REPOSITORY_TOKEN` Actions secret. The example monitors its own repository; change `provider` and `repository` to monitor a different GitHub or Codeberg repository.

```yaml
name: Repository monitor
on:
  schedule:
    - cron: '17 0 * * *'
  workflow_dispatch:

permissions:
  contents: read
  actions: write

concurrency:
  group: repository-monitor
  cancel-in-progress: false

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          persist-credentials: false
      - uses: ./.github/actions/server-check
        id: monitor
        with:
          provider: github
          repository: ${{ github.repository }}
          token: ${{ secrets.REPOSITORY_TOKEN }}
          inactivity-days: '30'
      - name: Disable this monitor after completion
        if: steps.monitor.outputs.stop-schedule == 'true'
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh api --method PUT "repos/$GITHUB_REPOSITORY/actions/workflows/repository-monitor.yml/disable"
```

The example runs at 00:17 UTC. Its final step uses the caller repository's `GITHUB_TOKEN` with `actions: write` to disable only the named monitor workflow, including its manual trigger. Keep the filename in the API path aligned with the workflow filename. Disabling the workflow is separate from changing the monitored repository's visibility; if that step fails, the next run retries after checking visibility again. Re-enable the workflow deliberately to resume monitoring. See GitHub's [workflow-disable API](https://docs.github.com/en/rest/actions/workflows#disable-a-workflow).

For use from another repository, replace the checkout and local action steps with the remote `uses` reference above. The action's repository and ref must be accessible to the caller. Pass the target repository explicitly and use a provider token authorized for that target; the workflow-disable step still addresses the repository hosting the workflow.

## Tests

```sh
python3 -m unittest discover -s .github/actions/server-check/tests -v
```

Tests mock provider transport and never change remote repository visibility. The image CI runs them inside the server image with networking disabled.
