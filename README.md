# Dockerfiles

- [Laptop location client](images/laptop-location-client): cron and POSIX shell scripts for scheduled location, machine information, and file updates to a configured Git repository; client configuration snapshots are opt-in.
- [Laptop location server](images/laptop-location-server): daily GitHub or Codeberg inactivity checks that make the configured repository public, then remove their cron job. GitHub uses last-push time; Codeberg conservatively uses repository update time.
- [Portable server function](images/laptop-location-server/function): the same inactivity check as a dependency-free Python function, with a callback for removing any hosting scheduler's trigger.
- [Server composite action](.github/actions/server-check): run the Python check from a GitHub Actions workflow and expose its result as step outputs.

The `images` space in [dispat.yaml](dispat.yaml) shares inline build and push scripts between the two image packages:

```sh
dispat run build --space images --since all
dispat run push --space images --since all
```

The server package also owns the moving repository tag `v{major}` on Dispat's stable channel. Its first stable `1.x` release creates `v1` for composite-action consumers; RC releases receive only their versioned package tags. Use Dispat to record releases so these aliases follow the package version.

## GitHub CI/CD

[Images CI and CD](.github/workflows/images.yml) validates Compose and shell scripts, builds both images, and runs their offline test suites on pull requests, branch pushes, `v*.*.*` version-tag pushes, and manual runs. It also tests the server composite action. Publishing waits for both packages to pass. Pull requests and manual runs only test.

After a successful push to the default branch, the workflow publishes `linux/amd64` images to Docker Hub as `<namespace>/laptop-location-client:latest` and `<namespace>/laptop-location-server:latest`. A `v*.*.*` Git tag publishes that exact tag, such as `v1.2.3`. Every published image also receives `sha-<full-commit-sha>`; tag builds do not replace `latest`. Moving major aliases such as the composite action's `v1` do not trigger image publication.

Configure these in GitHub **Settings → Secrets and variables → Actions** before the first publication:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `DOCKERHUB_USERNAME` | Docker Hub login username. |
| Secret | `DOCKERHUB_TOKEN` | Docker Hub access token with permission to push both repositories. |
| Variable, optional | `DOCKERHUB_NAMESPACE` | Docker Hub organization or account owning the images; defaults to the login username. |

Create `laptop-location-client` and `laptop-location-server` repositories in that namespace and grant the token access to them. A personal access token needs read/write repository access. See Docker's [GitHub Actions setup](https://docs.docker.com/build/ci/github-actions/) and [access-token documentation](https://docs.docker.com/security/access-tokens/). The workflow publishes images; it does not start containers or run the repository-publication check against a real repository.
