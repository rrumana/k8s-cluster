# Media library CephFS bulk migration record

The shared media library was migrated in July 2026 from the replicated
`ceph-filesystem` filesystem to the EC 2:1 bulk data pool on the `cephfs`
filesystem. The data migration and consumer cutover are complete. The guarded
source purge and removal of the old filesystem and its four pools are also
complete.

This document preserves the identities, validation evidence, and lessons that
matter for recovery or a future large CephFS migration. It is no longer an
activation runbook for the removed copy and cutover Jobs.

## Final storage contract

- The authoritative Kubernetes claim is `media/media-library-bulk`, backed by
  retained PV `pvc-3c9d41ae-9801-449c-9c74-7aee4e1e04cb`.
- Its CephFS subvolume is
  `csi-vol-ef558726-9083-4b68-967b-68384ebbe5f1` in group `csi`, at
  `/volumes/csi/csi-vol-ef558726-9083-4b68-967b-68384ebbe5f1/93c2eaaf-c82c-492f-a60a-1d6e552de2ec`.
- The PV reports `fsName: cephfs`, `pool: cephfs-bulk`, and reclaim policy
  `Retain`. The claim and source quota are 7 TiB.
- Plex and Jellyfin mount `media-library-bulk` directly.
- ARR mounts the same subvolume through the static
  `media-library-bulk-torrent-eva-3` alias. That alias is node-affine to
  `eva-3` and preserves the qBittorrent-specific mount contract:
  `noatime` and `rasize=131072`.
- The ARR alias deliberately omits the old replicated-filesystem
  `read_from_replica=localize` and `crush_location` options. An EC 2:1 stripe
  has no complete local replica to select, so those options are inapplicable.
- The stable Ganesha export remains `/media`, but now publishes the exact
  target path on `cephfs`. It remains RW, NFS 3+4 over TCP, with
  `no_root_squash`, `sectype=sys`, and `security_label=true`.

Do not replace ARR's tuned alias with the canonical claim merely because both
reach the same subvolume. The canonical dynamically provisioned PV has generic
mount options. On the alias, 128 KiB readahead coalesces qBittorrent's otherwise
tiny reads without allowing much larger speculative reads, while `noatime`
avoids read-driven metadata writes.

The mount is only half of the ARR anti-amplification contract. The `pf-sync`
sidecar continuously reconciles these qBittorrent/libtorrent settings from the
Deployment, including after a port-forward update:

| Setting | Desired value |
| --- | ---: |
| Disk I/O type | Simple pread/pwrite (`3`) |
| Asynchronous I/O threads | `3` |
| Hashing threads | `4` |
| Global upload slots | `256` |
| Upload slots per torrent | `8` |
| Send-buffer low watermark | `16384` bytes |
| Send-buffer watermark | `131072` bytes |
| Send-buffer watermark factor | `250` percent |

ARR's incomplete/temp path remains local at `/var/lib/qbit-temp`; high-churn
temporary writes do not enter Ceph. The ARR alias, Plex, Jellyfin, and NFS all
reach the same target subvolume, so imports and seeding retain inode-level hard
links rather than creating copies across filesystems.

## Retired source identity

The source was the `media/media-library` claim, backed by:

```text
filesystem: ceph-filesystem
group:      bulk
subvolume:  media
pool:       ceph-filesystem-bulk
path:       /volumes/bulk/media/e51b34bd-ab57-4678-bc00-5861411d64f5
quota:      7696581394432 bytes (7 TiB)
```

The pre-copy inventory measured 5,520,405,814,767 bytes (5.02 TiB) and about
1.32 million objects. It found 2,709 hard-link groups spanning top-level
branches, including roughly 3.25 TiB linked between Downloads and Shows and
589 GiB linked between Downloads and Movies. A pathname-based split would have
materialized many of those names as separate files and nearly doubled some
content, so it was explicitly prohibited.

## Copy design and convergence

The online seed used whole-file rsync streams and deterministically assigned
every non-directory pathname by source device and inode. Every name belonging
to one hard-link group therefore remained in the same worker's file list even
when its paths crossed Downloads and an organized library. The five buckets
contained 0.93-1.05 TiB of unique data each, with zero hard-link groups crossing
workers.

The active v11 phase ran five inode-disjoint streams capped at 52 MiB/s each,
for a 260 MiB/s logical ceiling. Completed files remained restart-safe, while
an interrupted current file was retransmitted with `--whole-file` instead of
delta-scanning an EC partial. A serial full-tree convergence then restored
directory metadata, applied deletes, and provided the final hard-link boundary.

The v11 copy reached data convergence but exited because four empty nested
`.rsync-partial` directories remained. The v12 convergence pass transferred no
file data, removed those reserved directories, produced an empty exact dry run,
and wrote the `seed:v1` completion marker. This distinction is useful: an rsync
exit caused solely by protected empty work directories did not justify
recopying 5 TiB.

After all consumers and the NFS export were fenced, the final-delta pass also
transferred and deleted zero files. Its exact dry run was empty and it wrote the
`final:v1` marker with these byte counts:

```text
source_bytes=5520406966272
target_bytes=5520406967296
```

