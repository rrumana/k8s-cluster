# Media library CephFS bulk migration

This stages the migration of the shared media library from the old replicated
`ceph-filesystem` filesystem to the EC 2:1 `cephfs` filesystem. It does not
change a live consumer or remove old data.

## Known state and safety limits

- The source is the `media/media-library` claim, backed by
  `ceph-filesystem:/volumes/bulk/media/e51b34bd-ab57-4678-bc00-5861411d64f5`
  in `ceph-filesystem-bulk`.
- The source holds 5,520,405,814,767 bytes (5.02 TiB) and about 1.32 million
  objects. Its quota and the target claim size are 7 TiB.
- Plex and Jellyfin are the direct live consumers. ARR is at zero replicas.
  The Ganesha `/media` export had no established external sessions during the
  inventory, but that must be checked again at cutover.
- The new EC pool had about 8.2 TiB maximum available. Coexistence is projected
  to put the cluster at 66-67% raw usage and OSD.4 near 80%; the near-full
  threshold is 85%.
- The initial concurrent seed is capped at 64 MiB/s. It may run alongside
  other migrations while Ceph remains healthy and clean, MDS health remains
  normal, application health is stable, and OSD latency and temperature stay
  within the monitored gates. Replace the Job with a newly named resumable
  phase if a materially different throttle is needed.

## GitOps phases

1. Add only `storage-class-cephfs-bulk-retain.yaml` to the Rook cluster
   kustomization. Wait for that Application to be Synced/Healthy and confirm
   its provisioner, filesystem, pool, and `Retain` policy.
2. Add `media-library-bulk-pvc.yaml` to the media-shared kustomization. Wait for
   the claim to bind. Confirm its PV reports `fsName: cephfs`,
   `pool: cephfs-bulk`, a nonempty `subvolumePath`, and reclaim policy
   `Retain`. Record that path for the consumer and NFS cutover.
3. Commit `media-library-bulk-copy-job.yaml` while it remains excluded from
   kustomization. This is the inert review phase represented by this tree.
4. Add the Job to kustomization and activate it only after the target claim is
   Bound and its PV has been verified as `fsName: cephfs`, `pool: cephfs-bulk`,
   with reclaim policy `Retain`. The pinned image is authenticated in Harbor
   and supplies rsync 3.2.5 with ACL/xattr support, but is not guaranteed to be
   cached on a storage node; require Harbor healthy before first launch.
5. Monitor Ceph health, slow requests, per-OSD latency, OSD.4 temperature and
   utilization, client throughput, and target growth from the first minute.
   Suspend through GitOps if latency or temperature materially deteriorates,
   if any OSD approaches near-full, or if Ceph stops being clean. Rsync uses
   `--no-whole-file` so protected partial files are valid resume bases even
   though both endpoints are local mounts.
6. After the online seed completes, quiesce every writer and reader through
   separate GitOps commits, explicitly disable or unmount every known external
   NFS client, and run a newly named final-delta Job from the same reviewed
   template. The final Job must use its own phase-specific success marker (for
   example `.cephfs-bulk-migration-final-v1-complete`). Do not rely on changing
   a completed Job in place.
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
Cutover therefore needs a separately reviewed, versioned GitOps Job that
replaces `/media` on filesystem `cephfs` and the target `subvolumePath` while
preserving those settings and the stable LoadBalancer Service.

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
claims and old NFS export.
