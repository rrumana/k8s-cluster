# Media library CephFS bulk migration

This stages the migration of the shared media library from the old replicated
`ceph-filesystem` filesystem to the EC 2:1 `cephfs` filesystem. It does not
change a live consumer or remove old data.

## Current recorded phase (2026-07-21)

- The retained target claim is `media/media-library-bulk`, PV
  `pvc-3c9d41ae-9801-449c-9c74-7aee4e1e04cb`, subvolume
  `csi-vol-ef558726-9083-4b68-967b-68384ebbe5f1` in group `csi`, at
  `/volumes/csi/csi-vol-ef558726-9083-4b68-967b-68384ebbe5f1/93c2eaaf-c82c-492f-a60a-1d6e552de2ec`.
  The PV reports `fsName: cephfs`, `pool: cephfs-bulk`, and reclaim policy
  `Retain`.
- `media-library-cephfs-bulk-seed-v4` is the active online seed. It is capped
  at 240 MiB/s, mounts the legacy source read-only, and uses whole-file
  sequential transfer. Completed files remain valid across a restart, while
  an interrupted current file is retransmitted rather than delta-scanned
  against an EC partial. Do not activate another target writer while it or one
  of its pods exists.
- The live Kubernetes mount inventory found only Plex, Jellyfin, and the seed
  pod mounted on the canonical old claim. ARR remains at zero replicas and its
  Deployment template still names `media-library-torrent-eva-3`.
- The NFS export remains RW on the legacy source. Ganesha's client manager
  reported only its loopback bookkeeping client, with every NFS protocol flag
  false; export I/O counters and established TCP/2049 sessions were both zero.
  This is only a point-in-time observation and is not a substitute for fencing
  the export at cutover.

## Known state and safety limits

- The source is the `media/media-library` claim, backed by
  `ceph-filesystem:/volumes/bulk/media/e51b34bd-ab57-4678-bc00-5861411d64f5`
  in `ceph-filesystem-bulk`.
- The source holds 5,520,405,814,767 bytes (5.02 TiB) and about 1.32 million
  objects. Its quota and the target claim size are 7 TiB.
- Plex and Jellyfin are the direct live consumers. ARR is at zero replicas.
  The Ganesha `/media` export had no established external sessions during the
  inventory, but that must be checked again and then fenced at cutover.
- The new EC pool had about 8.2 TiB maximum available. Coexistence is projected
  to put the cluster at 66-67% raw usage and OSD.4 near 80%; the near-full
  threshold is 85%.
- The resumed concurrent seed is capped at 240 MiB/s. It may run alongside
  other migrations while Ceph remains healthy and clean, MDS health remains
  normal, application health is stable, and OSD latency, SMART critical
  warnings, media-error counters, and actual device throttling remain within
  the monitored gates. Temperature alone is informational. Replace the Job
  with a newly named phase if a materially different throttle is needed.

## Online-seed GitOps phases

1. Add only `storage-class-cephfs-bulk-retain.yaml` to the Rook cluster
   kustomization. Wait for that Application to be Synced/Healthy and confirm
   its provisioner, filesystem, pool, and `Retain` policy.
2. Add `media-library-bulk-pvc.yaml` to the media-shared kustomization. Wait for
   the claim to bind. Confirm its PV reports `fsName: cephfs`,
   `pool: cephfs-bulk`, a nonempty `subvolumePath`, and reclaim policy
   `Retain`. Record that path for the consumer and NFS cutover.
3. Commit `media-library-bulk-copy-job.yaml` while it remains excluded from
   kustomization for inert review.
4. Add the Job to kustomization and activate it only after the target claim is
   Bound and its PV has been verified as `fsName: cephfs`, `pool: cephfs-bulk`,
   with reclaim policy `Retain`. The pinned image is authenticated in Harbor
   and supplies rsync 3.2.5 with ACL/xattr support, but is not guaranteed to be
   cached on a storage node; require Harbor healthy before first launch.
5. Monitor Ceph health, slow requests, per-OSD latency, OSD.4 temperature and
   utilization, client throughput, and target growth from the first minute.
   Suspend through GitOps if latency materially deteriorates, if any OSD
   approaches near-full, or if Ceph stops being clean. Rsync deliberately uses
   `--whole-file`: these are large reconstructable media objects, and
   sequentially retransmitting the interrupted current file is substantially
   faster than delta-scanning an EC-backed partial. Completed files are still
   skipped on restart.
6. After the online seed completes, quiesce every writer and reader through
   separate GitOps commits, explicitly disable or unmount every known external
   NFS client, fence the `/media` export, and run the phase-specific final
   delta Job. Do not rely on changing a completed Job in place.