The 1,024-byte target excess was migration marker metadata, not duplicated
media. Rsync preserved ownership, modes, hard links, ACLs, xattrs, sparse files,
and filesystem boundaries. Ceph checksums and rsync transfer checks protected
the copy path; a second full 5 TiB checksum reread was intentionally avoided
because it would have doubled I/O and thermal exposure without a proportional
recovery benefit.

## Cutover and validation evidence

The cutover used separate GitOps commits and health gates because Plex,
Jellyfin, ARR, NFS, media-shared, and Rook are separate Argo CD Applications.
Cross-Application sync waves were not treated as an ordering mechanism.

The completed sequence was:

1. Converge the online seed and remove its Job and source session.
2. Quiesce Plex, Jellyfin, and ARR; explicitly check external NFS activity.
3. Remove the legacy `/media` export so an offline client could not reconnect
   to the source during the final delta.
4. Run the exact final delta with every consumer fenced, then remove its Job.
5. Move Plex and Jellyfin to `media-library-bulk` and validate representative
   media stats and reads.
6. Create `/media` on the target path, inspect its complete export definition,
   and validate a representative read through an independent read-only NFSv4.1
   mount.
7. Move ARR to the target, restore one replica, validate all nine containers
   and the qBittorrent/Servarr APIs, and perform a controlled target
   create/rename/read/delete test.
8. Correct ARR's first generic target mount by introducing the retained tuned
   static alias. The live node mount was then verified as `noatime` with
   `rasize=131072` before legacy storage cleanup proceeded.
9. Remove the old canonical binding and all four old torrent aliases after
   cluster-wide workload, PVC, PV, CephFS-session, and path-reference scans
   found no remaining source consumer.

The NFS fence exposed one Ceph CLI behavior worth retaining: an absent export
can be returned as `{}` with exit status zero. Absence checks must inspect the
export inventory or parsed object content; command success alone is not proof
that an export exists.

## Throughput and placement lessons

- The media tree could sustain approximately 230-250 MiB/s of simultaneous
  logical reads and writes when the OSDs and competing recovery were healthy.
  Adding more rsync processes beyond the balanced inode buckets mostly added
  queue depth rather than bandwidth.
- A high-throughput run coincided with 5-7 second BlueStore commit stalls on
  OSD.0 and an actual SMART thermal-management transition. Temperature by
  itself was informational; latency, device throttling, media errors, Ceph
  health, and application health were the material gates.
- Bulk movers need an explicit placement decision. The early seed used default
  scheduling on a control node; the final-delta Job was deliberately placed on
  the storage plane. Future movers must select a client pool after checking
  link headroom and must spread concurrent clients by hostname.
- Job pod templates are immutable. A materially changed throttle or script must
  use a newly named, initially suspended Job. Remove or suspend the prior Job
  and prove its pod, process, and CephFS session are absent before activating a
  replacement; Argo CD can apply a replacement before pruning its predecessor.

## Source retirement

The old five PV/PVC bindings and obsolete seed/cutover Jobs have been removed
from desired state. The destructive cleanup Jobs failed closed unless all of
these remained true:

- every OSD is up and in and all PGs are active+clean;
- the target identity, pool, quota, minimum byte count, and NFS export exactly
  match the final contract;
- the old filesystem contains only the exact source subvolume and has no
  snapshots, pending deletions, unexpected groups, or unexpected clients;
- the target is at least as large as the source; and
- the old pool still has its expected 2x layout.

The v1 Job scheduled `ceph fs subvolume rm` and waited for the namespace to be
absent, pending deletion count to reach zero, and the old bulk pool to fall to
at most 2 GiB of filesystem residuals. The source purge reclaimed about
5.52 TB logical / 11.04 TB raw and left zero objects. While that happened, the
PG autoscaler merged the emptying pool from 128 PGs to 32. v1 reached its final
health assertion during one merge handoff and failed rather than reporting a
false success. A separately staged v2 verifier waited for the stable 32-PG
state and completed with the cluster at 529/529 active+clean.

After the cleanup Jobs were pruned, GitOps first changed
`preserveFilesystemOnDelete` to `false` and waited for the live
CephFilesystem's observed generation to catch up. A separate revision then
removed the old CR. Rook deleted `ceph-filesystem`, both MDS deployments and
auth identities, and pools `ceph-filesystem-metadata` (3),
`ceph-filesystem-data0` (4), `ceph-filesystem-replicated` (16), and
`ceph-filesystem-bulk` (17). The final cluster has only the retained `cephfs`
filesystem and 417/417 PGs active+clean.

## Recovery posture

Before the final cutover, rollback could have switched consumers to the
retained old claims while no target writer existed. That is no longer safe:
ARR and NFS have been allowed to write to the target, the old bindings are
gone, and the source filesystem has been deleted.

Recover the current dataset from the retained target, an explicitly selected
backup recovery point, or a deliberate reverse migration. Never recreate an
old claim and blindly switch writers to it; doing so can discard or fork all
changes made after cutover. Any reverse migration must quiesce target writers,
inventory hard links again, run a reviewed delta, and pass the same exact
identity and consumer gates used here.
