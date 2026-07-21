# Valkey queue primary storage migration

This runbook moves the queue primary from the legacy `ceph-block` PVC to the
prepared `ceph-block-app-replicated` PVC. It intentionally uses separate
GitOps commits for every state transition. Do not combine the consumer pause,
primary shutdown, copy, primary restore, or cleanup into one Argo CD sync.

The copy Job is deliberately **not** listed in `kustomization.yaml`. It is safe
to commit as dormant preparation and must only be activated after phase 3 has
removed the primary StatefulSet and pod.

## Fixed names

- Source PVC: `valkey-data-valkey-queue-primary-0`
- Target PVC: `valkey-queue-primary-app-replicated`
- Primary StatefulSet/pod: `valkey-queue-primary` / `valkey-queue-primary-0`
- Replica StatefulSet/pods: `valkey-queue-replicas` / replicas `0` and `1`
- Only observed application client: `media/immich-server`

The 5.4.9 chart renders no primary StatefulSet when
`primary.replicaCount: 0`. This gives Argo CD a clean delete/recreate boundary
and avoids trying to mutate the StatefulSet's immutable
`volumeClaimTemplates` when `existingClaim` is enabled.

## Phase 0: baseline gate

Do not start while another storage migration is holding the cluster in a
degraded state. In particular, let the active Prometheus migration finish and
restore monitoring before this cutover. Require Ceph `HEALTH_OK`, all PGs clean,
all nodes Ready, both Valkey replicas Ready, and no AOF rewrite in progress.

Record the pre-cutover key count and check all three data copies:

```sh
for pod in valkey-queue-primary-0 valkey-queue-replicas-0 valkey-queue-replicas-1; do
  kubectl -n databases exec "$pod" -c valkey -- bash -lc '
    export VALKEYCLI_AUTH="$(< /opt/bitnami/valkey/secrets/valkey-password)"
    valkey-cli INFO replication | egrep "^(role|connected_slaves|master_link_status|master_sync_in_progress|master_repl_offset|slave_repl_offset|slave[0-9])"
    valkey-cli INFO persistence | egrep "^(aof_enabled|aof_rewrite_in_progress|aof_rewrite_scheduled|aof_last_bgrewrite_status|aof_last_write_status)"
    valkey-cli DBSIZE
  '
done
```

Required results:

- primary role is `master`, `connected_slaves:2`, and both replicas are online;
- both replicas report `master_link_status:up` and no sync in progress;
- all nodes have AOF enabled and both last AOF status fields are `ok`;
- all three `DBSIZE` results match.

## Phase 1: make replicas tolerate the brief primary outage

Commit only this change to `values.yaml`, under the existing `replica:` block:

```yaml
  customLivenessProbe:
    exec:
      command:
        - /usr/bin/bash
        - -ec
        - /health/ping_liveness_local.sh 5
    initialDelaySeconds: 20
    periodSeconds: 5
    timeoutSeconds: 6
    failureThreshold: 5
  customReadinessProbe:
    exec:
      command:
        - /usr/bin/bash
        - -ec
        - /health/ping_readiness_local.sh 1
    initialDelaySeconds: 20
    periodSeconds: 5
    timeoutSeconds: 2
    failureThreshold: 5
```

This rolls the replicas one at a time while the primary is still available.
Wait for the rollout, then repeat the phase 0 replication and AOF gates. Both
replicas must be Ready and caught up before proceeding.

## Phase 2: pause the only queue consumer

Do this before activating the separately prepared Immich storage migration:
that migration is intentionally gated on a healthy Valkey cutover. Commit only
`spec.replicas: 0` for `media/immich-server`. Do not combine this with a Valkey
change or accidentally stage the dormant Immich storage-migration edits in the
shared worktree. The machine-learning Deployment was not observed connecting
directly to Valkey and does not need to be stopped for this cutover.

Wait until the server pod is gone. Then run the final durability gate on the
still-running primary:

```sh
kubectl -n databases exec valkey-queue-primary-0 -c valkey -- bash -lc '
  export VALKEYCLI_AUTH="$(< /opt/bitnami/valkey/secrets/valkey-password)"
  valkey-cli WAIT 2 5000
  valkey-cli WAITAOF 1 2 5000
  valkey-cli DBSIZE
  valkey-cli INFO replication
  valkey-cli INFO persistence
  valkey-cli CLIENT LIST
'
```

Require `WAIT` to return `2`, `WAITAOF` to return local `1` and replicas `2`,
the recorded key count to remain unchanged, both replicas online at the
primary's replication offset, and no application client IPs. Replica links and
the diagnostic CLI itself are expected clients.

## Phase 3: remove the old primary

Commit only this addition beneath `primary:` in `values.yaml`:

```yaml
  replicaCount: 0
```

Wait for Argo CD to prune the primary StatefulSet and for
`valkey-queue-primary-0` to disappear. Confirm the legacy source PVC remains
Bound and the two replica pods remain Running/Ready under their temporary
local-only probes. `master_link_status:down` is expected during this outage.

Do not proceed while a primary pod exists or while the source PVC is mounted.

## Phase 4: copy and verify offline

Activate the already-prepared Job in a new commit by adding this one resource
to `kustomization.yaml`:

```yaml
  - storage-migration-copy-job.yaml
```

