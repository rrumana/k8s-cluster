# qBittorrent LTS consolidation assessment

Date: 2026-07-10

## Decision

One LTS seeding deployment is sufficient. The tuned canary demonstrated that a
single instance can saturate the internet uplink, and the two LTS instances are
not sharding the torrent set: they are complete duplicates.

The clean long-term outcome is to roll the tested settings into `arr-lts`, keep
the stable `qbit-lts` Service and ingress names, and then retire `arr-lts2`
after a rollback window. No media copy or torrent import is required.

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
| All-time upload | 1,244,749,355,042,179 B | 1,325,788,556,700,865 B | 2,570,537,911,743,044 B |
| All-time download | 38,229,692,474,196 B | 40,548,275,525,326 B | 78,777,967,999,522 B |
| Human-readable upload | 1.11 PiB | 1.18 PiB | 2.28 PiB |
| Human-readable download | 34.77 TiB | 36.88 TiB | 71.65 TiB |
| Combined ratio | - | - | 32.63 |

These counters cannot be cleanly merged inside qBittorrent. The application
stores global totals as a serialized Qt `QVariantHash` in
`qBittorrent-data.conf`; there is no supported Web API for setting them.
Per-torrent uploaded/downloaded counters are similarly owned by each
instance's resume database. Editing either format would be unsupported and
would still not produce a fully consistent merge.

The combined snapshot above should be treated as the historical handoff. The
retired config PVC should be retained during the rollback window, so its UI and
counters remain recoverable if needed. Future durable statistics should come
from an exporter/Prometheus rather than qBittorrent's local lifetime counter.

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
4. Stop all torrents on `arr-lts2` and observe `arr-lts` alone for 24 hours.
5. Set `arr-lts2` to zero replicas through GitOps. Retain its config PVC,
   ExternalSecrets, Service, and ingress for a short rollback window.
6. After the rollback window, remove the `arr-lts2` workload, Service, ingress,
   certificate, Homepage entry, and unused VPN/WebUI Vault records. Handle the
   config PVC according to the normal retained-volume cleanup policy.

Do not merge or overwrite the two config PVCs. Since every torrent already
exists in `arr-lts`, copying the canary database would replace rather than add
state and would discard the survivor's own statistics.
