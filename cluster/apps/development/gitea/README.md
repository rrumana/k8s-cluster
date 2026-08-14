# Gitea platform

This deployment makes Gitea the private, operator-controlled Git and Actions
platform at `https://git.rcrumana.xyz`. GitHub remains the public mirror and the
repository source used by Argo CD during the initial migration.

## Architecture

- Two rootless Gitea 1.27 replicas on separate control-plane nodes.
- A retained 100 GiB `ReadWriteMany` PVC on replicated CephFS for Git
  repositories, LFS, packages, attachments, avatars, and Actions artifacts.
- A dedicated database and non-superuser role on the three-instance
  `pg-platform` CloudNativePG cluster.
- Three dedicated persistent Valkey nodes. Each pod runs Sentinel; quorum is
  two and a primary failover does not require Gitea to restart.
- OpenSearch-backed issue and repository indexes. The `gitea` OpenSearch user
  can only operate on `gitea_issues*` and `gitea_codes*` plus read cluster
  health. Indexes are rebuildable and are not part of the authoritative data.
- Authentik OpenID Connect as the only displayed web sign-in method. Password
  and passkey sign-in are disabled; a generated local `gitea-admin` account is
  retained for GitOps-enabled break-glass recovery.
- Private HAProxy ingress with HTTPS only. SSH Git transport is disabled.
- One organization-scoped Actions runner in the isolated `ci` namespace. It
  has capacity one, a rootless DinD sidecar, no Kubernetes token, no host
  mounts, and egress limited to Gitea, Harbor, DNS, and public HTTP(S).

The Gitea and runner charts and every runtime image are pinned and expected to
be mirrored in Harbor. External Secrets generates the initial credentials once
and pushes them into Vault with `IfNotExists`; normal reconciliation never
rotates those stateful values.

The generated Vault records live under `kv/apps/development/` as
`gitea-postgresql`, `gitea-valkey`, `gitea-admin`, `gitea-oidc`,
`gitea-secret-key`, `gitea-internal-token`, `gitea-lfs-jwt`,
`gitea-oauth2-jwt`, and `gitea-opensearch`. Back up these records before
accepting authoritative data. In particular, never casually regenerate the
Gitea secret/JWT keys: existing encrypted credentials and signed tokens depend
on them.

## Review and first deployment

No live-cluster command is required to prepare this change. Before merging:

1. Review the complete diff and rendered output.
2. Confirm private DNS resolves `git.rcrumana.xyz` to `192.168.1.230` from the
   LAN and tailnet.
3. Seed the pinned charts and images in Harbor. This changes Harbor, not the
   Kubernetes API. The script requires Helm and `crane`; `crane copy` preserves
   and verifies the manifest digests referenced by the workloads:

   ```bash
   HARBOR_PASSWORD='...' ./scripts/seed-gitea-prereqs.sh
   ```

After the reviewed Git change reaches the Argo source repository, use this
order:

1. Let `external-secrets-extras` seed the new Vault paths.
2. Verify `pg-platform`, `valkey-gitea`, `opensearch-logs`, and
   `shared-ingress` are healthy.
3. Manually sync the existing `authentik` Application so the Gitea OIDC
   provider and `app-gitea` group are created.
4. Verify Authentik discovery returns a document at
   `https://auth.rcrumana.xyz/application/o/gitea/.well-known/openid-configuration`.
5. Add the intended operators to Authentik `app-gitea` (platform administrators
   are already authorized), then sync/verify the `gitea` Application and test
   OIDC.
6. Retain the local `gitea-admin` account solely for recovery. Its password is
   in Vault at `kv/apps/development/gitea-admin`, property `password`. A reviewed
   GitOps change that temporarily sets `ENABLE_PASSWORD_SIGNIN_FORM: true` is
   required before the account can sign in through the web UI.

The `gitea-actions` Application is intentionally manual. Gitea must exist before
its organization registration token can be created.

## Actions runner bootstrap

Create a dedicated trusted organization in Gitea, then generate an
organization-scoped runner registration token. Write only that token to Vault:

- path: `kv/apps/development/gitea-actions-runner`
- property: `token`

After writing the token, manually sync the `gitea-actions` Application. Its
negative sync wave makes Argo wait for the `gitea-actions-token` ExternalSecret
before starting the runner. Keep runner ownership at the organization level,
do not register it instance-wide, and initially enable Actions only for repos
whose workflow changes require trusted review. Fork pull requests and
untrusted contributors must require approval before a workflow receives
repository secrets.

