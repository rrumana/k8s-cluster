# qBittorrent LTS consolidation assessment

Date: 2026-07-10

## Decision

One LTS seeding deployment is sufficient. The tuned canary demonstrated that a
single instance can saturate the internet uplink, and the two LTS instances are
not sharding the torrent set: they are complete duplicates.

The clean long-term outcome is to roll the tested settings into `arr-lts`, keep
the stable `qbit-lts` Service and ingress names, and then retire `arr-lts2`
after a rollback window. No media copy or torrent import is required.

## Cutover status

The consolidation completed on 2026-07-10. `arr-lts` is the surviving
deployment behind `qbit-lts`; `arr-lts2` is held at zero replicas and its
configuration PVC remains intact for rollback.

The final offline merge processed all 1,186 torrents and produced these
cutover counters before the survivor resumed protocol traffic:

| Counter | Merged value |
| --- | ---: |
| All-time upload | 2,570,812,445,989,938 B |
| All-time download | 78,786,134,235,853 B |
| Per-torrent upload | 2,461,234,772,721,440 B |
| Per-torrent download | 414,821,590,553 B |

The immutable local snapshots and merger outputs are retained at
`/home/rcrumana/qbittorrent-consolidation-backups/20260710T181519Z`. A second
copy of the pre-merge target files is retained inside the `arr-lts` config PVC
under `history-merge-backup-20260710T181519Z`.

The restarted survivor reported all 1,186 torrents, no error or missing
states, a global ratio of 32.63, approximately 105 MB/s upload, and a 93 ms I/O
queue during the initial validation sample. Its port-forward sidecar now
refreshes the qBittorrent network-interface binding after each detected
process start because the previously observed stale binding recurred during
the cutover.

## Live inventory

| Property | `arr-lts` | `arr-lts2` |
| --- | ---: | ---: |
| Torrent count | 1,186 | 1,186 |
| Aggregate torrent size | 4.24 TiB | 4.24 TiB |
| Torrent hashes shared by both | 1,186 | 1,186 |
| Save-path mismatches | 0 | 0 |
| Tag mismatches | 0 | 0 |
| Category mismatches | 1 | 1 |
| Torrents in an error/missing state | 0 | 0 |

Ratio limits, seeding-time limits, automatic torrent management, tags, and
save paths match for every torrent. `share_limit_action` differs on every
torrent because the instances run different qBittorrent versions; the actual
ratio and time limits are equal.

## Historical statistics

At assessment time, qBittorrent reported:

| Counter | `arr-lts` | `arr-lts2` | Combined snapshot |
| --- | ---: | ---: | ---: |
| All-time upload | 1,244,758,191,920,844 B | 1,325,817,161,871,536 B | 2,570,575,353,792,380 B |
| All-time download | 38,229,959,839,570 B | 40,549,123,858,022 B | 78,779,083,697,592 B |
| Human-readable upload | 1.11 PiB | 1.18 PiB | 2.28 PiB |
| Human-readable download | 34.77 TiB | 36.88 TiB | 71.65 TiB |
| Combined ratio | - | - | 32.63 |

There is no supported qBittorrent API for importing these counters. The
application stores global totals as a serialized Qt `QVariantHash` in
`qBittorrent-data.conf`, while per-torrent counters are bencoded inside each
row of `torrents.db`.

`tools/qbittorrent-merge-history` performs a deliberate offline merge of both
formats. It sums uploaded/downloaded bytes, preserves the earliest lifecycle
timestamps and latest activity timestamps, and takes the maximum active and
seeding duration to avoid double-counting wall time from concurrent duplicate
clients. It requires identical torrent sets, checks all SQLite databases, and
writes new files rather than changing its inputs.

The merged global total will remain larger than the sum of current per-torrent
totals. qBittorrent's global counter includes protocol traffic and torrents
removed in the past, whereas resume rows only describe the 1,186 torrents that
still exist. Both values are retained according to their original semantics.

The table is a tested snapshot, not the final cutover value. The tool will
recalculate the final totals after both clients stop. The retired config PVC
and timestamped copies of all four input files must remain available through
the rollback window. Future durable statistics should still come from an
exporter/Prometheus rather than only qBittorrent's local lifetime counter.

## Benefits of consolidation

- Removes duplicate reads and duplicate peer connections for the same data.
- Releases one VPN tunnel, forwarded port, config PVC, pod, Service, ingress,
  certificate, and Homepage integration.
- Avoids splitting operational settings and upgrades across two clients.
- Preserves uplink saturation based on the canary's measured 100-110 MB/s.
- Reduces CephFS queue pressure when both clients happen to serve uncached
  pieces concurrently.

The tradeoff is loss of client-level redundancy. A qBittorrent or VPN restart
briefly stops all LTS seeding. That is acceptable for a seeding workload and is
preferable to continuously duplicating the same read workload. Kubernetes,
the retained config PVC, and the existing media data provide straightforward
recovery.

## Recommended sequence

1. Roll the tested Harbor image, CephFS mount, disk backend, thread count,
   upload-slot limits, and memory ceiling into `arr-lts`.
2. Give `arr-lts` an eva-2-affine CephFS PV with
   `read_from_replica=localize`, `crush_location=host:eva-2`, and
   `rasize=131072`.
3. Verify all 1,186 hashes, the single category difference, forwarded-port
   synchronization, VueTorrent, tracker reachability, and sustained line-rate
   upload on `qbit-lts`.
4. Stop both qBittorrent processes cleanly so statistics and resume data are
   flushed. Capture `torrents.db` and `qBittorrent-data.conf` from both PVCs,
   retain timestamped originals, and run `qbittorrent-merge-history` with
   `arr-lts` as the target.
5. Install the two validated output files in the `arr-lts` config PVC, restore
   ownership to `1000:1000`, remove stale `torrents.db-wal` and
   `torrents.db-shm` files after backing them up, and start only `arr-lts`.
   Confirm its API totals match the merger output before resuming service.
6. Observe `arr-lts` alone for 24 hours, then set `arr-lts2` to zero replicas
   through GitOps. Retain its config PVC, ExternalSecrets, Service, and ingress
   for a short rollback window.
7. After the rollback window, remove the `arr-lts2` workload, Service, ingress,
   certificate, Homepage entry, and unused VPN/WebUI Vault records. Handle the
   config PVC according to the normal retained-volume cleanup policy.

Do not copy the canary database over the survivor. Since every torrent already
exists in `arr-lts`, a direct copy would discard the survivor's history. Only
the merger outputs should replace the two target files, and only while the
surviving qBittorrent process is stopped.
