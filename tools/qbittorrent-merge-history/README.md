# qBittorrent history merger

This utility merges the historical counters from two qBittorrent instances
that contain the same torrent IDs. It is intended for the `arr-lts` and
`arr-lts2` consolidation and must only be run against files captured after both
qBittorrent processes have stopped cleanly.

It writes new files and never changes either input. Read-only input snapshots
are supported; only the newly created outputs are made owner-writable.

## Merged state

- `total_uploaded` and `total_downloaded`: sum both clients.
- `added_time` and `completed_time`: earliest non-zero timestamp.
- `last_upload`, `last_download`, and `last_seen_complete`: latest timestamp.
- `active_time`, `finished_time`, and `seeding_time`: maximum duration. The
  clients ran concurrently, so summing these would double-count wall time.
- `Stats/AllStats` all-time upload/download: sum both clients.

All other torrent settings and state come from the target (surviving) client.
The tool requires equal torrent counts and a matching source row for every
target torrent ID. Both input databases and the output database must pass
SQLite `quick_check`.

## Build

```bash
cmake -S tools/qbittorrent-merge-history \
  -B build/qbittorrent-merge-history
cmake --build build/qbittorrent-merge-history
```

## Run

```bash
build/qbittorrent-merge-history/qbittorrent-merge-history \
  --target-db snapshots/arr-lts/torrents.db \
  --source-db snapshots/arr-lts2/torrents.db \
  --target-stats snapshots/arr-lts/qBittorrent-data.conf \
  --source-stats snapshots/arr-lts2/qBittorrent-data.conf \
  --output-db output/torrents.db \
  --output-stats output/qBittorrent-data.conf
```

At cutover, retain timestamped copies of all four inputs and the retiring
client's config PVC. Copy the validated output files into the surviving config
PVC only while qBittorrent is stopped. Back up and remove any old
`torrents.db-wal` and `torrents.db-shm` files before replacing the main
database, then restore ownership to `1000:1000` and start the survivor. Compare
its API counters with the tool output before retiring the second deployment.

Run the merger on trusted snapshots only. The Qt settings file is deserialized
using `QSettings`, which is not intended as a parser for untrusted input.

The merge is intentionally not idempotent: using an already merged database as
the target would add the source counters again. Keep the original snapshots,
use new output paths for every attempt, and install exactly one validated
output pair.
