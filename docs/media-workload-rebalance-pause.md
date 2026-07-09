# Media Workload Rebalance Pause

On 2026-07-08, the workloads that mount the shared media CephFS PVCs were
scaled to zero during the final Eva OSD expansion and rebalance.

Paused workloads:

| Namespace | Workload | PVC | Reason |
| --- | --- | --- | --- |
| `media` | `arr-stack` | `media-library-torrent` | qBittorrent/Servarr stack can generate heavy CephFS reads during seeding and scanning. |
| `media` | `arr-lts` | `media-library-torrent` | qBittorrent seeding should stay offline during the rebuild. |
| `media` | `arr-lts2` | `media-library-torrent` | qBittorrent seeding should stay offline during the rebuild. |
| `media` | `jellyfin` | `media-library` | Media streaming should stay offline during the rebuild. |
| `media` | `plex` | `media-library` | Media streaming should stay offline during the rebuild. |

Restore these workloads by setting each Deployment back to `replicas: 1` after
Ceph is active+clean and the stale removed OSD has been purged.