The configured `ubuntu-latest` job image is a digest-pinned Gitea runner image
mirrored in Harbor. Repository secrets such as Harbor robot credentials belong
in Gitea's organization/repository Actions secrets, not in this cluster repo.

## Repository migration

Migrate one repository at a time:

1. Create an empty private repository in the trusted Gitea organization.
2. Push all refs and verify branches, tags, releases, LFS objects, and default
   branch protection.
3. Configure a Gitea push mirror to the existing public GitHub repository with
   a narrowly scoped GitHub token.
4. Push a test commit to Gitea and verify the GitHub mirror advances.
5. Move developer `origin` to the HTTPS Gitea URL. Keep a read-only `github`
   remote for diagnostics if useful.
6. Leave Argo CD pointed at GitHub until the Gitea backup/restore path has been
   tested and the desired control-plane dependency has been reviewed.

Gitea push mirroring is deliberately one-way. Do not accept independent writes
to both Gitea and GitHub after cutover; that creates divergent authorities.

## Storage choice: CephFS and RGW

Git repositories require POSIX filesystem semantics: directory trees, file
locking, atomic rename, permissions, and many small random reads and writes.
CephFS provides those semantics and permits both Gitea replicas to mount the
same data. RGW is an S3-compatible object API and cannot replace the repository
filesystem.

RGW can later replace local storage for blob-like classes that Gitea supports
through its object-storage backend: LFS objects, packages, attachments, avatars,
repo archives, and Actions logs/artifacts. That can reduce CephFS metadata
pressure, provide independent lifecycle policies, and make large-object
replication/backup easier. It also adds S3 credentials, bucket policy, network
dependency, and a second restore path. At this cluster's current scale, CephFS
is the simpler and more failure-contained default.

Revisit RGW when object data materially dominates Git repository data, CephFS
metadata latency becomes measurable, different retention policies are needed,
or an independently replicated S3 endpoint becomes operational. Repository
data will remain on CephFS regardless.

## Why a dedicated Sentinel deployment

The existing shared Valkey deployments do not expose Sentinel and have
different durability policies: cache uses eviction and no persistence, while
queue is a separate persistent workload. Gitea uses Valkey simultaneously for
cache, sessions, and durable queue coordination. Reusing a standalone endpoint
would make every Gitea replica dependent on a single Valkey primary and would
mix incompatible eviction/failure behavior.

The dedicated deployment is small rather than sharded: one primary, two
replicas, three Sentinels, 1 GiB maximum dataset, and four logical databases
(cache, sessions, queue, and the cross-replica global lock).
It uses AOF `everysec`, disables RDB snapshots, refuses eviction, and requires a
healthy replica before acknowledging writes.

Sentinel is also worth considering for the shared queue if its clients support
Sentinel discovery and queue continuity justifies the additional stateful pods.
It is usually unnecessary for a disposable cache: clients should tolerate a
cache reset, and persistence can make cache recovery slower and costlier. Do
not combine cache and durable queue roles solely to reduce pod count.

## Backups and restore order

Backups are not currently operational cluster-wide. The Gitea CephFS
`ReplicationSource` is committed in a paused state and refers to a future
`gitea-data-backup-restic` Secret. CloudNativePG WAL archiving is also on its
existing safety hold. Until both database and filesystem backup/restore tests
pass, Gitea must not contain the only copy of any repository.

A valid recovery captures both PostgreSQL and CephFS within a controlled
window. If Authentik is unavailable, first prepare the reviewed temporary
GitOps override described above. Restore in this order:

1. Vault/External Secrets values, especially Gitea encryption and JWT keys.
2. `pg-platform` and the `gitea` database.
3. The `gitea-shared-storage` CephFS data from a matching recovery point.
4. Gitea replicas and local break-glass authentication.
5. Valkey (sessions and queued work may be discarded if necessary).
6. Recreate the OpenSearch indexes from Gitea.
7. Re-register the Actions runner only if its retained state is unusable.

Test clone, push, LFS, package, OIDC, Actions, and GitHub push mirroring after a
restore before declaring it complete.

## Routine checks

- Confirm both Gitea replicas are available and scheduled on different nodes.
- Confirm all three Valkey exporters report up and Sentinel sees one primary
  with two replicas.
- Watch CephFS capacity alerts at 80% and 90%.
- Verify the OpenSearch cluster remains green and both Gitea index families are
  searchable.
- Review failed/queued Actions and rotate repository-scoped credentials without
  changing the runner registration token.
- Treat the retained PVCs and `Database` resource as deletion-protected data;
  do not manually delete their dynamically provisioned claims or PVs.