7. As soon as a pass completes, suspend or remove its Job from desired state
   before any writer resumes. The phase marker makes an Argo self-heal replay
   a no-op, but removal is still the lifecycle boundary.

Job pod templates are immutable. Any throttle, command, or image adjustment
requires suspending/removing the current Job and creating a newly named Job.
The protected partial directory makes that replacement resumable.

The Job refuses a nonempty target unless it contains its expected identity
marker. It also refuses to replay a phase whose valid completion marker exists.
It preserves ownership, modes, hard links, ACLs, xattrs, sparse files, and
filesystem boundaries. Before launch, confirm the source has no device nodes or
privileged `security.capability` xattrs; the deliberately minimal container
capabilities make rsync fail safely rather than recreate those. After each
successful pass it performs an rsync metadata dry run and atomically writes a
completion record. Ceph checksums and rsync's transfer checks protect the data
path; a full 5 TiB checksum reread is not part of the online seed because it
would double thermal and I/O exposure.

## Prepared inert cutover artifacts

These files are intentionally absent from every kustomization and have
`spec.suspend: true`. An activation commit must both reference the selected
file and flip it to `false`.

- `media-library-bulk-final-delta-job.yaml` requires the exact target identity
  and the successful `seed:v1` marker before it can write. It uses the unique
  `.cephfs-bulk-migration-final-v1-complete` marker, preserves the seed marker,
  retains the 96 MiB/s thermal limit, performs a metadata dry-run after the
  copy, and is safe to retry only while every consumer remains quiesced.
- `ceph-nfs-bulk-media-export-fence-v1-job.yaml` validates the full legacy
  export definition and refuses to proceed while a CephFS CSI session is still
  rooted at the old media subvolume. It then removes `/media` and proves that
  the export is absent. This closes the reconnect race that a momentary socket
  check cannot close.
- `ceph-nfs-bulk-media-export-cephfs-v1-job.yaml` requires `/media` to be
  absent, validates the exact target subvolume, pool, path, state, and 7 TiB
  quota, then creates and validates the RW target export. If creation produces
  a mismatched export, it removes it and fails closed. It never silently
  overwrites or rolls back to an existing legacy export.

The live Ceph 20.2.2 CLI does not expose `nfs export apply`; changing the
filesystem/path therefore requires the supported remove/create operations.
The separate fence and target Jobs make that non-atomic transition explicit
and keep the export absent throughout the final delta.

## Exact cutover order and gates

Every item below is its own commit unless it explicitly says that two commits
may be pushed back-to-back. Do not use cross-Application sync waves as an
ordering mechanism.

1. Require the online seed Job to be `Complete`, verify the `seed:v1` marker,
   and require an empty rsync metadata dry-run. Recheck the target PV identity,
   `HEALTH_OK`, all PGs active+clean, both filesystems healthy, no slow ops, and
   acceptable OSD latency, temperature, and utilization.
2. In media-shared, remove the online seed Job from kustomization. Wait for its
   Job and pod to disappear. The old-source CephFS client from its node must
   disappear before proceeding.
3. Quiesce direct consumers. Commit Plex replicas to zero and require its pod
   absent; commit Jellyfin replicas to zero and require its pod absent. Confirm
   ARR is still zero with no pod. Disabling known external NFS clients can run
   in parallel with these scale-downs, but each client owner must explicitly
   confirm its mount is disabled or unmounted.
4. Repeat both NFS observations. `ShowClients` must contain no external client
   with an active NFS protocol, and the Ganesha host must have zero established
   TCP/2049 sessions. Then, in the Rook Application, replace the legacy export
   Job resource with the suspended fence-v1 file and flip only that file to
   `suspend: false`. Require the fence Job to succeed and `ceph nfs export info
   ceph-nfs-bulk /media` to report no export. Do not remove the stable NFS CR
   or LoadBalancer Service.
5. Require zero CephFS clients rooted at the old media path. In media-shared,
   add the suspended final-delta file and flip it to `false`. Require the Job to
   complete, its dry-run verification to be empty, and its `final:v1` marker to
   contain sensible source/target byte counts. Keep all consumers fenced.
6. Immediately remove the final-delta Job from kustomization and require its
   pod to disappear. Recheck Ceph/MDS/OSD health. No writer may resume before
   this lifecycle boundary.
7. Cut Plex to `media-library-bulk` and restore one replica in its own commit.
   Cut Jellyfin identically in a second commit. These commits may be pushed
   back-to-back after the final marker because both consumers are normally
   readers, but gate them independently: the rendered/live pod claim must be
   the target, the rollout must be healthy, the CephFS session root must be the
   target path, and a representative media stat/read must succeed.
