# Renovate and Harbor artifact promotion

Renovate discovers releases from upstream registries and chart repositories even
though cluster workloads continue to pull from Harbor. The source-of-truth mapping
is `artifact-sources.json`; `scripts/check-renovate-coverage.mjs` verifies that the
matching Renovate rules and every checked-in Harbor mirror reference remain covered.

During backlog draining, Renovate runs every 15 minutes in America/Los_Angeles and
limits the repository to five concurrent Renovate pull requests. Low-risk
application updates can open pull requests immediately. Major and coordinated
platform updates stay visible in the Dependency Dashboard until explicitly
approved. Automerge is disabled. Return the CronJob to a daily cadence after the
accumulated drift is cleared.

## Promoter behavior

During backlog draining, `renovate-promoter` runs every five minutes. It processes
open pull requests and also retries Renovate pull requests merged within the last
24 hours when their head commit does not have a successful promotion status. This
recovery window prevents an early merge from permanently skipping artifact copying.
Eligible pull requests must:

- belong to `rrumana/k8s-cluster` and target `main`;
- have a same-repository branch beginning with `renovate/`; and
- are authored by the configured `GITHUB_ALLOWED_AUTHOR` account.

Successful PR heads are skipped on later runs. Failed or missing promotion statuses
are retried while the PR remains open or inside the merged-PR recovery window.

It reads changed files through the GitHub API and never checks out or executes pull
request code. Images are copied by digest and verified after upload. Existing tags
with different content are never overwritten. Mirrored Helm charts are pulled from
their cataloged upstream, rendered with the pull request's value files, and have all
mapped transitive images promoted before the chart is pushed.

The promoter publishes the commit status `renovate/artifacts-promoted`. Configure
that status as a required check before merging Renovate pull requests.

## Credentials

For initial testing, the promoter reuses the existing `harbor-pull-creds` Docker
configuration for Harbor authentication and the `RENOVATE_TOKEN` in
`renovate-secrets` for GitHub access. Despite its current name, `harbor-pull-creds`
must allow the promoter to publish to `mirror` and `thirdparty-charts` and read from
`apps-private`. These shared credentials should be renamed and split into
least-privilege responsibilities in a later change.

The GitHub token must have repository read and commit-status write permission. The
promoter pod has no service-account token and no Kubernetes RBAC.

Promoter tool updates are dashboard-gated. When approving a
`google/go-containerregistry` update, also replace `CRANE_SHA256` with the SHA-256
of the named upstream release archive; the pod refuses to execute an archive whose
checksum does not match.

## Adding a dependency

1. Add the exact Harbor-to-upstream prefix to `artifact-sources.json` when it is a
   new image namespace, and add the matching lookup rule to the root `renovate.json`.
2. Add every new mirrored chart to the catalog with its Argo application path and
   true upstream repository.
3. Add a `# renovate: datasource=... depName=...` annotation for version values in
   scripts, bootstrap files, Dockerfiles, or manual compatibility tracks that normal
   Renovate managers cannot safely update.
4. Run:

   ```bash
   node scripts/check-renovate-coverage.mjs
   node cluster/platform/automation/renovate/promoter.test.mjs
   docker run --rm -v "$PWD:/repo" -w /repo \
     ghcr.io/renovatebot/renovate:43.288.0 \
     renovate-config-validator renovate.json
   docker run --rm -v "$PWD:/repo" -w /repo \
     --entrypoint /bin/bash ghcr.io/renovatebot/renovate:43.288.0 \
     -ec 'install-tool helm 3.18.6 >/dev/null; node scripts/check-chart-artifact-coverage.mjs'
   kubectl kustomize cluster/platform/automation/renovate >/dev/null
   ```

Dependencies in `dependencies/renovate-manual-tracks.yaml` intentionally report drift without
claiming that a compatible private image or regenerated installation manifest exists.
Their Renovate pull requests must be amended with the documented rebuild or upgrade
work before merge.