The Job refuses to touch the target if either the primary Service or the
primary pod's headless DNS name answers a PING. Required pod anti-affinity also
keeps it off a node that still has a primary pod, so a surviving primary holds
the RWO source attachment on another node. The Job mounts the source read-only,
clears only non-`lost+found` target content, copies the offline tree, syncs it,
and verifies file-content and tree-metadata SHA-256 manifests. An interrupted
run starts over safely; a completed run with a marker only re-verifies.

Require Job `Complete` and retain its log line containing `verified files=`,
`bytes=`, `files_sha256=`, and `tree_sha256=`. A Failed Job is a stop condition;
do not start the primary from an unverified target.

## Phase 5: start the primary on the target

After the Job is Complete, make one commit that:

1. removes `storage-migration-copy-job.yaml` from `kustomization.yaml`; and
2. replaces the temporary primary values with:

```yaml
primary:
  replicaCount: 1
  persistence:
    enabled: true
    storageClass: ceph-block-app-replicated
    existingClaim: valkey-queue-primary-app-replicated
    size: 20Gi
```

Keep the temporary replica probes from phase 1. The chart now creates a fresh
StatefulSet with an explicit PVC volume instead of an immutable claim template.

Before resuming Immich, require all of the following:

- primary pod is Ready and mounted to the target PVC;
- startup logs contain no AOF truncation, corruption, or recovery error;
- `DBSIZE` equals the value recorded before shutdown;
- `aof_enabled:1`, `aof_last_write_status:ok`, and
  `aof_last_bgrewrite_status:ok`;
- `connected_slaves:2`, both replicas online, no sync in progress, and offsets
  converged;
- `WAIT 2 5000` returns `2`; and
- `WAITAOF 1 2 5000` returns local `1` and replicas `2`.

If startup or validation fails, keep Immich paused, set `replicaCount: 0` again,
and investigate. The legacy source has not been changed or deleted. A clean
rollback can point `primary.persistence.existingClaim` at
`valkey-data-valkey-queue-primary-0` and restore `replicaCount: 1`.

## Phase 6: restore normal replica health checks

Remove only `replica.customLivenessProbe` and
`replica.customReadinessProbe` from `values.yaml`. Wait for both replicas to
roll one at a time and repeat the replication, AOF, `WAIT`, and `WAITAOF` gates.

## Phase 7: continue directly into the Immich storage migration

The quickest safe path is to keep `media/immich-server` at zero after the
Valkey target and both replicas pass phase 6. Commit the separately prepared
Immich storage migration next. Its desired Deployment has `replicas: 1`, but
its restart-safe copy init keeps the application unavailable until the new
critical-pool claim has been verified; it therefore reuses the same coordinated
downtime instead of briefly starting Immich on the legacy claim and stopping it
again.

Require the Immich storage copy and application validation gates from its own
runbook, followed by the Immich ping endpoint, Valkey AOF status, and expected
Immich client reconnections. Queue activity may change `DBSIZE` after this
point, so the exact pre-cutover count is no longer a valid gate.

Only if the Immich storage migration is explicitly deferred should a separate
commit restore `media/immich-server` to `spec.replicas: 1` immediately after
phase 6.

## Phase 8: recycle paused VolSync state

Offsite ReplicationSources are globally paused, but their scratch/cache PVCs
still consume the legacy pool. Recycle the two queue ReplicationSources in two
separate syncs:

1. temporarily remove only `valkey-queue-node-0-backup` and
   `valkey-queue-node-1-backup` ReplicationSource documents from
   `replicationsources/platform.yaml`, leaving their ExternalSecrets; wait for
   both ReplicationSources, mover Jobs, scratch PVCs, and cache PVCs to be gone;
2. recreate the paused definitions with these changes:

```yaml
# valkey-queue-node-0-backup
spec:
  sourcePVC: valkey-queue-primary-app-replicated
  restic:
    storageClassName: ceph-block-app-replicated
    cacheStorageClassName: ceph-block-app-replicated

# valkey-queue-node-1-backup
spec:
  sourcePVC: valkey-data-valkey-queue-replicas-0
  restic:
    storageClassName: ceph-block-app-replicated
    cacheStorageClassName: ceph-block-app-replicated
```

Keep `volumeSnapshotClassName: ceph-block-snap`; it selects the RBD CSI driver
and works for both RBD pools. Confirm every recreated Valkey VolSync scratch and
cache PVC uses `ceph-block-app-replicated` before cleanup.

## Phase 9: prune legacy queue storage

Only after the new primary, both replicas, Immich, and the recreated paused
ReplicationSources are healthy:

1. verify no pod, Job, ReplicationSource, VolumeSnapshot, or VolumeAttachment
   references any of these claims;
2. remove `storage-migration-legacy-pvcs.yaml` from `kustomization.yaml` and
   delete the file so Argo CD prunes:
   - `valkey-data-valkey-queue-primary-0`
   - `valkey-data-valkey-queue-node-0`
   - `valkey-data-valkey-queue-node-1`
3. remove the now-unused `migration-primary-service.yaml`; and
4. verify all three legacy PVs and their RBD images are gone before counting
   `ceph-block` as free of Valkey data.

Keep `valkey-queue-primary-app-replicated` permanently declared in Git and keep
the final `existingClaim` setting in chart values.