8. In the Rook Application, replace fence-v1 with the suspended target-export
   v1 file and flip it to `false`. Require the Job to succeed and inspect the
   full export JSON: `fs_name: cephfs`, the exact target path, RW, NFS 3+4,
   TCP, `no_root_squash`, `sectype: sys`, and `security_label: true`. Remove the
   completed target-export Job from kustomization in the next commit; the
   export persists. Perform a read-only NFS mount and representative read
   before allowing external clients to reconnect.
9. While ARR remains at zero, change its Deployment from
   `media-library-torrent-eva-3` to the canonical `media-library-bulk` claim in
   a dedicated commit. Require the live Deployment template to name only the
   target. Restore one ARR replica in the next commit; require every container
   ready, qBittorrent and Servarr APIs healthy, and representative reads and a
   controlled write/rename on the target.
10. After all gates pass, confirm no workload references any of the four
    torrent aliases and no client remains on the old media path. Leave the old
    canonical claim, all five static PV bindings, old export definition, and
    old subvolume available for a rollback soak; retire them only in the later
    cleanup phase.

Useful point-in-time session checks are:

```sh
NFS_POD=$(kubectl -n rook-ceph get pod \
  -l app=rook-ceph-nfs,ceph_nfs=ceph-nfs-bulk \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n rook-ceph exec "$NFS_POD" -c nfs-ganesha -- \
  busctl --system call org.ganesha.nfsd \
  /org/ganesha/nfsd/ClientMgr org.ganesha.nfsd.clientmgr ShowClients
NFS_NODE=$(kubectl -n rook-ceph get pod "$NFS_POD" \
  -o jsonpath='{.spec.nodeName}')
ssh "rcrumana@${NFS_NODE}" \
  'sudo -n ss -Htn state established "( sport = :2049 )"'
```

An empty socket/client result cannot detect an offline client. The explicit
client shutdown plus the export fence are both required.

## Cutover requirements

The dynamically provisioned target PV exposes `subvolumeName` and
`subvolumePath`. The four torrent aliases existed to use
`read_from_replica=localize` on replicated storage. EC 2:1 has no complete
local replica, so do not recreate those aliases on the EC pool. Point ARR at
the canonical RWX `media-library-bulk` claim during cutover and retire all four
old aliases only after validation.

The current Ganesha export is `/media` on filesystem `ceph-filesystem` and the
old source path. Its access configuration is read-write, NFS protocols 3 and 4,
TCP, `no_root_squash`, `sectype=sys`, and `security_label=true`. The existing
completed export Job uses create-if-absent behavior and cannot update it.
Cutover therefore uses separately reviewed, versioned GitOps Jobs to fence the
legacy export and create `/media` on filesystem `cephfs` at the target
`subvolumePath`, while preserving those settings and the stable LoadBalancer
Service.

An empty export `clients` list describes access rules, not active sessions, and
an instantaneous socket check cannot detect an offline client that reconnects.
Explicitly disable or unmount every known external NFS client before the final
delta and export swap, then verify export information and a read-only NFS mount
before allowing clients to reconnect.

Plex, Jellyfin, ARR, NFS, and media-shared are separate Argo Applications, so
resource sync-wave annotations cannot order the cutover across them. Switch
each through a separate commit and health gate. Keep all old claims, PVs, the
old export details, and the old subvolume intact for rollback until the new
mounts and representative media reads have been verified.

## Deferred cleanup gates

No destructive cleanup is represented in this phase.

- The media subvolume currently has no CephFS snapshots. Remove its five old
  static claim/PV bindings through GitOps only after every direct, torrent, and
  NFS client has moved and Ceph reports no old-filesystem clients.
- The old data0 pool still contains the orphaned subvolume
  `csi-vol-088b88c5-e3a9-4efd-ba2a-105e6d2a8c3e` and retained snapshot
  `csi-snap-ab6c8947-7eb5-4e29-a887-2f7775c11d07`. There are no matching
  Kubernetes VolumeSnapshot/VolumeSnapshotContent objects or pending clones.
  Snapshot removal must precede orphan-subvolume and old-filesystem removal.
- Before deleting either old filesystem or pool, repeat the Kubernetes PV/PVC,
  CephFS client, subvolume, snapshot, pending-clone, and pool-usage inventories
  and require zero unexplained references.

Until those gates pass, rollback is a GitOps switch back to the retained old
claims and old NFS export only if no writer has been allowed onto the target.
After NFS or ARR writes to the target, a direct switch back can discard or
fork new data: quiesce every target writer and run a reviewed reverse delta (or
explicitly accept the loss) before restoring the old claims/export.
